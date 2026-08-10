require "json"
require "fileutils"
require "time"
require "date"

module Amazon
  class Store
    # RuntimeError so CLI#run's rescue turns it into a message, not a backtrace.
    class Error < RuntimeError; end

    # Preference order for an order's headline total. Only grand_total is the
    # real amount charged: total_before_tax excludes tax, and subtotal excludes
    # tax *and* shipping. Old orders that amazon-orders can't fully parse land
    # with a null grand_total, so the fallbacks are load-bearing — but a number
    # several dollars low looks entirely legitimate in a table, and sums across
    # orders come out silently understated. Record which field was used.
    TOTAL_FIELDS = %w[grand_total total_before_tax subtotal].freeze

    def initialize
      @orders_dir = Config.orders_dir
      @index_path = Config.index_path
    end

    def index
      @index ||= if @index_path.exist?
        JSON.parse(File.read(@index_path))
      else
        { "last_sync" => nil, "orders" => {} }
      end
    rescue JSON::ParserError => e
      raise Error, "index at #{@index_path} is corrupt (#{e.message}) — re-run `amazon order sync --full`"
    end

    def write_order(order)
      id = order["order_id"]
      raise "order missing order_id" unless id

      year = year_for(order)
      year_dir = @orders_dir.join(year.to_s)
      FileUtils.mkdir_p(year_dir)
      file = year_dir.join("#{id}.json")
      File.write(file, JSON.pretty_generate(order) + "\n")

      relative = file.relative_path_from(Config.data_dir).to_s
      source = TOTAL_FIELDS.find { |f| order[f] }
      index["orders"][id] = {
        "year" => year,
        "date" => order["order_placed"],
        "total" => source && order[source],
        "total_source" => source,
        "file" => relative
      }
      file
    end

    # True when the stored total isn't the amount actually charged.
    def self.estimated_total?(meta)
      source = meta["total_source"]
      # Orders written before total_source existed: assume the good case rather
      # than flagging every historical row.
      !source.nil? && source != "grand_total"
    end

    def commit_index!(synced_at: Time.now.utc.iso8601)
      index["last_sync"] = synced_at
      write_json_atomic(@index_path, index)
    end

    def each_order(year: nil)
      return enum_for(:each_order, year: year) unless block_given?
      index["orders"].each do |id, meta|
        next if year && meta["year"] != year
        yield id, meta, -> { read(id) }
      end
    end

    def read(order_id)
      meta = index["orders"][order_id]
      return nil unless meta
      path = Config.data_dir.join(meta["file"])
      JSON.parse(File.read(path))
    end

    # What a query was drawn from, so an empty result can say which of the two
    # empties it is. "(no orders)" from an unsynced archive and "(no orders)"
    # from a 222-order archive holding none for the year asked about are the
    # same four words, and only the first one is fixed by syncing.
    #
    # `searched` is the count *after* the year filter, because that is the
    # number actually looked at; `stored` is the whole archive. They differ
    # exactly when a filter is doing the excluding, which is the case the
    # caller most needs to name.
    def scope(year: nil)
      metas = index["orders"].values
      {
        stored: metas.size,
        searched: year ? metas.count { |m| m["year"] == year } : metas.size,
        years: metas.filter_map { |m| m["year"] }.uniq.sort,
        year: year
      }
    end

    def list(year: nil, limit: nil)
      rows = index["orders"].map { |id, meta| meta.merge("order_id" => id) }
      rows = rows.select { |r| r["year"] == year } if year
      rows.sort_by! { |r| r["date"].to_s }.reverse!
      rows = rows.first(limit) if limit
      rows
    end

    def search(query, year: nil)
      q = query.downcase
      hits = []
      each_order(year: year) do |id, meta, load|
        order = load.call
        items = order["items"] || []
        match = items.any? do |it|
          (it["title"] || "").downcase.include?(q) ||
            (it["link"] || "").downcase.include?(q)
        end
        match ||= id.downcase.include?(q)
        hits << order if match
      end
      hits.sort_by { |o| o["order_placed"].to_s }.reverse
    end

    ASIN_RE = %r{/(?:dp|gp/product)/([A-Z0-9]{10})}

    def self.asin_from(link)
      link.to_s[ASIN_RE, 1]
    end

    # asin => [{date, price, order_id, title}, …], newest first. Used to annotate
    # live results with what you paid last time. Walks every order file, so
    # callers should build this once and reuse it.
    def purchases_by_asin
      @purchases_by_asin ||= begin
        map = Hash.new { |h, k| h[k] = [] }
        each_order do |id, meta, load|
          order = begin
            load.call
          rescue JSON::ParserError, SystemCallError => e
            # This walks every order file on disk, so one truncated file from an
            # interrupted sync would otherwise take down an unrelated `amazon
            # item` lookup.
            warn "amazon: skipping unreadable order #{id} (#{e.class})"
            next
          end
          (order["items"] || []).each do |item|
            asin = Store.asin_from(item["link"])
            next unless asin
            map[asin] << {
              "order_id" => id,
              "date" => meta["date"],
              "price" => item["price"],
              "title" => item["title"]
            }
          end
        end
        map.each_value { |v| v.sort_by! { |p| p["date"].to_s }.reverse! }
        map.default_proc = nil
        map
      end
    end

    # Most recent prior purchase of an ASIN, or nil.
    def last_purchase(asin)
      purchases_by_asin[asin]&.first
    end

    private

    # Write-then-rename: an interrupted sync leaves the previous index intact
    # instead of a half-written one that fails to parse on the next run.
    def write_json_atomic(path, data)
      tmp = nil
      FileUtils.mkdir_p(path.dirname)
      tmp = path.dirname.join(".#{path.basename}.#{Process.pid}.tmp")
      File.write(tmp, JSON.pretty_generate(data) + "\n")
      File.rename(tmp, path)
      tmp = nil
    ensure
      FileUtils.rm_f(tmp) if tmp
    end

    def year_for(order)
      placed = order["order_placed"]
      return Date.parse(placed).year if placed
      Time.now.year
    end
  end
end
