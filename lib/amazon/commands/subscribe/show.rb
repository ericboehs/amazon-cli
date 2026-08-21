module Amazon
  module Commands
    module Subscribe
      # `amazon subscribe show` — one subscription, in full.
      #
      # The third view, and the only one that knows the ASIN, the seller, the
      # backup item, and what this subscription has saved you since you started
      # it. Amazon keeps all of that in the edit modal, one subscription at a
      # time, which is why it isn't columns on `list`.
      class Show
        include Args
        include Cached
        include Images

        def initialize(global)
          @global = global
        end

        # Room for the whole detail block beside it — this is the one view
        # showing a single product, so the picture can be worth looking at.
        IMAGE_ROWS = 12

        def run(argv)
          fresh = false
          images = nil
          target = nil
          while (a = argv.shift)
            case a
            when "--fresh" then fresh = true
            when "--image", "--images" then images = true
            when "--no-image", "--no-images" then images = false
            when "-h", "--help"
              puts help_text
              return 0
            else
              reject_unknown_flag!(a)
              target = target ? "#{target} #{a}" : a
            end
          end

          if target.nil?
            warn "a subscription id or search term is required"
            warn help_text
            return 2
          end

          Amazon::Config.load
          detail, reason = lookup(target, fresh)
          if detail.nil?
            warn reason || "nothing matched #{target.inspect}"
            return 2
          end

          renderer = thumbnails(images, IMAGE_ROWS)
          Amazon::Formatter.new(json: @global.json).subscription(detail, thumbnails: renderer)
          report_missing_images(renderer)
          0
        end

        private

        # A miss is not cached. "No subscription matched" is cheap to re-derive
        # and expensive to be wrong about for half an hour — you would fix the
        # typo, run it again, and get the same denial from a file.
        #
        # Returns the worker's own explanation alongside the record, because
        # "4 subscriptions match 'coconut'" is a better answer than anything
        # this side could reconstruct from a nil.
        def lookup(target, fresh)
          reason = nil
          detail = cached("show:#{target.downcase}", fresh: fresh) do
            worker = Amazon::Worker.new(verbose: @global.verbose)
            result = worker.subscription(target)
            reason = worker.not_found
            # The detail *is* the cached payload here, so the warnings have to
            # travel inside it — merged rather than assigned, because the
            # worker's hash is not ours to modify.
            if result && !worker.degradations.empty?
              result = result.merge("_degraded" => worker.degradations)
            end
            result
          end
          [detail, reason]
        end

        def help_text
          <<~HELP
            Usage: amazon subscribe show <id-or-search> [--no-image] [--fresh] [--json]

            Everything Amazon knows about one subscription: the product and its
            ASIN, who sells it, the schedule, the discount you're getting, any
            backup item, and what the subscription has saved you to date.

            Takes a subscription id, or any words from the product title:

              amazon subscribe show SNSD0_JW5SC777SESY1WWWNZPK
              amazon subscribe show dishwasher

            A search that matches more than one prints the matches and stops,
            rather than picking one for you.

            No price here — the edit modal has none, and its dollar figure is
            lifetime savings, not what the next delivery costs. `amazon
            subscribe upcoming` has the prices.

            Options:
              --no-image  Skip the product photo
              --fresh     Ignore the cache and re-read Amazon
              --json      JSON output
          HELP
        end
      end
    end
  end
end
