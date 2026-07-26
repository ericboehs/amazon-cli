module Amazon
  module Commands
    # Live product detail: current price, stock, delivery estimate, seller.
    class Item
      include Args

      def initialize(global)
        @global = global
      end

      def run(argv)
        target = nil
        fresh = false
        while (a = argv.shift)
          case a
          when "--fresh" then fresh = true
          when "-h", "--help"
            puts <<~HELP
              Usage: amazon item <ASIN|url> [--fresh] [--json]

              Looks up a product on Amazon right now — price, availability,
              delivery estimate, seller, rating. Delivery dates are personalized
              to the address on your signed-in account.

              Options:
                --fresh   Re-fetch from Amazon and refresh the cache
            HELP
            return 0
          else
            reject_unknown_flag!(a)
            target ||= a
          end
        end

        unless target
          warn "item: an ASIN or product URL is required"
          return 2
        end

        Amazon::Config.load
        worker = Amazon::Worker.new(verbose: @global.verbose, quiet: @global.quiet)
        cache = Amazon::Cache.new("item", read: !fresh)
        data = cache.fetch(target) { worker.item(target) }
        unless data
          warn "amazon: no product data for #{target} — the worker finished without returning an item"
          return 1
        end

        store = Amazon::Store.new
        data = data.merge("purchases" => store.purchases_by_asin[data["asin"]] || [])
        Amazon::Formatter.new(json: @global.json).item(data)
        0
      end
    end
  end
end
