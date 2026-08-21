module Amazon
  module Commands
    module Subscribe
      # `amazon subscribe list` — what you're subscribed to.
      class List
        include Args

        def initialize(global)
          @global = global
        end

        def run(argv)
          load_all = false
          while (a = argv.shift)
            case a
            when "--all" then load_all = true
            when "-h", "--help"
              puts help_text
              return 0
            else
              warn "unknown list option: #{a}"
              return 2
            end
          end

          Amazon::Config.load
          worker = Amazon::Worker.new(verbose: @global.verbose)
          rows = worker.subscriptions(all: load_all)
          Amazon::Formatter.new(json: @global.json)
            .subscriptions(rows, total: worker.subscription_total, loaded_all: load_all)
          0
        end

        private

        def help_text
          <<~HELP
            Usage: amazon subscribe list [--all] [--json]

            Lists your Subscribe & Save subscriptions with the schedule and the
            next delivery date Amazon currently shows for each.

            Amazon paginates this list, ~30 at a time. Without --all you get the
            first page and a note saying how many there are in total.

            No price column: a subscription has no price until its delivery is
            placed, so the number would be one this command made up. `amazon
            subscribe upcoming` shows the prices Amazon has actually committed to.

            Deliberately uncached. A schedule you changed on the website an hour
            ago and a schedule from an hour-old cache look identical, and only
            one of them is true.

            Options:
              --all    Page through every subscription, not just the first page
              --json   JSON output
          HELP
        end
      end
    end
  end
end
