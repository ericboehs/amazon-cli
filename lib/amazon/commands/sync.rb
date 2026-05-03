require "date"
require "open3"
require "time"

module Amazon
  module Commands
    class Sync
      def initialize(global)
        @global = global
      end

      def run(argv)
        years = nil
        full_details = true
        full_resync = false
        while (a = argv.shift)
          case a
          when "--year"  then years = [Integer(argv.shift)]
          when "--years" then years = argv.shift.split(",").map { |y| Integer(y) }
          when "--no-full-details" then full_details = false
          when "--full"  then full_resync = true
          when "-h", "--help"
            puts help_text
            return 0
          else
            warn "unknown sync option: #{a}"
            return 2
          end
        end

        config = Amazon::Config.load
        years ||= default_years(config)

        if cookies_authenticated?
          password = "unused-have-cookies"
          otp_secret = nil
          log "using cached browser session (skipping 1Password prompt)"
        else
          unless config.password_op_ref
            warn "config: password_op_ref must be set, or run `amazon login` first"
            return 2
          end
          password = fetch_password(config.password_op_ref)
          otp_secret = config.otp_op_ref ? fetch_password(config.otp_op_ref) : nil
        end

        store = Amazon::Store.new
        known_ids = full_resync ? [] : store.index["orders"].keys

        log "syncing years: #{years.join(", ")}#{full_resync ? " (full re-sync)" : " (skipping #{known_ids.size} known)"}"
        worker = Amazon::Worker.new(verbose: @global[:verbose], quiet: @global[:quiet])
        orders = worker.sync(
          email: config.email,
          password: password,
          years: years,
          full_details: full_details,
          otp_secret: otp_secret,
          rate_limit: config.rate_limit,
          known_order_ids: known_ids
        )

        orders.each { |o| store.write_order(o) }
        store.commit_index!

        append_sync_log(years, orders.size)
        log "wrote #{orders.size} orders to #{Amazon::Config.orders_dir}"
        0
      rescue Amazon::Worker::Error => e
        if e.message.include?("Captcha") || e.message.include?("CaptchaForm")
          warn "amazon: login blocked by Amazon CAPTCHA."
          warn "  amazon-orders can't solve image/JS captchas. To clear it:"
          warn "    1) Open https://www.amazon.com in a browser and log in manually."
          warn "    2) If prompted, complete the captcha at"
          warn "       https://www.amazon.com/errors/validateCaptcha"
          warn "    3) Wait a few minutes (Amazon sometimes needs longer), then retry."
          warn "  Setting `otp_op_ref` in config (TOTP secret) reduces captcha frequency."
          1
        else
          raise
        end
      end

      private

      def default_years(config)
        n = config.default_year_window || 2
        cur = Date.today.year
        ((cur - n + 1)..cur).to_a
      end

      def cookies_authenticated?
        path = Amazon::Config.cache_dir.join("cookies.json")
        return false unless path.exist?
        data = JSON.parse(path.read) rescue {}
        data.key?("x-main")
      end

      def fetch_password(ref)
        out, err, status = Open3.capture3("bash", "-lc", "op signin --account my >/dev/null && op read #{shellword(ref)}")
        unless status.success?
          raise "op read failed for #{ref}: #{err.strip}"
        end
        out.chomp
      end

      def shellword(s)
        # Refs like op://Personal/Amazon/password are safe; still quote defensively.
        "'" + s.gsub("'", "'\\''") + "'"
      end

      def append_sync_log(years, count)
        path = Amazon::Config.sync_log_path
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, "a") do |f|
          f.puts "#{Time.now.utc.iso8601}  years=#{years.join(",")}  count=#{count}"
        end
      end

      def log(msg)
        warn(msg) unless @global[:quiet]
      end

      def help_text
        <<~HELP
          Usage: amazon sync [options]

          Options:
            --year YYYY          Sync a single year
            --years 2024,2025    Sync multiple years (comma-separated)
            --no-full-details    Skip per-order detail fetches (faster, fewer fields)
            --full               Re-fetch every order (default: skip orders already in store)
        HELP
      end
    end
  end
end
