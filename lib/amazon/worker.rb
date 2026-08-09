require "json"
require "open3"
require "io/console"

module Amazon
  class Worker
    class Error < StandardError; end

    PYWORKER = File.expand_path("../../pyworker", __dir__)

    def initialize(verbose: false, quiet: false)
      @verbose = verbose
      @quiet = quiet
    end

    def sync(email:, password:, years:, full_details: true, otp_secret: nil, rate_limit: {}, known_order_ids: [])
      request = {
        action: "sync",
        email: email,
        password: password,
        years: years,
        full_details: full_details,
        otp_secret: otp_secret,
        detail_delay: rate_limit["detail_delay"],
        detail_jitter: rate_limit["detail_jitter"],
        retry_backoff: rate_limit["retry_backoff"],
        known_order_ids: known_order_ids
      }.compact

      orders = []
      error_msg = nil
      progress = Progress.new(quiet: @quiet)
      run(request) do |event|
        case event["event"]
        when "order"    then orders << event["data"]
        when "total"    then progress.start(event)
        when "progress" then progress.tick(event)
        when "log"
          progress.clear
          log_event(event)
        when "done"     then progress.finish(event)
        when "error"    then error_msg = event["msg"]
        end
      end
      progress.clear
      raise Error, error_msg if error_msg && orders.empty?
      @partial_error = error_msg
      orders
    end

    # Set when a sync ended early but kept the orders fetched before the
    # failure. The caller has to decide what to do — silently exiting 0 makes a
    # partial sync indistinguishable from a complete one to cron and `&&`.
    attr_reader :partial_error

    # Live product lookup. Raises Error with a nudge toward `amazon login` when
    # the saved session is missing, has expired, or Amazon serves a captcha.
    def item(asin)
      data = nil
      run({ action: "item", asin: asin }, script: "live.py") do |event|
        case event["event"]
        when "item"  then data = event["data"]
        when "log"   then log_event(event)
        when "error" then raise Error, live_error(event)
        end
      end
      data
    end

    def search(query, limit: 10)
      results = []
      run({ action: "search", query: query, limit: limit }, script: "live.py") do |event|
        case event["event"]
        when "result" then results << event["data"]
        when "log"    then log_event(event)
        when "error"  then raise Error, live_error(event)
        end
      end
      results
    end

    class Progress
      BAR_WIDTH = 20

      def initialize(quiet: false)
        @quiet = quiet
        @tty = $stderr.tty?
        @line_drawn = false
        @start_time = nil
      end

      def start(event)
        return if @quiet
        warn("year #{event["year"]}: #{event["count"]} orders")
        @start_time = nil
      end

      def tick(event)
        return if @quiet
        @start_time ||= Time.now
        total = event["grand_total"] ? format("$%.2f", event["grand_total"]) : "         "
        eta = format_eta(event["i"], event["n"])
        line = format(
          "  [%3d/%-3d] %s %s %s %s  %s  %s",
          event["i"], event["n"],
          bar(event["i"], event["n"]),
          eta,
          event["date"] || "??????????",
          total,
          event["order_id"],
          event["title"].to_s
        )
        # Truncate to terminal width to avoid wrap-spam in TTY mode
        if @tty
          width = (ENV["COLUMNS"] || `tput cols 2>/dev/null`.to_i.nonzero? || 100).to_i
          line = line[0, width - 1]
          $stderr.print "\r\e[2K#{line}"
          $stderr.flush
          @line_drawn = true
        else
          $stderr.puts line
        end
      end

      def clear
        return unless @tty && @line_drawn
        $stderr.print "\r\e[2K"
        $stderr.flush
        @line_drawn = false
      end

      def finish(event)
        clear
        return if @quiet
        skipped = event["skipped"].to_i
        suffix = skipped.positive? ? " (#{skipped} skipped)" : ""
        warn("done: #{event["count"]} orders#{suffix}")
      end

      private

      def bar(i, n)
        return "[" + ("░" * BAR_WIDTH) + "]" if n.to_i.zero?
        filled = (i.to_f / n * BAR_WIDTH).round
        "[" + ("█" * filled) + ("░" * (BAR_WIDTH - filled)) + "]"
      end

      def format_eta(i, n)
        return "ETA --:--" if @start_time.nil? || i.to_i <= 0 || n.to_i <= 0
        elapsed = Time.now - @start_time
        remaining = (elapsed / i) * (n - i)
        return "ETA --:--" if remaining.nan? || remaining.infinite? || remaining < 0
        secs = remaining.to_i
        if secs >= 3600
          format("ETA %d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
        else
          format("ETA %2d:%02d", secs / 60, secs % 60)
        end
      end
    end

    private

    # A worker `warn` is the only signal that a selector chain has rotted or
    # that a page silently degraded — exactly the cases where the output still
    # looks complete because every field fails to null independently. Hiding
    # that behind -v means the person who needs it is the one who never sees
    # it. `info` is routine progress and stays behind the flag.
    def log_event(event)
      level = event["level"] || "info"
      return unless @verbose || level == "warn"
      warn("[worker:#{level}] #{event["msg"]}")
    end

    def live_error(event)
      case event["kind"]
      when "not_logged_in", "blocked" then event["msg"]
      else "live lookup failed: #{event["msg"]}"
      end
    end

    def run(request, script: "fetch.py")
      cmd = python_cmd(script)
      Open3.popen3(*cmd, chdir: PYWORKER) do |stdin, stdout, stderr, wait|
        stdin.write(JSON.generate(request) + "\n")
        # Keep stdin open — worker may need to write OTP/prompt responses.

        err_thread = Thread.new do
          stderr.each_line { |l| warn(l.chomp) if @verbose }
        rescue IOError
          # stderr was closed during shutdown; that's fine.
        end

        saw_error = false
        stdout.each_line do |line|
          line = line.strip
          next if line.empty?
          event = parse_event(line)
          next unless event

          case event["event"]
          when "otp_required"
            answer = prompt_secret(event["prompt"] || "OTP")
            stdin.write(answer + "\n")
          when "prompt"
            answer = prompt_text(event)
            stdin.write(answer + "\n")
          else
            yield event
            saw_error = true if event["event"] == "error"
            # `break`, not `return`: returning from here exits the popen3 block
            # and skips the exit-status check below, so a worker that emitted
            # `done` and then died during teardown looked like a clean success.
            break if event["event"] == "done" || event["event"] == "error"
          end
        end

        begin
          stdin.close
        rescue IOError, Errno::EPIPE
          # already closed
        end
        # Drain whatever the worker wrote after `done` so it can't block on a
        # full pipe while we wait for it to exit.
        begin
          stdout.read
        rescue IOError
          # already closed
        end
        err_thread.join
        status = wait.value
        # An `error` event already carries a better message than the exit code.
        if !status.success? && !saw_error
          raise Error, "python worker exited #{status.exitstatus}"
        end
      end
    end

    def parse_event(line)
      JSON.parse(line)
    rescue JSON::ParserError
      warn("[worker] non-JSON output: #{line}") if @verbose
      nil
    end

    def python_cmd(script)
      # Prefer uv-managed venv if present; otherwise fall back to plain python3
      venv = File.join(PYWORKER, ".venv", "bin", "python")
      return [venv, script] if File.executable?(venv)
      ["python3", script]
    end

    def prompt_text(event)
      msg = event["prompt"].to_s
      choices = event["choices"] || []
      choices.each { |c| $stderr.puts(c) }
      $stderr.print("--> #{msg}: ")
      $stderr.flush
      $stdin.gets.to_s.chomp
    end

    def prompt_secret(msg)
      $stderr.print("--> #{msg}: ")
      $stderr.flush
      if $stdin.respond_to?(:noecho) && $stdin.tty?
        code = $stdin.noecho(&:gets).to_s.chomp
        $stderr.puts
        code
      else
        $stdin.gets.to_s.chomp
      end
    end
  end
end
