require "json"
require "open3"
require "io/console"

module Amazon
  class Worker
    class Error < StandardError; end

    PYWORKER = File.expand_path("../../pyworker", __dir__)

    # How much of the worker's stderr to keep for a failure report. A Python
    # traceback is a couple of dozen lines and the interesting end is the last
    # one, while Playwright can write megabytes before it falls over — so this
    # keeps the tail rather than the head, and keeps it bounded so that
    # reporting a crash never becomes the failure itself.
    STDERR_TAIL_LINES = 40

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
          # Only erase the bar for a message that is actually going to land on
          # top of it. Same predicate `log_event` decides with, because the
          # side effect and the decision drifting apart is what produced a bar
          # erased and redrawn with nothing in between.
          progress.clear if printable?(event)
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
    #
    # `reviews:` folds the rating histogram and the product page's own review
    # block into the same page load. `review_pages:` walks /product-reviews/ for
    # more, at one page load each.
    def item(asin, reviews: false, review_pages: 0, sort: "helpful")
      data = nil
      request = { action: "item", asin: asin }
      request.merge!(reviews: true, review_pages: review_pages, sort: sort) if reviews
      run(request, script: "live.py") do |event|
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
    #
    # Deliberately does not consult `@quiet`. -q suppresses non-essential
    # output, and by the argument above a warn is the essential case; the item,
    # search, and reviews paths used to pass `quiet:` in here anyway, where it
    # reached nothing but read as though it did. `@quiet` now belongs to
    # `Progress` alone, which only the sync path builds.
    def log_event(event)
      return unless printable?(event)
      warn("[worker:#{event["level"] || "info"}] #{event["msg"]}")
    end

    def printable?(event)
      @verbose || loud?(event["level"] || "info")
    end

    # Levels quiet enough to hide behind -v. Everything else prints, which is
    # the asymmetry rather than the ordering: this used to be `level == "warn"`,
    # an equality test wearing a threshold's clothes, and it made `error`
    # *quieter* than `warn` — backwards from what any author reaching for the
    # more severe word would assume, and silent about being backwards. A typo'd
    # `warning` vanished the same way. Unrecognized resolves loud for the same
    # reason `classify_failure` resolves an unrecognized exception transient:
    # the cost of a needless line is a line, and the cost of the other
    # direction is the message that mattered.
    ROUTINE_LEVELS = %w[debug trace info].freeze

    def loud?(level) = !ROUTINE_LEVELS.include?(level)

    # `fetch.py` puts a full traceback on its error events as `trace`, and
    # nothing here read it: `sync` takes `msg`, `live_error` takes `kind` and
    # `msg`. So the stack naming which parser broke was captured, serialized,
    # piped, parsed and dropped — at every verbosity, which made -v useless as
    # an escape hatch. Unconditional for the same reason the stderr tail is:
    # the run you need it for is the one that already happened.
    def log_trace(event)
      trace = event["trace"].to_s
      return if trace.empty?
      warn(trace.lines.map { |l| "[worker:trace] #{l.chomp}" }.join("\n"))
    end

    def live_error(event)
      case event["kind"]
      when "not_logged_in", "blocked" then event["msg"]
      else "live lookup failed: #{event["msg"]}"
      end
    end

    def run(request, script: "fetch.py")
      cmd = python_cmd(script)
      tail = []
      Open3.popen3(*cmd, chdir: PYWORKER) do |stdin, stdout, stderr, wait|
        stdin.write(JSON.generate(request) + "\n")
        # Keep stdin open — worker may need to write OTP/prompt responses.

        reader_error = nil
        err_thread = Thread.new do
          stderr.each_line { |l| forward_stderr(tail, l.chomp) }
        rescue IOError
          # stderr was closed during shutdown; that's fine.
        rescue StandardError => e
          # Recorded rather than raised. `Thread#join` re-raises into the main
          # thread, and it does so *before* the exit-status check below — so a
          # failure while writing the diagnostics down replaced the failure
          # they were describing, and handed the caller an exception pointing
          # at the logging path. The forwarding channel must never preempt the
          # thing it forwards.
          reader_error = e
        end

        begin
          saw_error = false
          malformed = 0
          stdout.each_line do |line|
            line = line.strip
            next if line.empty?
            event = parse_event(line)
            if event.nil?
              malformed += 1
              next
            end

            case event["event"]
            when "otp_required"
              answer = prompt_secret(event["prompt"] || "OTP")
              stdin.write(answer + "\n")
            when "prompt"
              answer = prompt_text(event)
              stdin.write(answer + "\n")
            else
              # Before the yield, not after: the live callers raise from inside
              # it, and the traceback is worth most on exactly that path.
              log_trace(event) if event["event"] == "error"
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
          # Said before the status check rather than instead of it, so it reads
          # as context for whichever way the run ends: the stderr tail below is
          # short by however much the reader missed.
          if reader_error
            warn("[worker:stderr] forwarding the worker's stderr failed: " \
                 "#{reader_error.class}: #{reader_error.message}")
          end
          status = wait.value
          # An `error` event already carries a better message than the exit code.
          if !status.success? && !saw_error
            raise Error, "python worker exited #{status.exitstatus}#{malformed_note(malformed)}"
          end
        ensure
          # The callers raise from inside the yielded block, which unwinds
          # straight past the join above — abandoning the reader thread along
          # with the buffered stderr that explains what went wrong. Bounded on
          # purpose: a worker still writing must not hold the CLI open, and
          # popen3's own teardown closes the pipes and frees the reader.
          err_thread.join(2)
        end
      end
    rescue Error => e
      # Every failure out of `run` gets the worker's own last words attached
      # here rather than at each raise site, because the ones raised from inside
      # the yielded block never reach a raise site we control.
      #
      # live.py prints the traceback to stderr and then emits an `error` event
      # naming only the exception class — "AttributeError: 'NoneType' object has
      # no attribute 'count'" with no hint which selector rotted. The two halves
      # are only useful together, and gating stderr behind -v guaranteed that
      # the person diagnosing a crash never saw it: the run they need it for is
      # the run that already happened. An expired session writes nothing to
      # stderr, so its `run: amazon login` message stays exactly as composed.
      report = stderr_report(tail)
      raise if report.empty?
      raise Error, "#{e.message}#{report}"
    end

    # Tagged like every other line this class writes: under -v these interleave
    # with the progress bar, and an untagged stream in a pasted log is one
    # nobody can attribute.
    def forward_stderr(tail, line)
      warn("[worker:stderr] #{line}") if @verbose
      tail << line
      tail.shift while tail.size > STDERR_TAIL_LINES
    end

    def stderr_report(tail)
      return "" if tail.empty? || @verbose
      "\nworker stderr (last #{tail.size} line#{"s" unless tail.size == 1}):\n#{tail.join("\n")}"
    end

    # Unconditional, unlike `log_event`, and deliberately not a log level: this
    # is the event channel itself breaking. A half-written line is what a worker
    # killed mid-`emit` leaves behind, so it is the highest-information moment
    # there is — and -v is a flag you can only set on the run before the one
    # that failed. Stray stdout from a chatty library still doesn't abort the
    # run; it just says so once.
    def parse_event(line)
      JSON.parse(line)
    rescue JSON::ParserError
      warn("[worker] non-JSON output: #{bounded(line)}")
      nil
    end

    # A truncated event can be the head of a very large one. Same reasoning as
    # STDERR_TAIL_LINES: reporting the break must not become the failure.
    JUNK_LINE_LIMIT = 200

    def bounded(line)
      return line if line.length <= JUNK_LINE_LIMIT
      "#{line[0, JUNK_LINE_LIMIT]}… (#{line.length} chars)"
    end

    # Named at exit as well as where it happened, because by then the broken
    # line has scrolled past everything the worker printed on its way down, and
    # a bare "exited 1" reads as a failure the worker chose and described.
    def malformed_note(count)
      return "" if count.zero?
      " after #{count} unparseable line#{"s" unless count == 1} on the event channel"
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
