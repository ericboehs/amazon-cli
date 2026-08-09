module Amazon
  module Commands
    # Review research: rating distribution, complaint themes, and local
    # fake-review heuristics for one product.
    class Reviews
      include Args

      SORTS = %w[helpful recent].freeze
      MAX_PAGES = 10

      def initialize(global)
        @global = global
      end

      def run(argv)
        target = nil
        pages = 0
        sort = "helpful"
        fresh = verbatim = critical = false
        limit = nil

        while (a = argv.shift)
          case a
          when "--pages" then pages = pages_arg!(argv.shift)
          when "--limit" then limit = integer_arg!("--limit", argv.shift)
          when "--sort" then sort = sort_arg!(argv.shift)
          when "--verbatim" then verbatim = true
          when "--critical" then critical = verbatim = true
          when "--fresh" then fresh = true
          when "-h", "--help"
            puts help_text
            return 0
          else
            reject_unknown_flag!(a)
            target ||= a
          end
        end

        unless target
          warn "reviews: an ASIN or product URL is required"
          return 2
        end

        Amazon::Config.load
        worker = Amazon::Worker.new(verbose: @global.verbose, quiet: @global.quiet)
        cache = Amazon::Cache.new("reviews", read: !fresh)
        data = cache.fetch("#{target}|pages=#{pages}|sort=#{sort}") do
          worker.item(target, reviews: true, review_pages: pages, sort: sort)
        end
        unless data
          warn "amazon: no product data for #{target} — the worker finished without returning an item"
          return 1
        end

        # Analysis runs on the whole sample; --critical narrows only what gets
        # printed. Scoring a hand-picked subset would be meaningless.
        analysis = Amazon::Reviews.analyze(data)
        data = data.merge("reviews_sample" => critical_only(data)) if critical
        Amazon::Formatter.new(json: @global.json).reviews(data, analysis, verbatim: verbatim, limit: limit)
        0
      end

      private

      def critical_only(data)
        Array(data["reviews_sample"]).select { |r| r["rating"].is_a?(Numeric) && r["rating"] <= 3 }
      end

      def pages_arg!(raw)
        n = integer_arg!("--pages", raw)
        # Each page is another round trip to Amazon from the same session, which
        # is exactly the traffic pattern that gets a session captcha'd.
        raise BadArgument, "--pages must be between 0 and #{MAX_PAGES}" unless n.between?(0, MAX_PAGES)
        n
      end

      def sort_arg!(raw)
        return raw if SORTS.include?(raw)
        raise BadArgument, "--sort must be one of: #{SORTS.join(", ")}"
      end

      def help_text
        <<~HELP
          Usage: amazon reviews <ASIN|url> [--pages N] [--verbatim] [--critical] [--json]

          Pulls the rating histogram and a sample of reviews, then scores the
          listing for signs of review manipulation — unverified purchases,
          timing bursts, duplicated wording, undisclosed compensation, and
          reviews that don't match the product.

          Every point in the score is itemised, including the checks that could
          not be run on the sample available. It is a research aid, not a verdict.

          By default only the ~8 reviews on the product page are sampled, which
          is too thin for the timing and duplicate checks. Use --pages for those.

          Options:
            --pages N    Also walk N pages of the full review listing (~10 each,
                         max #{MAX_PAGES}). One extra page load each; default 0
            --sort S     helpful (default) or recent — applies to --pages
            --verbatim   Print the review text, not just the analysis
            --critical   Print only 1-3 star reviews (implies --verbatim)
            --limit N    Cap how many reviews --verbatim prints
            --fresh      Re-fetch from Amazon and refresh the cache
        HELP
      end
    end
  end
end
