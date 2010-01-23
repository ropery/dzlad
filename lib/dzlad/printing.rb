#!/usr/bin/env ruby
# encoding: utf-8

module Dzlad
  module Printing
    # Tested in rxvt-unicode and xterm, both works with:
    # :reset, :bold, :underscore, :reverse
    Attributes = {
      :reset      => '0', :black   => '30', :on_black   => '40',
      :bold       => '1', :red     => '31', :on_red     => '41',
      :faint      => '2', :green   => '32', :on_green   => '42',
      :italic     => '3', :yellow  => '33', :on_yellow  => '43',
      :underscore => '4', :blue    => '34', :on_blue    => '44',
      :blink      => '5', :magenta => '35', :on_magenta => '45',
      :fast_blink => '6', :cyan    => '36', :on_cyan    => '46',
      :reverse    => '7', :white   => '37', :on_white   => '47',
      :concealed  => '8',
    }

    @@attrs = Attributes

    def turn_off_colors
      @@attrs = nil
    end
    def turn_on_colors
      @@attrs = Attributes
    end
    def colors_on?
      !!@@attrs
    end
    module_function :turn_off_colors
    module_function :turn_on_colors
    module_function :colors_on?

    alias colors? colors_on?

    # order matters in attrs list
    def add_attr(text, *attrs)
      return text unless @@attrs
      attrs.map! {|a| @@attrs[a]}
      attrs = attrs.join(';')
      "\033[#{attrs}m#{text}\033[m"
    end

    module_function :add_attr

    Prefixes = {
      #method; prefix and its attributes;
      'msg' => [':: ', :green,  :bold],
      'inf' => [' -> ', :blue,   :bold],
      'wrn' => ['WW ', :yellow, :bold],
      'err' => ['>> ', :red,    :bold]
    }
    Prefixes.each do |k,v|
      module_eval(<<-EOF)
        def #{k}(format, *args)
          prefix = add_attr(*#{v})
          "\#{prefix}\#{format}\\n" % args
        end
        module_function :#{k}
      EOF
    end

    AttrConfigs = {
      :core              => [:blue],
      :extra             => [:green],
      :community         => [:cyan],
      #:community_testing => [:cyan,    :bold],
      :testing           => [:yellow,:bold],
      :aur               => [:magenta],
      :pkgname           => [:white, :bold],
      :pkgver_out        => [:red,   :bold],
      :pkgver_ok         => [:green, :bold],
      :numvotes          => [:black, :bold],
      :pkgdesc           => nil
    }

    # width normally should be set to terminal width
    def package_info_brief(pkgrepo, pkgname, pkgverr, pkgdesc, outofdate, numvotes, width=80)
      pkgrepo = add_attr(pkgrepo, *AttrConfigs[pkgrepo.to_sym]) + '/'
      pkgname = add_attr(pkgname, *AttrConfigs[:pkgname])
      pkgverr = ' ' + add_attr(pkgverr, *AttrConfigs[outofdate ? :pkgver_out : :pkgver_ok])
      pkg_old = ' [Out Of Date]' unless !outofdate or colors_on?
      numvotes = add_attr(" |#{numvotes}|", *AttrConfigs[:numvotes])
      pkgdesc = "\n" + add_attr(pkgdesc.to_block(width,4), *AttrConfigs[:pkgdesc])
      "#{pkgrepo}#{pkgname}#{pkgverr}#{pkg_old}#{numvotes}#{pkgdesc}"
    end

    # Note values of this hash are already String.
    # create a two-column chart from hash; mimics the output of pacman -Qi
    def package_info_chart(hash, width=terminal_width, sep=' : ')
      # length of left column == length of the longest key.
      l_len = hash.keys.map{|k| k.length}.max
      len_l = l_len + sep.length
      r_len = width - len_l
      chart = ''
      hash.each do |k,v|
        chart << k.ljust(l_len) << sep << v.to_block(r_len, len_l).lstrip
      end
      chart
    end

    # tput is in the ncurses package; stty in coreutils.
    def terminal_width
      %x{/bin/tput cols}.chomp.to_i rescue %x{/bin/stty size}.chomp.split.last.to_i rescue 80
    end

    class ::Object
      def to_block(len, lpad=0, rpad=0, fill=' ')
        l_fill = ''; lpad.times {l_fill << fill}
        r_fill = ''; rpad.times {r_fill << fill}
        c_len = len - (lpad + rpad) * fill.length
        # heck, come back and clean this sometime.
        s = self.to_s.gsub(/(\S{#{c_len},#{c_len}})(\S{1,#{c_len}})/,"\\1\n\\2\n")
        s.gsub(/(.{1,#{c_len}})(\s+|$)/, "#{l_fill}\\1#{r_fill}\n")
      end
    end
  end
end

# vim:ts=2 sw=2 et:
