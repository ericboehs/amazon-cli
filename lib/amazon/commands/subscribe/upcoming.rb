module Amazon
  module Commands
    module Subscribe
      # `amazon subscribe upcoming` — the delivery schedule, with prices.
      class Upcoming
        include Args

        def initialize(global)
          @global = global
        end

        def run(argv)
          while (a = argv.shift)
            case a
            when "-h", "--help"
              puts help_text
              return 0
            else
              warn "unknown upcoming option: #{a}"
              return 2
            end
          end

          Amazon::Config.load
          worker = Amazon::Worker.new(verbose: @global.verbose)
          Amazon::Formatter.new(json: @global.json).deliveries(worker.deliveries)
          0
        end

        private

        def help_text
          <<~HELP
            Usage: amazon subscribe upcoming [--json]

            Shows each scheduled Subscribe & Save delivery: what's in it, and —
            for the one shipping next — the price Amazon will charge and the
            last day you can still change or skip it.

            Future deliveries carry no prices on Amazon's side, so none are
            shown for them rather than a guess from today's listing.

            Options:
              --json   JSON output
          HELP
        end
      end
    end
  end
end
