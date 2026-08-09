module Amazon
  module Commands
    # Live product search. Results are annotated from the local order archive
    # when you've bought the same ASIN before.
    class Search
      include Args

      DEFAULT_LIMIT = 10

      def initialize(global)
        @global = global
      end

      def run(argv)
        query = nil
        limit = DEFAULT_LIMIT
        fresh = false
        hide_sponsored = false
        while (a = argv.shift)
          case a
          when "--limit" then limit = positive_arg!("--limit", argv.shift)
          when "--fresh" then fresh = true
          when "--no-sponsored" then hide_sponsored = true
          when "-h", "--help"
            puts <<~HELP
              Usage: amazon search <query> [--limit N] [--no-sponsored] [--fresh] [--json]

              Searches Amazon live. Items you have bought before are annotated
              with the date and price you paid.

              To search your own order history instead, use `amazon order search`.

              Options:
                --limit N        Max results (default #{DEFAULT_LIMIT})
                --no-sponsored   Drop sponsored listings
                --fresh          Re-fetch from Amazon and refresh the cache
            HELP
            return 0
          else
            reject_unknown_flag!(a)
            query ||= a
          end
        end

        unless query
          warn "search: query is required"
          return 2
        end

        Amazon::Config.load
        worker = Amazon::Worker.new(verbose: @global.verbose, quiet: @global.quiet)
        cache = Amazon::Cache.new("search", read: !fresh)
        results = cache.fetch([query, limit].join(" ")) { worker.search(query, limit: limit) }

        if hide_sponsored
          # `sponsored` is nil when the worker couldn't tell. Dropping those
          # would hide organic listings; silently keeping them would report the
          # filter as complete when it isn't.
          unknown = results.count { |r| r["sponsored"].nil? }
          warn "amazon: couldn't tell whether #{unknown} listing(s) are sponsored — keeping them" if unknown.positive?
          results = results.reject { |r| r["sponsored"] }
        end

        store = Amazon::Store.new
        results = results.map do |r|
          r.merge("prior_purchase" => store.last_purchase(r["asin"]))
        end

        Amazon::Formatter.new(json: @global.json).live_search(results, query)
        0
      end
    end
  end
end
