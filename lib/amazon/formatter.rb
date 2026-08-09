require "json"
require "date"

module Amazon
  class Formatter
    BOLD  = "\e[1m"
    DIM   = "\e[2m"
    GREEN = "\e[32m"
    RED   = "\e[31m"
    RST   = "\e[0m"

    def initialize(json: false, color: $stdout.tty?)
      @json = json
      @color = color
    end

    def list(rows)
      return puts(JSON.pretty_generate(rows)) if @json
      return puts("(no orders — run `amazon sync`)") if rows.empty?

      headers = %w[date order_id total status]
      data = rows.map do |r|
        # A "~" beats a number that silently excludes tax (or tax and shipping)
        # looking exactly as authoritative as one that doesn't.
        total = format_money(r["total"])
        total = "~#{total}" if Store.estimated_total?(r) && !total.empty?
        [r["date"], r["order_id"], total, r["status"] || ""]
      end
      print_table(headers, data)
      if rows.any? { |r| Store.estimated_total?(r) }
        puts dim("~ total is estimated: Amazon didn't report a grand total, so this excludes tax (and, from a subtotal, shipping)")
      end
    end

    def show(order)
      return puts(JSON.pretty_generate(order)) if @json
      return puts("(not found)") unless order

      puts "#{bold("Order")} #{order["order_id"]}"
      puts "  Placed:  #{order["order_placed"]}"
      puts "  Total:   #{format_money(effective_total(order))}"
      puts "  Ship to: #{order["ship_to"]}" if order["ship_to"]
      puts "  Payment: #{order["payment_method"]} #{order["payment_method_last_4"] ? "•••• #{order["payment_method_last_4"]}" : ""}".rstrip if order["payment_method"]
      if (link = order["order_details_link"])
        puts "  Link:    #{link}"
      end

      items = order["items"] || []
      puts
      puts bold("Items (#{items.size})")
      items.each do |it|
        title = it["title"].to_s
        qty   = it["quantity"] ? "x#{it["quantity"]} " : ""
        price = it["price"] ? " — #{format_money(it["price"])}" : ""
        puts "  • #{qty}#{title}#{price}"
        puts dim("    #{it["link"]}") if it["link"]
      end

      shipments = order["shipments"] || []
      if shipments.any?
        puts
        puts bold("Shipments")
        shipments.each do |s|
          status = s["delivery_status"] || "(unknown)"
          puts "  • #{status}"
          puts dim("    #{s["tracking_link"]}") if s["tracking_link"]
        end
      end
    end

    # --- live output ---------------------------------------------------

    def item(data)
      return puts(JSON.pretty_generate(data)) if @json
      return puts("(not found)") unless data

      puts bold(data["title"].to_s)
      puts dim("#{data["asin"]}  ·  #{data["url"]}")
      puts

      price = data["price"]
      line = "  Price:     #{price ? bold(format_money(price)) : "(no buybox price)"}"
      if (list = data["list_price"]) && price
        line += dim("  was #{format_money(list)}  (-#{format_money(list - price)})")
      end
      puts line
      puts "  Stock:     #{data["availability"]}" if data["availability"]
      puts "  Delivery:  #{delivery_phrase(data)}" if data["delivery_raw"]
      puts "  Seller:    #{data["seller"]}" if data["seller"]
      if data["rating"]
        reviews = data["reviews"] ? " (#{comma(data["reviews"])} ratings)" : ""
        puts "  Rating:    #{data["rating"]}★#{dim(reviews)}"
      end
      puts "  Coupon:    #{data["coupon"]}" if data["coupon"]

      purchases = data["purchases"] || []
      return if purchases.empty?

      puts
      puts bold("You've bought this #{purchases.size}x")
      purchases.each do |p|
        delta = price_delta(price, p["price"])
        puts "  #{p["date"]}  #{format_money(p["price"]).rjust(9)}#{delta}  #{dim(p["order_id"])}"
      end
    end

    # Full `amazon reviews` view: histogram, trust signals, complaint themes,
    # and — with verbatim: true — the review text itself.
    def reviews(data, analysis, verbatim: false, limit: nil)
      return puts(JSON.pretty_generate(data.merge("analysis" => analysis))) if @json
      return puts("(not found)") unless data

      puts bold(data["title"].to_s)
      puts dim("#{data["asin"]}  ·  #{data["url"]}")
      puts

      rating = data["rating"]
      count = data["reviews"]
      header = rating ? "#{rating}★" : "(no rating)"
      header += dim("  #{comma(count)} ratings") if count
      puts "  Overall:   #{bold(header)}"
      if (adjusted = analysis["adjusted_rating"])
        puts "  Adjusted:  #{bold("#{adjusted}★")}#{dim("  verified, uncompensated reviews in this sample only")}"
      end
      if (verified = analysis["verified_pct"])
        puts "  Verified:  #{verified}% of #{analysis["sample_size"]} sampled"
      end
      puts "  Vine:      #{analysis["vine_count"]} review(s) from Amazon's Vine programme" if analysis["vine_count"].to_i.positive?

      histogram(data["histogram"])
      trust(analysis)
      complaint_themes(analysis["themes"])
      verbatim_reviews(data["reviews_sample"] || [], limit) if verbatim
    end

    # Condensed block appended under `amazon item --reviews`.
    def reviews_summary(analysis)
      return if @json

      puts
      score = analysis["score"]
      return puts(dim("  Reviews:   not enough data to assess")) unless score

      puts "  Reviews:   #{level_phrase(analysis)}"
      top = analysis["signals"].select { |s| s["points"].to_i.positive? }
                               .max_by(2) { |s| s["points"] }
      top.each { |s| puts dim("             · #{s["detail"]}") }
      themes = analysis["themes"].first(3).map { |t| t["phrase"] }
      puts dim("             complaints: #{themes.join(", ")}") if themes.any?
    end

    def live_search(results, query)
      return puts(JSON.pretty_generate(results)) if @json
      return puts("(no live results for #{query.inspect})") if results.empty?

      # "   $12.99  B0747R1M51  " is 23 columns; leave room for a sponsored tag.
      title_width = [term_width - 23 - 12, 30].max

      results.each do |r|
        tag = r["sponsored"] ? dim(" [sponsored]") : ""
        title = truncate(r["title"], title_width)
        puts "#{bold(format_money(r["price"]).rjust(9))}  #{dim(r["asin"])}  #{title}#{tag}"

        meta = []
        meta << "#{r["rating"]}★" if r["rating"]
        meta << "(#{comma(r["reviews"])})" if r["reviews"]
        meta << delivery_phrase(r) if r["delivery_raw"]
        puts dim("           #{meta.join(" · ")}") unless meta.empty?

        if (prior = r["prior_purchase"])
          delta = price_delta(r["price"], prior["price"])
          puts "           ↳ bought #{prior["date"]} for #{format_money(prior["price"])}#{delta}"
        end
        puts
      end
    end

    def search(orders, query)
      return puts(JSON.pretty_generate(orders)) if @json
      return puts("(no matches for #{query.inspect})") if orders.empty?

      orders.each do |o|
        items = o["items"] || []
        first = items.find { |i| i["title"].to_s.downcase.include?(query.downcase) } || items.first
        title = first ? first["title"] : "(no items)"
        line = "#{o["order_placed"]}  #{o["order_id"]}  #{format_money(effective_total(o))}  #{title}"
        puts line
      end
    end

    private

    HIST_WIDTH = 24

    def histogram(hist)
      return if hist.nil? || hist.empty?

      puts
      puts bold("Rating distribution")
      5.downto(1) do |star|
        # A drawn bar of 0% is a claim about the product. A row the scraper
        # never read is not that claim, and printing it as one is how a
        # half-read table came to look like a five-star wall.
        pct = hist[star.to_s]
        if pct.nil?
          puts "  #{star}★ #{" " * HIST_WIDTH}   #{dim("?")}"
          next
        end
        pct = pct.to_i
        bar = "█" * ((pct / 100.0) * HIST_WIDTH).round
        puts "  #{star}★ #{bar.ljust(HIST_WIDTH)} #{pct.to_s.rjust(3)}%"
      end
    end

    # The score is deliberately never printed alone — every point it carries is
    # itemised underneath, including the checks that could not be run.
    def trust(analysis)
      puts
      puts bold("Authenticity")
      puts "  #{level_phrase(analysis)}"

      analysis["signals"].each do |s|
        if s["points"].nil?
          puts dim("    ?  #{s["label"]}: #{s["detail"]}")
        else
          mark = s["points"].positive? ? red("!") : green("✓")
          weight = s["points"].positive? ? dim(" [+#{s["points"]}/#{s["max"]}]") : ""
          puts "    #{mark}  #{s["label"]}: #{s["detail"]}#{weight}"
        end
      end
      deeper = if analysis["exhausted"]
                 "That is everything Amazon would serve for this listing."
               else
                 "Use --pages 3 for a deeper sample."
               end
      puts dim("    Heuristics on a #{analysis["sample_size"]}-review sample, not a verdict. #{deeper}")
    end

    def level_phrase(analysis)
      score = analysis["score"]
      return dim("not enough data to assess") unless score

      label = case analysis["level"]
              when "low"      then green("low risk")
              when "some"     then "some risk"
              when "elevated" then red("elevated risk")
              else red("high risk")
              end
      "#{label} #{dim("(#{score}/100, #{analysis["confidence"]} confidence)")}"
    end

    def complaint_themes(themes)
      return if themes.nil? || themes.empty?

      puts
      puts bold("What critical reviews mention")
      themes.each { |t| puts "  · #{t["phrase"]} #{dim("(#{t["count"]}x)")}" }
    end

    def verbatim_reviews(reviews, limit)
      shown = limit ? reviews.first(limit) : reviews
      return if shown.empty?

      puts
      puts bold("Reviews (#{shown.size} of #{reviews.size})")
      shown.each do |r|
        badges = []
        badges << "verified" if r["verified"]
        badges << "vine" if r["vine"]
        stars = r["rating"] ? "#{r["rating"]}★" : "?★"
        puts
        puts "  #{bold(stars)}  #{r["title"]}"
        meta = [r["date"], r["author"], *badges].compact.reject(&:empty?)
        meta << "#{r["helpful_votes"]} helpful" if r["helpful_votes"]
        puts dim("      #{meta.join(" · ")}")
        wrap(r["body"], term_width - 8).each { |line| puts "      #{line}" }
      end
    end

    def wrap(text, width)
      words = text.to_s.split
      return [] if words.empty?

      words.each_with_object([+""]) do |word, lines|
        if lines.last.empty?
          lines.last << word
        elsif lines.last.length + word.length + 1 <= width
          lines.last << " " << word
        else
          lines << +word
        end
      end
    end

    # Prefer the parsed ISO date (stable, sortable) and fall back to whatever
    # blurb Amazon rendered.
    def delivery_phrase(data)
      iso = data["delivery_date"]
      return truncate(data["delivery_raw"], 60) unless iso

      d = Date.parse(iso)
      label = case (d - Date.today).to_i
              when 0 then "today"
              when 1 then "tomorrow"
              else d.strftime("%a, %b %-d")
              end
      free = data["delivery_raw"].to_s.include?("FREE") ? "FREE " : ""
      "#{free}delivery #{label}"
    rescue Date::Error
      truncate(data["delivery_raw"], 60)
    end

    # " (-$5.00)" when the live price is below what you paid, " (+$2.00)" above.
    def price_delta(current, paid)
      return "" unless current.is_a?(Numeric) && paid.is_a?(Numeric)

      diff = (current - paid).round(2)
      return dim("  (same)") if diff.zero?
      diff.negative? ? green("  (-#{format_money(diff.abs)})") : red("  (+#{format_money(diff)})")
    end

    def comma(n) = n.to_s.reverse.scan(/\d{1,3}/).join(",").reverse

    def term_width
      @term_width ||= (ENV["COLUMNS"] || (`tput cols 2>/dev/null`.to_i.nonzero?) || 100).to_i
    end

    def truncate(str, len)
      s = str.to_s
      s.length > len ? "#{s[0, len - 1]}…" : s
    end

    def effective_total(order)
      field = Store::TOTAL_FIELDS.find { |f| order[f] }
      field && order[field]
    end

    def print_table(headers, rows)
      cols = headers.size
      widths = Array.new(cols) { |i| [headers[i].length, *rows.map { |r| r[i].to_s.length }].max }
      fmt = widths.map { |w| "%-#{w}s" }.join("  ")
      puts bold(fmt % headers)
      rows.each { |r| puts(fmt % r) }
    end

    def format_money(val)
      return "" if val.nil?
      return val if val.is_a?(String) && !val.match?(/\A-?\d/)
      sprintf("$%.2f", val.to_f)
    end

    def bold(s)  = @color ? "#{BOLD}#{s}#{RST}"  : s
    def dim(s)   = @color ? "#{DIM}#{s}#{RST}"   : s
    def green(s) = @color ? "#{GREEN}#{s}#{RST}" : s
    def red(s)   = @color ? "#{RED}#{s}#{RST}"   : s
  end
end
