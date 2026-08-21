module Amazon
  module Commands
    module Subscribe
      # `amazon subscribe upcoming` — the delivery schedule, with prices.
      class Upcoming
        include Args
        include Cached

        # Amazon schedules deliveries months out; the real account had seven,
        # 84 items between them. Everything is available with --all, but the
        # question "what's coming" has a short answer and this is it.
        DEFAULT_LIMIT = 3

        def initialize(global)
          @global = global
        end

        def run(argv)
          limit = DEFAULT_LIMIT
          fresh = false
          while (a = argv.shift)
            case a
            when "--all" then limit = nil
            when "--fresh" then fresh = true
            when "--limit"
              limit = positive_arg!("--limit", argv.shift)
            when "-h", "--help"
              puts help_text
              return 0
            else
              warn "unknown upcoming option: #{a}"
              return 2
            end
          end

          Amazon::Config.load
          cards = cached("deliveries", fresh: fresh) do
            Amazon::Worker.new(verbose: @global.verbose).deliveries
          end
          Amazon::Formatter.new(json: @global.json).deliveries(cards, limit: limit)
          0
        end

        private

        def help_text
          <<~HELP
            Usage: amazon subscribe upcoming [--limit N | --all] [--fresh] [--json]

            Shows each scheduled Subscribe & Save delivery: what's in it, and —
            for the one shipping next — the price Amazon will charge and the
            last day you can still change or skip it.

            Future deliveries carry no prices on Amazon's side, so none are
            shown for them rather than a guess from today's listing.

            Amazon schedules months ahead, so only the next #{DEFAULT_LIMIT} print by
            default; a note says how many more there are.

            Cached for 30 minutes. --fresh re-reads Amazon and drops the cached
            copy of `list` and `show` too, since all three describe the same
            account.

            Options:
              --limit N  Show N deliveries (default #{DEFAULT_LIMIT})
              --all      Show every scheduled delivery
              --fresh    Ignore the cache and re-read Amazon
              --json     JSON output (always every delivery, unaffected by --limit)
          HELP
        end
      end
    end
  end
end
