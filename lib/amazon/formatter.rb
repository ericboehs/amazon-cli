require "json"

module Amazon
  class Formatter
    BOLD = "\e[1m"
    DIM  = "\e[2m"
    RST  = "\e[0m"

    def initialize(json: false, color: $stdout.tty?)
      @json = json
      @color = color
    end

    def list(rows)
      return puts(JSON.pretty_generate(rows)) if @json
      return puts("(no orders — run `amazon sync`)") if rows.empty?

      headers = %w[date order_id total status]
      data = rows.map { |r| [r["date"], r["order_id"], format_money(r["total"]), r["status"] || ""] }
      print_table(headers, data)
    end

    def show(order)
      return puts(JSON.pretty_generate(order)) if @json
      return puts("(not found)") unless order

      puts "#{bold("Order")} #{order["order_id"]}"
      puts "  Placed:  #{order["order_placed"]}"
      puts "  Total:   #{format_money(order["grand_total"])}"
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

    def search(orders, query)
      return puts(JSON.pretty_generate(orders)) if @json
      return puts("(no matches for #{query.inspect})") if orders.empty?

      orders.each do |o|
        items = o["items"] || []
        first = items.find { |i| i["title"].to_s.downcase.include?(query.downcase) } || items.first
        title = first ? first["title"] : "(no items)"
        line = "#{o["order_placed"]}  #{o["order_id"]}  #{format_money(o["grand_total"])}  #{title}"
        puts line
      end
    end

    private

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

    def bold(s) = @color ? "#{BOLD}#{s}#{RST}" : s
    def dim(s)  = @color ? "#{DIM}#{s}#{RST}"  : s
  end
end
