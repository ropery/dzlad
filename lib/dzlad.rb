#!/usr/bin/env ruby
# encoding: utf-8

require 'optparse'
require 'ostruct'

require 'dzlad/aur'
require 'dzlad/printing'

module Dzlad

  class Dzlad
    include Printing

    Meta = {
      :version => ['0.1.1', '20090122'],
      :authors => ['lolilolicon <lolilolicon@gmail.com>'],
      :license => ['MIT']
    }

    RootDir = File.join(ENV[:HOME], '.dzlad')
    Ignored = File.join(Dzlad::RootDir, 'upgrade_ignore')
    Configs = File.join(Dzlad::RootDir, 'config')
    Session = File.join(Dzlad::RootDir, 'cookie')

    # {{{ setup: option/config parsing
    def initialize(argv)
      @config = {
      :action         => :derive,
      :data_dir       => nil,
      :colors         => true,
      :sort           => 'Name',
      :msearch_mode   => :normal,
      :username       => nil,
      :password       => nil,
      :cookie         => nil,
      :save_cookie_in => nil,
      :vote_at_submit => false,
      :by_id          => false,
      :upgrade_ignore => nil,
      :remember       => false,
      :quiet          => false
      }
      # maybe read config file here
      @opts = OpenStruct.new(@config)
      OptionParser.new(nil, 32, ' '*2) do |opts|
        opts.banner = 'Usage: dzlad [action [options] [arguments]]'

        opts.separator ''
        opts.separator 'Actions:'

        opts.on('-d', '--derive', 'Obtain build scripts for packages') do
          @opts.action = :derive
          opts.separator ''
          opts.separator 'Derive:'
          opts.on('-t', '--save-to Dir', 'Save the obtained packages in Dir') do |d|
            @opts.data_dir = d
          end
        end

        opts.on('-u', '--upgrade', 'Check for upgradable AUR packages') do
          @opts.action = :upgrade
          opts.separator ''
          opts.separator 'Upgrade:'
          opts.on('--ignore a,b,c', Array, 'Do not check for packages in list') do |list|
            @opts.upgrade_ignore = list
          end
          opts.on('--remember', 'Ignore next time those not in AUR') do
            @opts.remember = true
          end
        end

        opts.on('-s', '--search', 'Search for packages by name, desc') do
          @opts.action = :search
          opts.separator ''
          opts.separator 'Search:'
          opts.on('-v', '--votes', 'Sort search results by votes') do
            @opts.sort = 'NumVotes'
          end
        end

        opts.on('-i', '--info', 'Output detailed info for packages') do
          @opts.action = :info
        end

        opts.on('-m', '--msearch', 'Search for packages by maintainer') do
          @opts.action = :msearch
          opts.separator ''
          opts.separator 'Msearch:'
          opts.on('-o', '--outofdate', 'Print only outdated packages for maintainer') do
            @opts.msearch_mode = :outofdate
          end
          opts.on('-v', '--votes', 'Sort search results by votes') do
            @opts.sort = 'NumVotes'
          end
        end

        opts.on('-p', '--submit', 'Upload .src.tar.gz tarball to AUR') do
          @opts.action = :submit
          opts.separator ''
          opts.separator 'Submit:'
          opts.on('--category Category', categories=AUR::Categories, 'Set category for the uploaded package') do |c|
            @opts.category = c.nil? ? nil : categories.index(c).to_s
          end
          opts.on('-v', '--vote', 'Vote for the uploaded packages') do
            @opts.vote_at_submit = true
          end
          opts.on('-u', '--user [user:passwd]', 'AUR login username and password') do |u|
            @opts.username, @opts.password = u.split(':') if u
          end
          opts.on('-b', '--cookie [name=data]', 'Use cookie from former login session') do |c|
            @opts.cookie = c
          end
          opts.on('-c', '--cookie-jar [file]', 'Save cookie to file for later access') do |f|
            @opts.save_cookie_in = (f || Dzlad::Session)
          end
        end

        opts.on('-a', '--action Action', actions=AUR::Actions.keys, "Other AUR actions:",
                "#{actions[0,5].join(', ')}", "#{actions[5..-1].join(', ')}") do |a|
          @opts.action = a
          opts.separator ''
          opts.separator 'Other:'
          opts.on('-u', '--user [user:passwd]', 'AUR login username and password') do |u|
            @opts.username, @opts.password = u.split(':')
          end
          opts.on('-b', '--cookie [name=data]', 'Use cookie from former login session') do |c|
            @opts.cookie = c
          end
          opts.on('-c', '--cookie-jar [file]', 'Save cookie to file for later access') do |f|
            @opts.save_cookie_in = (f || Dzlad::Session)
          end
          opts.on('--id', 'Pass packages by ID, instead of name') do
            @opts.by_id = true
          end
        end

        opts.separator ''
        opts.separator 'General:'

        opts.on('--[no-]color', 'Turn on/off color output [on]') do |c|
          @opts.colors = c
        end
        opts.on('-q', '--quiet', 'May reduce output verboseness') do
          @opts.quiet = true
        end
        opts.on('-h', '--help', 'Print help message, then exit') do
          $stderr.puts opts.help
          exit
        end
        opts.on('--version', 'Print version info, then exit') do
          version, date = Meta[:version]
          $stderr.puts "dzlad #{version} (#{date})"
          exit
        end
        opts.on('--examples', 'Demonstrate usage by examples') do
          $stdout.print dzlad_examples
          exit
        end
      end.parse!(argv)
      @args = argv
    rescue OptionParser::ParseError => e
      $stderr.print err "%s (for action %s)", e.message, @opts.action
      exit EXIT::OPT_ERR
    end
    # }}}

    # {{{ where job is done
    def start
      #traps
      trap :INT do
        $stderr.puts
        $stderr.print err "Interrupted by user, terminating..."
        exit EXIT::INT
      end
      turn_off_colors unless @opts.colors
      case @opts.action
      when :derive
        if dir = @opts.data_dir
          dir = File.expand_path(dir)
          Dir.mkdir(dir) unless FileTest.exist?(dir) rescue nil
          unless FileTest.directory?(dir) and FileTest.writable?(dir)
            $stderr.print err "Directory doesn't exist or not writable: %s", dir
            exit EXIT::FAIL
          end
          Dir.chdir(dir)
        end
        aur = AUR.new
        @args.each {|pkg|
          if aur.download pkg
            $stdout.print msg "AUR package %s saved in %s", add_attr(pkg,:white,:bold), Dir.pwd
          else
            $stderr.print err "Failed to download from AUR: %s", pkg
          end
        }
      when :upgrade
        upgradable = []
        localnewer = []
        notfound = []
        list = %x{/usr/bin/pacman -Qm}.split("\n") #["pkgname ver-rel", ...]
        ignored =  File.open(Dzlad::Ignored).read.split rescue []
        ignores = ignored + (@opts.upgrade_ignore || [])
        list -= ignores
        max_len = list.map{|s| s.size}.max
        aur = AUR.new
        list.each {|pkg|
          pkg, local_ver = pkg.split
          info = aur.info(pkg) rescue nil
          (notfound << pkg; next) unless info
          aur_ver = info['Version']
          pad = add_attr('.' * (max_len - pkg.size + 1), :black)
          case %x{/usr/bin/vercmp #{aur_ver} #{local_ver}}.chomp
          when '1'  then upgradable << pkg; $stdout.print add_attr(pkg,:white, :bold), pad, add_attr("#{local_ver} -> #{aur_ver}\n", :green,  :bold) unless @opts.quiet
          when '-1' then localnewer << pkg; $stdout.print add_attr(pkg,:white, :reverse), pad, add_attr("#{local_ver} >> #{aur_ver}\n", :yellow, :bold) unless @opts.quiet
          end
        }
        $stdout.print msg 'Upgradable AUR Packagess:'
        $stdout.print upgradable.join(' '), "\n"
        if @opts.remember
          try_make_dzlad_rootdir
          File.open(Dzlad::Ignored, 'w') {|f| f << (notfound + ignored).sort.join("\n")}
        end
      when :search
        sep = @args.size == 1 ? '' : "---\n"
        @args.each {|term| search_aur(term, @opts.sort); print sep}
      when :msearch
        sep = @args.size == 1 ? '' : "---\n"
        @args.each {|term| msearch_aur(term, @opts.sort, @opts.msearch_mode); print sep}
      when :info
        sep = @args.size == 1 ? '' : "---\n"
        @args.each {|pkg| pkginfo_aur(pkg); print sep}
      when :submit
        prepare_aur_cookie
        aur = AUR.new(@cookie)
        ids = []
        @args.each {|f|
          # allow the format of: foo.src.tar.gz@bar:baz, where foo is pkgname, bar is category, baz is comment.
          /^([^@:]+)(?:@([^@:]+))?(?::(.+))?$/ =~ f
          tarball, category, comment = $1, $2, $3
          category = category ? AUR::Categories.index(category).to_s : @opts.category
          begin
            res = aur.upload(tarball, category)
          rescue Errno::ENOENT => e
            $stderr.print err e.message
            next
          end
          id = res['location'].split('ID=')[1] if res.code == '302' and res.key? 'location'
          if id
            $stdout.print msg "Uploaded #{File.basename(tarball)} [#{id}]"; ids << id
            comment = $stdin.read if comment == '-' #read comment from stdin if it's '-'
            res = aur.addComment(id, comment) if comment #maybe check res too.
          else
            error = (aur.read_upload_error_message(res) || 'Unkown error while uploading')
            $stderr.print err "%s", error
          end
        }
        # vote all at once instead one by one.
        $stdout.print msg "%s", (aur.read_package_action_response(aur.vote(*ids)) || "Unkown error while voting") if @opts.vote_at_submit and !ids.empty?
      else # made sure above it's one of the "other" AUR actions
        prepare_aur_cookie
        aur = AUR.new(@cookie)
        ids = []
        if @opts.by_id
          ids = @args
        else
          # we have to retrieve the id for the given pkgname first
          @args.each {|pkg|
            info = aur.info(pkg) rescue nil
            unless info
              $stderr.print err "Failed to retrieve ID for %s", pkg
              next
            end
            ids << info['ID']
          }
        end
        ($stderr.print err "No ID retrieved for any of the given packages"; exit EXIT::FAIL) if ids.empty?
        $stdout.print msg "%s", (aur.read_package_action_response(aur.__send__(@opts.action.to_sym,*ids)) || "Unkown error while voting")
      end
    end

    def Dzlad.start(argv)
      Dzlad.new(argv).start
    end
    # }}}

    # {{{ functions
    def dzlad_examples
"
$ dzlad -ph

Will print help messages for the -p/--submit action
Note whatever option you want to use, the first option
must be one of the Actions, unless the intended action
is --derive, which is the default one

$ dzlad -a vote -c -- x264-git

You will be prompt for your AUR username and password,
unless you have cookie saved in #{Dzlad::Session}
The -c switch without an argument tells dzlad to save
the cookie from this session to #{Dzlad::Session}

$ dzlad -a vote -c /tmp/cookie -u user:passwd x264-git
$ dzlad --submit ffcast.src.tar.gz@multimedia:'New Release.' -b /tmp/cookie

You specify AUR username and password with the -u option
The submit example introduces something more interesting:
Note how you can use `@' and `:' to specify category and
add a comment upon submission (use :- to tell dzlad to read it from stdin)
Also note the -c option can take either a filename or a
name-value pair, e.g. 'AURSID=F6C22B006FO1028R1Y907DMTU'

$ dzlad -u --ignore foo,bar,baz --remember

Dzlad will check for upgradable packages from the list
reported by `pacman -Qm', but ignoring foo, bar and baz,
and --remember tells dzlad to save a list of packages
tried but not fount in AUR, plus all ignored packages
to #{Dzlad::Ignored} so they will be
ignored by default next time

"
    end

    def try_make_dzlad_rootdir
      unless FileTest.directory? Dzlad::RootDir
        $stdout.print msg 'Creating Directory %s', Dzlad::RootDir
        begin
          Dir.mkdir Dzlad::RootDir
        rescue
          $stderr.print err 'Failed creating directory.'
          exit EXIT::FAIL
        end
      end
    end

    def prepare_aur_cookie
      @cookie = login_aur(@opts.cookie, @opts.username, @opts.password)
      ($sdterr.print err 'AUR login failed'; exit EXIT::AUR_BAD_AUTH) unless @cookie
      if @opts.save_cookie_in
        try_make_dzlad_rootdir if @opts.save_cookie_in == Dzlad::Session
        File.open(@opts.save_cookie_in,'w') {|f| f << @cookie} # note this overwrites any existing file. (!)
      end
    end

    # cookie is always re-fetched (re-login) if a username is explicitly given.
    def login_aur(cookie, username, password)
      (return cookie.include?('AURSID=') ? cookie : (File.open(cookie) {|f| f.read} rescue nil)) if cookie and not username
      (cooked = File.open(Dzlad::Session).read rescue nil; return cooked if cooked) unless username # use cookie "cooked" in a former session if no cookie or username is given in the command line.
      username ||=  %x{read    -p 'Username: ' i;echo -n $i}
      (password =  %x{read -s -p 'Password: ' i;echo -n $i}; $stdout.puts) unless password
      return AUR.new.login(username, password)
    end

    def search_aur(term, sort='Name')
      aur = AUR.new
      begin
        got = aur.search(term, sort)
      rescue AURBadResponse => e
        $stderr.print err e.message
        exit EXIT::AUR_BAD
      end
      return $stdout.print msg "No package found." if got.nil?
      out = ''
      got.each {|pkg|
        params = ['aur', pkg['Name'], pkg['Version'], pkg['Description'], pkg['OutOfDate'], pkg['NumVotes']]
        out << package_info_brief(*params, terminal_width)
      }
      $stdout.print out
    end

    def msearch_aur(term, sort='Name', mode=:normal)
      aur = AUR.new
      begin
        got = aur.msearch(term, sort)
      rescue AURBadResponse => e
        $stderr.print err e.message
        exit EXIT::AUR_BAD
      end
      return $stdout.print msg "Nothing maintained by #{term} is found." if got.nil?
      out = ''
      case mode
      when :normal
        got.each {|pkg|
          params = ['aur', pkg['Name'], pkg['Version'], pkg['Description'], pkg['OutOfDate'], pkg['NumVotes']]
          out << package_info_brief(*params, terminal_width)
        }
      when :outofdate
        got.each {|pkg|
          out << "#{pkg['Name']} #{add_attr(pkg['Version'], :black, :bold)}\n" if pkg['OutOfDate']
        }
        $stdout.print "#{term} is a good Maintainer. Nothing is outdated.\n" if out.empty?
      end
      $stdout.print out unless out.empty?
    end

    def pkginfo_aur(pkgname_or_id)
      aur = AUR.new
      begin
        got = aur.info(pkgname_or_id)
      rescue AURBadResponse => e
        $stderr.print err e.message
        exit EXIT::AUR_BAD
      end
      return $stdout.print msg "No such package." if got.nil?
      info = {}
      info['Repository'] = 'aur'
      info['Name'] = got['Name']
      info['Version'] = got['Version']
      info['URI'] = got['URL']
      info['AUR Page'] = AUR::BaseURI + "/packages.php?ID=#{got['ID']}"
      info['Category'] = got['CategoryID']
      info['Licenses'] = got['License']
      info['NumVotes'] = got['NumVotes']
      info['Out-Of-Date'] = got['OutOfDate']
      info['Description'] = got['Description']
      out = package_info_chart(info)
      $stdout.print out
    end

  end

  class EXIT
    SUCCESS = 0
    FAIL = 250
    INT = 100
    OPT_ERR = 1
    AUR_BAD = 2
    AUR_BAD_AUTH = 3
  end
  # }}}
end

# vim:ts=2 sw=2 et fdm=marker:
