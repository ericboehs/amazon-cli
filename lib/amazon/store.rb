require "json"
require "fileutils"
require "time"
require "date"

module Amazon
  class Store
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
      index["orders"][id] = {
        "year" => year,
        "date" => order["order_placed"],
        "total" => order["grand_total"],
        "file" => relative
      }
      file
    end

    def commit_index!(synced_at: Time.now.utc.iso8601)
      index["last_sync"] = synced_at
      File.write(@index_path, JSON.pretty_generate(index) + "\n")
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

    private

    def year_for(order)
      placed = order["order_placed"]
      return Date.parse(placed).year if placed
      Time.now.year
    end
  end
end
