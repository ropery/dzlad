#!/usr/bin/env ruby
# encoding: utf-8

begin
#  require 'rubygems'
  require 'yajl/json_gem'
rescue LoadError
  require 'json'
end
require 'uri'
require 'net/https'
require 'stringio'
require 'zlib'

module Dzlad

  class AURBadResponse < StandardError; end

  #
  # Arch User Repository Handler
  #
  class AUR

    BaseURI    = 'https://aur.archlinux.org'
    SearchURI  = BaseURI + '/rpc.php?type=search&arg='  # search in package Name and Description
    MSearchURI = BaseURI + '/rpc.php?type=msearch&arg=' # search by Maintainer name
    InfoURI    = BaseURI + '/rpc.php?type=info&arg='    # search info about an exact package by name or id
    SubmitURI  = BaseURI + '/pkgsubmit.php'             # upload *.src.tar.gz tarball

    Categories = [ nil, nil, 'daemons', 'devel', 'editors', 'emulators', 'games',
                  'gnome', 'i18n', 'kde', 'lib', 'modules','multimedia', 'network',
                  'office', 'science', 'system', 'x11', 'xfce', 'kernels' ]

    # The default User-Agent used in request headers.
    def AUR.default_user_agent
      "curl/7.19.7 (i686-pc-linux-gnu) libcurl/7.19.7 OpenSSL/0.9.8l zlib/#{Zlib.zlib_version}"
    end

    # Set User-Agent used in request headers.
    def set_user_agent(userAgent)
      @userAgent = userAgent
    end

    # Check if user is logged in.
    def logged_in?
      !@cookie.nil?
    end

    attr_accessor :userAgent, :cookie
    attr_reader   :user

    # Create a Dzlad::AUR object.
    def initialize(cookie=nil, userAgent=nil)
      @userAgent = (userAgent || AUR.default_user_agent)
      @cookie = cookie
      @user = nil
    end

    def inspect
      "#<#{self.class} user=#{@user} login=#{logged_in?}>"
    end

    # AUR user login, returns the cookie String on success, nil on fail.
    def login(username, password)
      @user = username
      path = "/index.php"
      body = "user=#{username}&passwd=#{password}"
      res = basic_form_post(path, body)
      if res.key?('set-cookie') and res.code == '302'
        @cookie = res['set-cookie']
      else
        @cookie = nil
      end
    end

    # Post method suitable for basic AUR form posts.
    # Returns a Net::HTTPResponse object.
    def basic_form_post(path, body)
      uri = URI.parse(BaseURI + path)
      req = Net::HTTP::Post.new(uri.request_uri)
      req.body = URI.escape(body)
      req['cookie'] = @cookie
      req['user-agent'] = @userAgent
      req['accept-encoding'] = 'gzip'
      req['content-type'] = 'application/x-www-form-urlencoded'
      req['content-length'] = req.body.length
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true if uri.scheme == "https"
      res = http.start {
        http.request(req) {|r|
          if r.key?('content-encoding')
            if r['content-encoding'] == 'gzip'
              body = StringIO.new(r.read_body)
              r.body= Zlib::GzipReader.new(body).read
            end
          end
        }
      }
    end

    # TODO Exeptions
    # NOTE This is only suitable for small files since it reads the entire body into memory.
    def http_get(uri)
      # use gzip for compression, gains speed.
      header = {
        'accept-encoding' => 'gzip',
        'user-agent'      => @userAgent,
      }
      header['cookie'] = @cookie if @cookie
      uri = URI.parse(uri)
      req = Net::HTTP::Get.new(uri.request_uri, header)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true if uri.scheme == "https"
      res = http.start {
        http.request(req) {|r|
          if r.key?('content-encoding')
            if r['content-encoding'] == 'gzip'
              body = StringIO.new(r.read_body)
              r.body= Zlib::GzipReader.new(body).read
            end
          end
        }
      }
    end

    # Parse the json String returned from the HTTP request into a Hash.
    def json_parse(uri)
      res = http_get(uri)
      json = res.body
      JSON.parse(json)
    end

    # search AUR RPC interface, returns a sorted Array of Hash (matched packages)
    def search(term, sort='Name')
      uri = SearchURI + URI.escape(term)
      do_search uri, 'search', sort
    end

    # search AUR RPC interface by Maintainer; returns a sorted Array of Hash (matched packages)
    def msearch(term, sort='Name')
      uri = MSearchURI + URI.escape(term)
      do_search uri, 'msearch', sort
    end

    # search AUR RPC interface by exact package name _or_ id, returns a hash.
    def info(term)
      uri = InfoURI + URI.escape(term)
      do_search uri, 'info'
    end

    # Unified for search, msearch and info methods
    #--
    # Hash keys in results (Maintainer is from msearch.)
    # (Maintainer) ID Name Version CategoryID Description LocationID URI URIPath License NumVotes OutOfDate
    #++
    def do_search(uri, type, sort=nil)
      json = json_parse(uri)
      if json['type'] == type
        packages = json['results']
        convert = lambda {|pkg|
          pkg['CategoryID'] = Categories[pkg['CategoryID'].to_i]
          pkg['NumVotes'] = pkg['NumVotes'].to_i
          pkg['OutOfDate'] = pkg['OutOfDate'] == '1'
        }
        case type
        when 'info' then convert.call(packages)
        else packages.each {|pkg| convert.call(pkg)}
        end
        packages = json['results'].sort_by{|pkg| pkg[sort]} if sort
        return packages
      elsif json['type'] == 'error' and json['results'] !~ /\ANo result(s?) found\Z/
        raise AURBadResponse, "#{json['results']}"
      end
      nil
    end

    # download from AUR build scripts for the named package.
    # --
    # using /bin/tar for now, which seems to be the best solution to me.
    # ++
    def download(pkgname)
      uri = BaseURI + "/packages/#{pkgname}/#{pkgname}.tar.gz"
      res = http_get(uri)
      tarcmd = '/bin/tar xzf - 2>/dev/null'
      IO.popen(tarcmd,'r+') {|f| f.write(res.body)}
      $?.success?
    end

    # Upload a src.tar.gz containing build scripts to AUR. Login required.
    # tarball can either be a filepath String or an IO-ish object
    def upload(tarball, category='16')
      uri = URI.parse(SubmitURI)
      req = Net::HTTP::Post.new(uri.path)
      req['cookie'] = @cookie
      req['user-agent'] = @userAgent
      # multipart/form-data post
      boundary = "--------------Dzlad#{rand 10000000000000000000000}"
      form_fields = {
        'pkgsubmit' => '1',
        'category'  => category
      }
      file_fields = { 'pfile' => tarball }
      req['content-type'] = "multipart/form-data; boundary=\"#{boundary}\""
      body = compose_multipart_post_body(boundary, form_fields, file_fields)
      req['content-length'] = body.size
      req.body_stream = body
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true if uri.scheme == "https"
      res = http.start {
        http.request(req)
      }
    end

    # Prepare body for a multipart/form-data post request; returns a StringIO object.
    def compose_multipart_post_body(boundary, form_fields, file_fields)
      body = StringIO.new('r+b')
      form_fields.each do |k,v|
        body.write "--#{boundary}\r\n"
        body.write "content-disposition: form-data; name=\"#{k}\"\r\n\r\n"
        body.write "#{v}\r\n"
      end
      file_fields.each do |name, path_or_io|
        if path_or_io.respond_to? :read # IO-ish object, comes opened
          close_input = false
          input = path_or_io
          if path_or_io.respond_to? :path
            filepath = path_or_io.path
          else
            filename = 'src.tar.gz'
          end
        else # it's a filepath
          close_input = true
          input = File.open(path_or_io, 'rb')
          filepath = path_or_io
        end
        filename ||= File.basename(filepath)
        body.write "--#{boundary}\r\n"
        body.write "content-disposition: form-data; name=\"#{name}\"; filename=\"#{filename}\"\r\n"
        body.write "content-type: application/x-gzip\r\n"
        body.write "content-transfer-Encoding: binary\r\n\r\n"
        body.write(input.read)
        input.close if close_input
        body.write "\r\n"
      end
      body.write "--#{boundary}--\r\n"
      body.flush
      body.rewind
      body
    end

    def read_upload_error_message(res)
      res.body =~ /.*^<span class='error'>([^\n]+)<\/span><br \/>$.*/m ||
        res.body =~ /.*<p class="pkgoutput">([^<]+)<.*/m ||
        res.body =~ /^(You must create an account before you can upload packages\.)$/
      error = $1
      return nil unless error
      error.gsub(/<[^>]+>/,'')
    end

    Actions = {
      :vote     => 'do_Vote',
      :flag     => 'do_Flag',
      :notify   => 'do_Notify',
      :adopt    => 'do_Adopt',
      :disown   => 'do_Disown',
      :delete   => 'do_Delete', #TU or Dev only
      :unvote   => 'do_UnVote',
      :unflag   => 'do_UnFlag',
      :unnotify => 'do_UnNotify'
    }

    # All actions can take an array of pkgids, with a single http post.
    Actions.each do |k,v|
      AUR.module_eval(<<-EOF)
        def #{k}(*pkgids)
          action = '#{v}'
          packages_action(*pkgids, action)
        end
      EOF
    end

    # Return the message String out of HTTPResponse returned by actions.
    def read_package_action_response(res)
      res.body =~ /.*<p class="pkgoutput">([^<]+)<.*/m
      message = $1
    end

    # Unified method for AUR basic post actions.
    def packages_action(*pkgids, action)
      path='/packages.php'
      body = []
      pkgids.each {|id| body << "IDs[#{id}]=1"}
      body << "action=#{action}"
      body = body.join('&')
      basic_form_post path, body
    end

    def changeCategory(pkgid, category_id)
      path = "/pkgedit.php"
      body = "change_Category=1&ID=#{pkgid}&category_id=#{category_id}"
      basic_form_post path, body
    end

    def viewComments(pkgid)
    end

    def addComment(pkgid, comment)
      path='/packages.php' + "?ID=#{pkgid}"
      comment.gsub!(' ', '+')
      body = "ID=#{pkgid}&comment=#{comment}"
      basic_form_post path, body
    end

    def delComment(pkgid, comment_id)
      uri = BaseURI + "/pkgedit.php?del_Comment=1&comment_id=#{comment_id}&ID=#{pkgid}"
      http_get uri
    end
  end
end

# vim:ts=2 sw=2 et:
