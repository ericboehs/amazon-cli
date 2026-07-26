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
