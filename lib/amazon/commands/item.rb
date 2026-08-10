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
        fresh = reviews = false
        while (a = argv.shift)
          case a
          when "--fresh" then fresh = true
          when "--reviews" then reviews = true
          when "-h", "--help"
            puts <<~HELP
              Usage: amazon item <ASIN|url> [--reviews] [--fresh] [--json]

              Looks up a product on Amazon right now — price, availability,
              delivery estimate, seller, rating. Delivery dates are personalized
              to the address on your signed-in account.

              Options:
                --reviews Append a review-authenticity summary (no extra page load)
                --fresh   Re-fetch from Amazon and refresh the cache

              For the full histogram, complaint themes, and review text, use
              `amazon reviews <ASIN>`.
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
        worker = Amazon::Worker.new(verbose: @global.verbose)
        # Separate cache namespaces: a plain lookup and a --reviews lookup return
        # different payloads, so one must never be served from the other's entry.
        cache = Amazon::Cache.new(reviews ? "item-reviews" : "item", read: !fresh)
        data = cache.fetch(target) { worker.item(target, reviews: reviews) }
        unless data
          warn "amazon: no product data for #{target} — the worker finished without returning an item"
          return 1
        end
        cache.replay_degradations(data)

        store = Amazon::Store.new
        # The denominator travels with the numerator: an empty `purchases` list
        # says nothing on its own, and the formatter can't tell "never bought"
        # from "never synced" without knowing how many orders were checked.
        data = data.merge("purchases" => store.purchases_by_asin[data["asin"]] || [],
                          "purchases_searched" => store.scope[:stored])
        formatter = Amazon::Formatter.new(json: @global.json)
        if reviews
          analysis = Amazon::Reviews.analyze(data)
          formatter.item(data.merge("analysis" => analysis))
          formatter.reviews_summary(analysis)
        else
          formatter.item(data)
        end
        0
      end
    end
  end
end
