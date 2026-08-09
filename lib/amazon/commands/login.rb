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
        while (a = argv.shift)
          case a
          when "-h", "--help"
            puts <<~HELP
              Usage: amazon login

              Opens a real browser window so you can log in to Amazon manually
              (solving any captcha or 2FA), then waits until your order history
              loads before saving anything — Amazon guards orders separately, so
              a session that greets you by name still can't read them.

              Cookies are saved so subsequent `amazon order sync` calls skip the
              login flow.
            HELP
            return 0
          end
        end

        Amazon::Config.ensure_dirs!

        Open3.popen3(*python_cmd, chdir: PYWORKER) do |stdin, stdout, stderr, wait|
          stdin.close
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
