module Amazon
  module Commands
    module Subscribe
      # `amazon subscribe upcoming` — the delivery schedule, with prices.
      class Upcoming
        include Args
        include Cached
        include Images

        # Amazon schedules deliveries months out; the real account had seven,
        # 84 items between them. "What's coming" means the next box — the one
        # with prices, a deadline, and something you can still do about it.
        # The rest are a list of things that might be true in March.
        DEFAULT_LIMIT = 1

        # Smaller than `list`: these are already nested under a delivery
        # heading, and a delivery can hold eighteen of them.
        IMAGE_ROWS = 4

        def initialize(global)
          @global = global
        end

        def run(argv)
          limit = DEFAULT_LIMIT
          fresh = false
          images = nil
          while (a = argv.shift)
            case a
            when "--all" then limit = nil
            when "--fresh" then fresh = true
            when "--image", "--images" then images = true
            when "--no-image", "--no-images" then images = false
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
          # v2: the cached shape gained a product image per item. Serving a v1
          # payload to --image would draw a screen of blank margins for half an
          # hour, with nothing on it to say why.
          #
          # v3: a wrapper rather than a bare array, so a degraded scrape can
          # carry the reason it was degraded and say it again on every cache
          # hit rather than only on the run that discovered it.
          payload = cached("deliveries:v3", fresh: fresh) do
            worker = Amazon::Worker.new(verbose: @global.verbose)
            cards = worker.deliveries
            { "cards" => cards, "_degraded" => worker.degradations }
          end
          cards = payload["cards"]
          renderer = thumbnails(images, IMAGE_ROWS)
          Amazon::Formatter.new(json: @global.json)
            .deliveries(cards, limit: limit, thumbnails: renderer)
          report_missing_images(renderer)
          0
        end

        private

        def help_text
          <<~HELP
            Usage: amazon subscribe upcoming [--limit N | --all] [--no-image] [--fresh] [--json]

            Shows each scheduled Subscribe & Save delivery: what's in it, and —
            for the one shipping next — the price Amazon will charge and the
            last day you can still change or skip it.

            Future deliveries carry no prices on Amazon's side, so none are
            shown for them rather than a guess from today's listing.

            Amazon schedules months ahead, but only the next delivery has
            prices and an edit deadline, so that's the one that prints by
            default; a note says how many more there are.

            Cached for 30 minutes. --fresh re-reads Amazon and drops the cached
            copy of `list` and `show` too, since all three describe the same
            account.

            Options:
              --limit N   Show N deliveries (default #{DEFAULT_LIMIT})
              --all       Show every scheduled delivery
              --no-image  Plain lines, no product photos
              --fresh     Ignore the cache and re-read Amazon
              --json      JSON output (every delivery, unaffected by --limit)
          HELP
        end
      end
    end
  end
end
