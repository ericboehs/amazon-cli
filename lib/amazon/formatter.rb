require "json"
require "date"

module Amazon
  class Formatter
    BOLD  = "\e[1m"
    DIM   = "\e[2m"
    GREEN = "\e[32m"
    RED   = "\e[31m"
    YELLOW = "\e[33m"
    RST   = "\e[0m"

    def initialize(json: false, color: $stdout.tty?)
      @json = json
      @color = color
    end

    def list(rows, scope:)
      return puts(JSON.pretty_generate(rows)) if @json
      return puts(empty_note("orders", scope)) if rows.empty?

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
      if purchases.empty?
        # Printing nothing here is a claim: "you have never bought this." On an
        # archive that was never synced it means "nothing was checked", which is
        # the opposite claim wearing the same silence. `purchases_searched` is
        # the denominator, so say it out loud.
        searched = data["purchases_searched"]
        puts dim("  History:   #{purchase_note(searched)}") unless searched.nil?
        return
      end

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
        # The percentage is over the cards whose badge we could read, so when
        # that is fewer than we sampled the line has to say so — quoting a
        # share of four as "of 5 sampled" overstates what was actually read.
        sampled = analysis["sample_size"]
        readable = analysis["verified_readable"] || sampled
        scope = readable == sampled ? "#{sampled} sampled" : "#{readable} readable of #{sampled} sampled"
        puts "  Verified:  #{verified}% of #{scope}"
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

    def search(orders, query, scope:)
      return puts(JSON.pretty_generate(orders)) if @json
      return puts(empty_note("matches for #{query.inspect}", scope)) if orders.empty?

      orders.each do |o|
        items = o["items"] || []
        first = items.find { |i| i["title"].to_s.downcase.include?(query.downcase) } || items.first
        title = first ? first["title"] : "(no items)"
        line = "#{o["order_placed"]}  #{o["order_id"]}  #{format_money(effective_total(o))}  #{title}"
        puts line
      end
    end

    # --- subscribe & save ----------------------------------------------

    # `total` is what Amazon says the account holds; `loaded_all` is whether we
    # asked for all of it. Both are needed to say anything honest about a short
    # list: 30 rows out of 59 is a page, 30 out of 30 is the whole thing, and
    # the rows cannot tell the two apart.
    def subscriptions(rows, total: nil, loaded_all: false, thumbnails: nil)
      return puts(JSON.pretty_generate(rows)) if @json
      return puts("(no Subscribe & Save subscriptions)") if rows.empty?

      thumbnails ? subscription_cards(rows, thumbnails) : subscription_table(rows)
      note = subscription_count_note(rows.size, total, loaded_all)
      puts dim(note) if note
    end

    # `limit` trims what prints, never what's returned: --json is a data
    # interface and a caller piping to jq did not ask for Amazon's next three.
    def deliveries(cards, limit: nil, thumbnails: nil)
      return puts(JSON.pretty_generate(cards)) if @json
      return puts("(no scheduled Subscribe & Save deliveries)") if cards.empty?

      shown = limit ? cards.first(limit) : cards
      # One warm-up for the whole screen rather than one per delivery: the
      # downloads are the slow part and they don't depend on each other.
      thumbnails&.prefetch(shown.flat_map { |c| Array(c["items"]).map { |i| i["image"] } })
      shown.each_with_index do |card, i|
        puts if i.positive?
        puts delivery_heading(card)
        # Only ever set on the delivery that is next out the door, and it is
        # the one fact on this screen with a deadline attached.
        puts "  #{bold(labelled(card, "editable_until", "Last day to edit:"))}" if card["editable_until"]
        puts dim("  #{labelled(card, "savings", "Savings:")}") if card["savings"]
        puts dim("  #{card["tiering"]}") if card["tiering"]
        thumbnails ? delivery_item_cards(card, thumbnails) : delivery_items(card)
      end
      remaining = cards.size - shown.size
      return unless remaining.positive?

      puts dim("#{remaining} more #{remaining == 1 ? "delivery" : "deliveries"} scheduled — pass --all")
    end

    # One subscription, from the edit modal. Laid out as labelled lines rather
    # than a table: it is one record with a dozen fields, half of which are
    # sentences.
    def subscription(detail, thumbnails: nil)
      return puts(JSON.pretty_generate(detail)) if @json

      head = [bold(detail["title"] || "(untitled subscription)")]
      head << dim(detail["variation"]) if detail["variation"]
      rows = subscription_detail_rows(detail)
      width = rows.map { |label, _| label.length }.max || 0
      fields = rows.map { |label, value| "  #{dim(label.ljust(width))}  #{value}" }

      unless thumbnails
        puts head
        puts
        return puts(fields)
      end

      thumbnails.prefetch([detail["image"]])
      beside_image(thumbnails.block(detail["image"]), head + [""] + fields, thumbnails)
    end

    # The result of a skip, confirmed or merely contemplated.
    def skip(result)
      return puts(JSON.pretty_generate(result)) if @json

      title = result["title"] || result["product"] || "(untitled subscription)"
      when_ = result["delivery_label"] || result["delivery_date"]
      if result["confirmed"]
        puts "#{green("skipped")} #{bold(title)}"
        puts dim("  from the #{when_} delivery") if when_
        puts skip_verdict(result["verified"])
      else
        puts "#{bold("would skip")} #{bold(title)}"
        puts dim("  from the #{when_} delivery") if when_
        # Amazon's warning, not ours. "Skip" sounds harmless; their own dialog
        # is the thing that says it may cost you a coupon.
        puts "  #{yellow(result["warning"])}" if result["warning"]
        puts dim("  nothing changed — pass --yes to skip it")
      end
    end

    private

    # A click that returned without error is not evidence, so the three
    # outcomes stay three: it left the delivery, it didn't, or we couldn't
    # look. The middle one is the only failure, and it must not be reported in
    # the same words as the third.
    def skip_verdict(verified)
      case verified
      when true  then dim("  confirmed — it's no longer in that delivery")
      when false then red("  but it is still in that delivery — check Amazon")
      else dim("  Amazon accepted it; couldn't re-read the delivery to confirm")
      end
    end

    def subscription_table(rows)
      headers = %w[next every qty price subscription_id item]
      # Everything but the title is fixed width; give the title the rest.
      title_width = [term_width - 74, 24].max
      data = rows.map do |r|
        [
          r["next_delivery_label"] || "?",
          interval_phrase(r),
          (r["quantity"] || "?").to_s,
          # Blank, not $0.00, for a delivery Amazon hasn't priced yet. The
          # discount is what it has committed to for those.
          subscription_price(r),
          r["subscription_id"],
          truncate(r["title"], title_width)
        ]
      end
      print_table(headers, data)
    end

    # With a photograph in the left margin the table has to go. Six columns is
    # a table; six columns and a picture is a wall. Each subscription becomes a
    # block instead, and the columns become a sentence.
    def subscription_cards(rows, thumbnails)
      thumbnails.prefetch(rows.map { |r| r["image"] })
      width = [term_width - thumbnails.cols - 4, 24].max
      rows.each_with_index do |r, i|
        puts if i.positive?
        lines = [bold(truncate(r["title"], width))]
        lines << dim(truncate(r["variation"], width)) if r["variation"]
        lines << subscription_summary(r)
        lines << dim(r["subscription_id"].to_s)
        beside_image(thumbnails.block(r["image"]), lines, thumbnails)
      end
    end

    # The table's columns rejoined into a sentence: what ships next, how often,
    # how many, and what it costs.
    def subscription_summary(row)
      parts = [row["next_delivery_label"] || "?", "every #{interval_phrase(row)}"]
      parts << "qty #{row["quantity"]}" if row["quantity"] && row["quantity"] != 1
      line = parts.join(dim(" · "))
      price = subscription_price(row)
      price.empty? ? line : "#{line}#{dim(" · ")}#{price}"
    end

    # Text to the right of a picture, without knowing which graphics protocol
    # drew the picture.
    #
    # The text goes down first and the image is painted over its left margin
    # afterwards, which looks backwards and isn't: printing the text first is
    # what scrolls the terminal, so by the time the image is drawn the rows it
    # needs exist. Drawing first at the bottom of a screen clips the photo
    # against the last line.
    def beside_image(blob, lines, thumbnails)
      body = lines.dup
      body << "" while body.size < thumbnails.rows
      indent = " " * (thumbnails.cols + 2)

      # Autowrap off, and the cursor parked after the text rather than counted
      # back to.
      #
      # Ruby counts "Clorox®" as six characters and the terminal draws it in
      # seven cells, so a line this side believes fits can wrap; and chafa fits
      # the photo *within* the box rather than filling it, so a wide product
      # shot comes back three rows tall instead of six. Either one breaks
      # arithmetic that counts rows. Saving the position after the text and
      # restoring it after the image returns to where the text ended no matter
      # what the image did in between.
      print "\e[?7l"
      begin
        body.each { |l| puts l.empty? ? "" : "#{indent}#{l}" }
        return if blob.nil?

        print "\e7\e[#{body.size}A"
        print blob
        print "\e8"
      ensure
        print "\e[?7h"
      end
    end

    def subscription_price(row)
      return format_money(row["price"]) if row["price"]
      row["discount"] ? dim(row["discount"].to_s.sub(/\ASaving /, "")) : ""
    end

    def subscription_detail_rows(detail)
      rows = []
      rows << ["next delivery", next_delivery_line(detail)] if detail["next_delivery_label"]
      rows << ["schedule", detail["schedule_raw"]] if detail["schedule_raw"]
      rows << ["discount", green(detail["discount_now"])] if detail["discount_now"]
      rows << ["saved so far", format_money(detail["lifetime_savings"])] if detail["lifetime_savings"]
      rows << ["sold by", detail["merchant"]] if detail["merchant"]
      rows << ["asin", detail["asin"]] if detail["asin"]
      # Amazon substitutes this if the subscribed item is out of stock, so its
      # absence is worth stating rather than omitting — "none" is a setting.
      rows << ["backup item", detail["backup_item"] || dim("none")]
      rows << ["subscription id", detail["subscription_id"]] if detail["subscription_id"]
      rows
    end

    # The modal prints "Next delivery will arrive by" above the date; keeping
    # its wording distinguishes an arrival estimate from a ship date.
    def next_delivery_line(detail)
      label = detail["next_delivery_label"]
      prefix = detail["next_delivery_prefix"].to_s[/arrive by/i]
      prefix ? "#{label} #{dim("(arrives by)")}" : label
    end

    # Amazon's own label for a value, when it gave one. Its wording is more
    # precise than anything invented here ("Estimated savings for this
    # delivery:" vs "Savings:"), and on the savings line the label is doing
    # load-bearing work: the value on its own is a bare "$1.95", which reads
    # as a price.
    def labelled(card, key, fallback)
      label = card["#{key}_label"].to_s
      "#{label.empty? ? fallback : label} #{card[key]}"
    end

    def delivery_heading(card)
      when_ = card["date_label"] || card["date"] || "(undated)"
      items = Array(card["items"]).size
      head = "#{bold(when_)}  #{dim("#{plural(items, "item")}")}"
      head += "  #{bold(format_money(card["subtotal"]))}" if card["subtotal"]
      head += dim("  · next") if card["kind"] == "current"
      head
    end

    def delivery_items(card)
      title_width = [term_width - 30, 24].max
      Array(card["items"]).each do |item|
        # A future delivery has no prices at all, so the column is blank rather
        # than $0.00 — the difference between "free" and "not priced yet".
        price = item["price"] ? format_money(item["price"]).rjust(9) : " " * 9
        line = "  #{price}  #{truncate(item["title"], title_width)}"
        line += green("  #{item["discount"]}") if item["discount"]
        puts line
      end
    end

    # The same block layout as `list`, one step further in: these items sit
    # under a delivery heading, so the price moves off the front of the line —
    # a price column indented past a photograph is a column of one.
    def delivery_item_cards(card, thumbnails)
      width = [term_width - thumbnails.cols - 4, 24].max
      Array(card["items"]).each do |item|
        lines = [truncate(item["title"], width)]
        lines << dim(truncate(item["variation"], width)) if item["variation"]
        lines << delivery_item_price(item)
        beside_image(thumbnails.block(item["image"]), lines.compact, thumbnails)
      end
    end

    def delivery_item_price(item)
      # A future delivery has no prices at all, so this is the discount alone
      # rather than $0.00 — the difference between "free" and "not priced yet".
      # With neither, the line is dropped rather than left blank.
      return nil if item["price"].nil? && item["discount"].nil?
      return green(item["discount"].to_s) unless item["price"]

      line = bold(format_money(item["price"]))
      item["discount"] ? "#{line}  #{green(item["discount"])}" : line
    end

    # "1 month", "2 weeks" — or whatever Amazon said, if it didn't parse.
    def interval_phrase(row)
      count = row["interval_count"]
      unit = row["interval_unit"]
      return "#{count} #{unit}#{"s" unless count == 1}" if count && unit
      row["schedule_raw"] || "?"
    end

    def subscription_count_note(shown, total, loaded_all)
      return nil unless total
      return nil if shown >= total
      # Without --all a short list is expected and the note is an offer; with
      # it, a short list means pagination gave up early and the worker has
      # already said so on stderr. Saying "use --all" there would be advice to
      # do the thing that just failed.
      return "showing #{shown} of #{total} — pass --all for the rest" unless loaded_all
      "showing #{shown} of the #{total} subscriptions Amazon reports"
    end

    # Every empty result in this file goes through here, because a zero is not
    # self-explanatory: it can mean nothing was stored to look at, or that
    # plenty was and a filter excluded all of it. The two need opposite
    # remedies — one syncs, the other picks a different year — so the line has
    # to name which happened rather than leaving the reader to guess.
    #
    # `scope:` is a required keyword on both callers rather than a nilable one,
    # so "we didn't know what was searched" isn't a state this can be in. A
    # default would have been a fallback no user could reach, kept alive only
    # by the tests proving it worked.
    def empty_note(subject, scope)
      stored = scope[:stored].to_i
      return "(no #{subject} — nothing stored yet; run `amazon order sync`)" if stored.zero?

      year = scope[:year]
      searched = scope[:searched].to_i
      if year && searched.zero?
        have = year_ranges(scope[:years])
        return "(no #{subject} — nothing from #{year} among your " \
               "#{plural(stored, "stored order")}#{have.empty? ? "" : "; stored years: #{have}"})"
      end
      "(no #{subject} — searched #{plural(searched, "stored order")}#{year ? " from #{year}" : ""})"
    end

    def purchase_note(searched)
      n = searched.to_i
      return "no local orders to check — run `amazon order sync`" if n.zero?
      "not in your #{plural(n, "stored order")}"
    end

    def plural(n, word) = "#{comma(n)} #{word}#{"s" unless n == 1}"

    # A real archive spans two decades, and nineteen comma-separated years is a
    # wall the reader skips — which puts us back where we started, with a line
    # that technically said what it searched and practically didn't. Contiguous
    # runs collapse; gaps survive, because a missing year is the one thing here
    # worth noticing.
    def year_ranges(years)
      sorted = Array(years).map(&:to_i).uniq.sort
      return "" if sorted.empty?

      sorted.slice_when { |a, b| b != a + 1 }
            .map { |run| run.first == run.last ? run.first.to_s : "#{run.first}–#{run.last}" }
            .join(", ")
    end

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
      puts dim("    Heuristics on a #{analysis["sample_size"]}-review sample, not a verdict. #{footer_advice(analysis)}")
    end

    # Same three states as the per-signal hints, and for the same reason: a walk
    # that crashed is not a listing that ran dry, and only one of the two is
    # worth retrying.
    def footer_advice(analysis)
      case analysis["walk"]
      when "exhausted" then "That is everything Amazon would serve for this listing."
      when "failed" then "The deeper walk did not finish — retry to sample further."
      else
        pages = analysis["pages"].to_i
        deeper = [pages + Amazon::Reviews::PAGE_STEP, Amazon::Reviews::MAX_PAGES].min
        deeper > pages ? "Use --pages #{deeper} for a deeper sample." : "This is the deepest sample offered."
      end
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
    def yellow(s) = @color ? "#{YELLOW}#{s}#{RST}" : s
  end
end
