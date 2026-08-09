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
        venv = File.join(PYWORKER, ".venv", "bin", "python")
        python = File.executable?(venv) ? venv : "python3"

        Open3.popen3(python, "login.py", chdir: PYWORKER) do |stdin, stdout, stderr, wait|
          stdin.close
          err_thread = Thread.new do
            stderr.each_line { |l| warn(l.chomp) if @global.verbose }
          rescue IOError
          end
          stdout.each_line do |line|
            line = line.strip
            next if line.empty?
            event = (JSON.parse(line) rescue nil)
            next unless event

            case event["event"]
            when "log"      then warn(event["msg"]) unless @global.quiet
            when "navigate" then warn("→ #{event["url"]}") unless @global.quiet
            when "done"
              warn("amazon: saved #{event["count"]} cookies to #{event["cookies_path"]}")
              warn("       run `amazon order sync` to fetch orders.")
            when "error"
              warn("amazon login: #{event["msg"]}")
            end
          end
          err_thread.join
          return wait.value.exitstatus
        end
      end
    end
  end
end
