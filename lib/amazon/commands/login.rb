require "open3"
require "json"

module Amazon
  module Commands
    class Login
      PYWORKER = File.expand_path("../../../pyworker", __dir__)

      def initialize(global)
        @global = global
      end

      def run(argv)
        manual = false
        while (a = argv.shift)
          case a
          when "--manual" then manual = true
          when "-h", "--help"
            puts <<~HELP
              Usage: amazon login [--manual]

              Opens a real browser window and signs you in to Amazon, then waits
              until your order history loads before saving anything — Amazon
              guards orders separately, so a session that greets you by name
              still can't read them.

              With `password_op_ref` (and optionally `otp_op_ref`) in your
              config, the password and 2FA code are read from 1Password and
              typed in for you, leaving the window there for anything only a
              human can do — a captcha, a "was this you?" prompt. Without them,
              or with --manual, you type everything yourself.

              The window is a throwaway Chrome profile with no extensions, so
              your password manager's toolbar button isn't in it. That is what
              --manual costs you.

              Cookies are saved so subsequent `amazon order sync` and
              `amazon subscribe` calls skip the login flow.
            HELP
            return 0
          else
            warn "unknown login option: #{a}"
            return 2
          end
        end

        Amazon::Config.ensure_dirs!
        request = manual ? {} : credentials

        Open3.popen3(*python_cmd, chdir: PYWORKER) do |stdin, stdout, stderr, wait|
          send_request(stdin, request)
          # Kept even when not printing it. login.py can die before it emits a
          # single event — a missing interpreter, a broken playwright install —
          # and the traceback explaining why is on this stream. Discarding it
          # unless -v happened to be passed left the user with a bare exit code
          # and a browser window that never opened.
          err_lines = []
          err_thread = Thread.new do
            stderr.each_line do |l|
              l = l.chomp
              err_lines << l
              warn(l) if @global.verbose
            end
          rescue IOError
            # stderr closed during shutdown; that's fine.
          end

          saw_error = false
          stdout.each_line do |line|
            line = line.strip
            next if line.empty?
            event = parse_event(line)
            next unless event

            case event["event"]
            when "log"      then warn(event["msg"]) unless @global.quiet
            when "navigate" then warn("→ #{event["url"]}") unless @global.quiet
            when "done"
              warn("amazon: saved #{event["count"]} cookies to #{event["cookies_path"]}")
              warn("       run `amazon order sync` to fetch orders.")
            when "error"
              saw_error = true
              warn("amazon login: #{event["msg"]}")
            end
          end

          err_thread.join
          status = wait.value.exitstatus
          # An `error` event already said something better than a traceback. It's
          # the silent crash that needs the stderr, and only then.
          if !status.zero? && !saw_error && !err_lines.empty? && !@global.verbose
            warn("amazon login: the browser worker failed:")
            err_lines.last(20).each { |l| warn("  #{l}") }
          end
          return status
        end
      end

      private

      # The password and TOTP, straight from 1Password to the worker's stdin.
      #
      # Silent when nothing was configured: no config file, or no
      # `password_op_ref` in it, means autofill was never on offer, and a
      # warning would be the CLI apologising for a feature you didn't ask for.
      # A configured ref that fails to read is the opposite — you asked, and
      # you need to know why the window is waiting.
      #
      # Either way the login continues. Every failure here is recoverable by a
      # human with a keyboard, which is exactly what happened before this
      # existed.
      def credentials
        ref = configured_password_ref
        return {} unless ref

        {
          password: Amazon::Secrets.read(ref),
          otp_secret: (otp = Amazon::Config.load.otp_op_ref) ? Amazon::Secrets.read(otp) : nil
        }.compact
      rescue StandardError => e
        warn "amazon login: no credentials from 1Password (#{e.message.lines.first&.strip}) — sign in by hand"
        {}
      end

      def configured_password_ref
        Amazon::Config.load.password_op_ref
      rescue StandardError => e
        # A missing config is the ordinary not-set-up-yet case, and the login
        # works fine without one, so it says nothing. A config that *exists*
        # and won't parse is a different animal: `amazon order sync` refuses
        # to run at all on that file (cli.rb), while this path quietly decided
        # you had no credentials configured. Same broken file, two verdicts,
        # and the quiet one is the one you'd hit first.
        warn "amazon login: couldn't read config (#{e.message.lines.first&.strip}) — " \
             "signing in by hand; run `amazon config edit` to fix it" if Amazon::Config.config_path.exist?
        nil
      end

      # One line of JSON, then the pipe closes. The worker reads at most one
      # line, so anything else would sit in a buffer nobody drains.
      def send_request(stdin, request)
        stdin.write("#{JSON.generate(request)}\n") unless request.empty?
        stdin.close
      rescue Errno::EPIPE
        # The worker died before reading — its stderr says why, and that is a
        # better message than a broken pipe.
        nil
      end

      def parse_event(line)
        JSON.parse(line)
      rescue JSON::ParserError
        # A bare `rescue nil` here swallowed every StandardError, so a truncated
        # line and a bug in this method looked identical — both vanished.
        warn("[login] non-JSON output: #{line}") if @global.verbose
        nil
      end

      def python_cmd
        venv = File.join(PYWORKER, ".venv", "bin", "python")
        python = File.executable?(venv) ? venv : "python3"
        [python, "login.py"]
      end
    end
  end
end
