module Amazon
  module Commands
    module Subscribe
      # `amazon subscribe list` — what you're subscribed to.
      class List
        include Args
        include Cached

        def initialize(global)
          @global = global
        end

        def run(argv)
          load_all = false
          fresh = false
          while (a = argv.shift)
            case a
            when "--all" then load_all = true
            when "--fresh" then fresh = true
            when "-h", "--help"
              puts help_text
              return 0
            else
              warn "unknown list option: #{a}"
              return 2
            end
          end

          Amazon::Config.load
          payload = cached("list:all=#{load_all}", fresh: fresh) { scrape(load_all) }
          Amazon::Formatter.new(json: @global.json)
            .subscriptions(payload["rows"], total: payload["total"], loaded_all: load_all)
          0
        end

        private

        # The total travels with the rows because it isn't derivable from them
        # — it is the number Amazon claims to hold, and on a first page of 30
        # the whole point is that it disagrees.
        def scrape(load_all)
          worker = Amazon::Worker.new(verbose: @global.verbose)
          rows = worker.subscriptions(all: load_all)
          { "rows" => rows, "total" => worker.subscription_total }
        end

        def help_text
          <<~HELP
            Usage: amazon subscribe list [--all] [--fresh] [--json]

            Lists your Subscribe & Save subscriptions: what ships next, when,
            how often, and what it costs.

            Sorted by next delivery date, soonest first. Amazon's own order is
            neither date nor alphabetical, so there is nothing in it to
            preserve.

            The price and discount come from the deliveries view, which is the
            only place Amazon commits to a number — a subscription card carries
            none. Only the delivery shipping next is priced; the rest show the
            discount they will get without an amount. If that view can't be
            read the schedules still print, with a warning.

            Amazon paginates at ~30. Without --all you get the first page and a
            note saying how many there are in total.

            Cached for 30 minutes. --fresh re-reads Amazon and drops the cached
            copy of `upcoming` and `show` too, since all three describe the
            same account.

            Options:
              --all    Page through every subscription, not just the first page
              --fresh  Ignore the cache and re-read Amazon
              --json   JSON output
          HELP
        end
      end
    end
  end
end
