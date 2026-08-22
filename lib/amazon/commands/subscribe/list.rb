module Amazon
  module Commands
    module Subscribe
      # `amazon subscribe list` — what you're subscribed to.
      class List
        include Args
        include Cached
        include Images

        def initialize(global)
          @global = global
        end

        # Six rows is the smallest thumbnail in which a bottle of detergent is
        # still a bottle of detergent, and it happens to be exactly the height
        # of the four lines of text beside it.
        IMAGE_ROWS = 6

        def run(argv)
          load_all = false
          fresh = false
          images = nil
          while (a = argv.shift)
            case a
            when "--all" then load_all = true
            when "--fresh" then fresh = true
            when "--image", "--images" then images = true
            when "--no-image", "--no-images" then images = false
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
          renderer = thumbnails(images, IMAGE_ROWS)
          Amazon::Formatter.new(json: @global.json).subscriptions(
            payload["rows"], total: payload["total"], loaded_all: load_all,
            thumbnails: renderer
          )
          report_missing_images(renderer)
          0
        end

        private

        # The total travels with the rows because it isn't derivable from them
        # — it is the number Amazon claims to hold, and on a first page of 30
        # the whole point is that it disagrees.
        def scrape(load_all)
          worker = Amazon::Worker.new(verbose: @global.verbose)
          rows = worker.subscriptions(all: load_all)
          { "rows" => rows, "total" => worker.subscription_total,
            "_degraded" => worker.degradations }
        end

        def help_text
          <<~HELP
            Usage: amazon subscribe list [--all] [--no-image] [--fresh] [--json]

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

            In a terminal each subscription is a block with its product photo
            alongside; --no-image gives the plain table instead, which is also
            what you get when stdout is a pipe or chafa isn't installed.

            Options:
              --all       Page through every subscription, not just the first page
              --no-image  Plain table, no product photos
              --fresh     Ignore the cache and re-read Amazon
              --json      JSON output
          HELP
        end
      end
    end
  end
end
