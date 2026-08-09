require "date"
require "set"

module Amazon
  # Deterministic fake-review heuristics, computed locally.
  #
  # There is no service left to lean on: Fakespot shut down in July 2025 and
  # ReviewMeta went offline in early 2026, and what replaced them are browser
  # extensions with unpublished methods and no API. So this scores its own
  # signals and always shows its work — a number you can't audit is worse than
  # no number, especially for a judgement call this soft.
  #
  # Each signal is scored out of its own max. A signal that can't be computed
  # from the sample on hand (burst detection needs dates, duplicate detection
  # needs bodies) returns nil and drops out of the *denominator* rather than
  # scoring zero — otherwise a thin sample would read as a clean bill of health,
  # which is the single most dangerous way for this to be wrong.
  module Reviews
    Signal = Data.define(:key, :label, :points, :max, :detail) do
      def computable? = !points.nil?

      def as_json
        { "key" => key.to_s, "label" => label, "points" => points, "max" => max, "detail" => detail }
      end
    end

    # Below this many sampled reviews, the per-review signals are noise: one
    # coincidence in a sample of five swings the score by 20 points.
    MIN_SAMPLE = 5
    BURST_MIN_SAMPLE = 15
    BURST_WINDOW_DAYS = 7
    # Deliberately steep. Honest reviews routinely share no vocabulary with a
    # keyword-stuffed title, so this only means anything across a deep sample —
    # and it is better to report "couldn't check" than to accuse a real listing.
    MISMATCH_MIN_SAMPLE = 25
    # Below this many content words, two reviews overlap by coincidence often
    # enough that Jaccard similarity stops meaning anything.
    DUPLICATE_MIN_WORDS = 6

    # Phrasing that discloses compensation. Amazon has banned incentivized
    # reviews since 2016, so these turning up at all is notable — except for
    # Vine, which Amazon runs itself and which is tracked separately.
    INCENTIVIZED_RE = /
      (?:received|got|given)\ (?:this|it|the\ product)[^.]{0,40}(?:free|discount|no\ cost)
      | in\ exchange\ for\ (?:my|an|a)\ (?:honest|unbiased|candid)
      | (?:free|discounted)\ (?:product|sample|item)\ in\ exchange
      | at\ a\ discounted\ (?:price|rate)
      | for\ (?:my|an)\ honest\ review
      | in\ return\ for\ (?:my|an)\ honest
      | sample\ (?:was\ )?provided\ by
      | test(?:ing)?\ purposes\ (?:in|at)\ (?:a\ )?discount
    /xi

    STOPWORDS = %w[
      about above after again against all also although always and another any are because been before
      being below between both but came come could did does doing down during each even every few for
      from further get got had has have having her here hers herself him himself his how into its
      itself just like made make many may might more most much must myself never not now off once only
      other others ought our ours ourselves out over own quite rather really same she should since
      some still such than that the their theirs them themselves then there these they this those
      though through too under until upon use used using very was way well were what when where which
      while who whom why will with within without would you your yours yourself yourselves
      product item amazon review reviews star stars bought buy purchase purchased order ordered
    ].to_set

    WORD_RE = /[a-z][a-z'-]*/
    # Anything shorter carries no topical meaning, and the stoplist below can't
    # be relied on to catch them all.
    MIN_WORD_LENGTH = 3
    # Splits a body into clauses. Digits count as breaks, not just punctuation:
    # "Leaking 1 everywhere" is two thoughts, and gluing them produces a phrase
    # nobody wrote. Apostrophes and hyphens stay inside words.
    CLAUSE_SPLIT_RE = /[^a-z'\-\s]+/

    class << self
      # Full analysis of one product's review payload. Safe on partial data:
      # every stage degrades to "not computable" rather than raising.
      def analyze(data)
        data ||= {}
        # "reviews" is the sitewide rating count; the sampled review objects
        # live under "reviews_sample".
        reviews = Array(data["reviews_sample"])
        signals = [
          histogram_signal(data["histogram"]),
          unverified_signal(reviews),
          burst_signal(reviews),
          duplicate_signal(reviews),
          incentivized_signal(reviews),
          mismatch_signal(data["title"], reviews),
          repeat_reviewer_signal(reviews)
        ]
        scored = signals.select(&:computable?)
        denominator = scored.sum(&:max)
        score = denominator.zero? ? nil : ((scored.sum(&:points) / denominator.to_f) * 100).round

        {
          "sample_size" => reviews.size,
          "score" => score,
          "level" => level_for(score),
          "confidence" => confidence_for(reviews, scored.size, signals.size),
          "signals" => signals.map(&:as_json),
          "verified_pct" => percentage(reviews.count { |r| r["verified"] }, reviews.size),
          "vine_count" => reviews.count { |r| r["vine"] },
          "reported_rating" => data["rating"],
          "adjusted_rating" => adjusted_rating(reviews),
          "themes" => themes(reviews)
        }
      end

      # Most-repeated phrases across critical (<=3 star) reviews. Bigrams first
      # — "battery life" says more than "battery" — with unigrams filling in.
      def themes(reviews, limit: 5)
        critical = reviews.select { |r| critical?(r) }
        return [] if critical.size < 3

        # Bigrams are taken within a clause, never across one. Joining title to
        # body or running through a comma manufactures phrases nobody wrote
        # ("great stopped", from "Great product" + "Stopped working").
        bigrams = tally(critical.flat_map { |r|
          segments("#{r["title"]}. #{r["body"]}").flat_map { |seg| seg.each_cons(2).map { |a, b| "#{a} #{b}" } }
        })
        unigrams = tally(critical.flat_map { |r| content_words("#{r["title"]} #{r["body"]}").uniq })
        picked = bigrams.select { |_, n| n >= 2 }.first(limit)
        covered = picked.flat_map { |phrase, _| phrase.split }
        picked += unigrams.reject { |w, _| covered.include?(w) }.select { |_, n| n >= 2 }
        picked.first(limit).map { |phrase, count| { "phrase" => phrase, "count" => count } }
      end

      # Mean of the reviews least likely to have been bought: verified, not
      # incentivized, not Vine. Sample-based, so it is not comparable to the
      # sitewide star rating — the formatter labels it as such.
      def adjusted_rating(reviews)
        trusted = reviews.select do |r|
          r["verified"] && !r["vine"] && !incentivized?(r) && numeric(r["rating"])
        end
        return nil if trusted.size < 3

        (trusted.sum { |r| numeric(r["rating"]) } / trusted.size).round(2)
      end

      def incentivized?(review)
        INCENTIVIZED_RE.match?("#{review["title"]} #{review["body"]}")
      end

      def critical?(review)
        rating = numeric(review["rating"])
        !rating.nil? && rating <= 3
      end

      # --- signals -----------------------------------------------------

      # A genuine product's ratings are J-shaped: a 5-star pile, a real 1-star
      # tail, and a thin middle. A wall of 5s with *neither* a middle nor a tail
      # is the shape review farms produce, because nobody buys 2-star reviews.
      def histogram_signal(histogram)
        pct = normalize_histogram(histogram)
        return na(:histogram, "Rating distribution", "Amazon didn't render the star histogram") if pct.empty?

        five = pct[5].to_i
        middle = pct[2].to_i + pct[3].to_i + pct[4].to_i
        points = 0
        points += 12 if five >= 90
        points += 7 if five >= 80 && five < 90
        points += 8 if middle <= 5
        points += 4 if middle > 5 && middle <= 10
        points = [points, 20].min

        detail =
          if points.zero?
            "#{five}% five-star with a #{middle}% middle — a normal spread"
          else
            "#{five}% five-star and only #{middle}% two-to-four-star; organic ratings keep a fatter middle"
          end
        Signal.new(key: :histogram, label: "Rating distribution", points: points, max: 20, detail: detail)
      end

      # The strongest single signal that survived into 2026. Farmed reviews are
      # usually posted without a matching purchase on the account.
      def unverified_signal(reviews)
        return thin(:unverified, "Verified purchases") if reviews.size < MIN_SAMPLE

        unverified = reviews.reject { |r| r["verified"] }
        share = unverified.size / reviews.size.to_f
        points = scaled(share, floor: 0.10, ceiling: 0.50, max: 20)
        glowing = unverified.count { |r| (rating = numeric(r["rating"])) && rating >= 4 }
        detail =
          if unverified.empty?
            "all #{reviews.size} sampled reviews are verified purchases"
          else
            "#{unverified.size}/#{reviews.size} sampled reviews are unverified" \
              "#{glowing.positive? ? " (#{glowing} of them 4★ or better)" : ""}"
          end
        Signal.new(key: :unverified, label: "Verified purchases", points: points, max: 20, detail: detail)
      end

      # Bought reviews arrive in batches, so they bunch into a few days. Needs a
      # deeper sample than one product page provides.
      def burst_signal(reviews)
        dates = reviews.filter_map { |r| parse_date(r["date"]) }.sort
        if dates.size < BURST_MIN_SAMPLE
          return na(:burst, "Review timing",
                    "needs #{BURST_MIN_SAMPLE}+ dated reviews (have #{dates.size}) — re-run with --pages 3")
        end

        best = dates.each_with_index.map { |start, i|
          dates[i..].count { |d| (d - start).to_i < BURST_WINDOW_DAYS }
        }.max
        share = best / dates.size.to_f
        points = scaled(share, floor: 0.30, ceiling: 0.70, max: 20)
        detail = "#{best}/#{dates.size} sampled reviews land inside one #{BURST_WINDOW_DAYS}-day window " \
                 "(#{(share * 100).round}%)"
        Signal.new(key: :burst, label: "Review timing", points: points, max: 20, detail: detail)
      end

      # Farm output is templated, so bodies share unusual amounts of vocabulary.
      def duplicate_signal(reviews)
        bodies = reviews.filter_map do |r|
          words = content_words(r["body"])
          words.to_set if words.size >= DUPLICATE_MIN_WORDS
        end
        if bodies.size < 4
          return na(:duplicates, "Distinct wording",
                    "needs 4+ reviews with substantial text (have #{bodies.size})")
        end

        involved = Set.new
        bodies.each_with_index do |a, i|
          bodies.each_with_index do |b, j|
            next if j <= i
            next unless jaccard(a, b) >= 0.55
            involved << i << j
          end
        end
        share = involved.size / bodies.size.to_f
        points = scaled(share, floor: 0.0, ceiling: 0.40, max: 15)
        detail =
          if involved.empty?
            "no near-duplicate phrasing among #{bodies.size} reviews"
          else
            "#{involved.size}/#{bodies.size} reviews share heavily overlapping wording with another"
          end
        Signal.new(key: :duplicates, label: "Distinct wording", points: points, max: 15, detail: detail)
      end

      def incentivized_signal(reviews)
        return thin(:incentivized, "Undisclosed compensation") if reviews.size < MIN_SAMPLE

        hits = reviews.count { |r| !r["vine"] && incentivized?(r) }
        share = hits / reviews.size.to_f
        points = scaled(share, floor: 0.0, ceiling: 0.30, max: 10)
        detail = hits.zero? ? "no compensation disclosures in the sample" :
                 "#{hits}/#{reviews.size} reviews mention a free or discounted unit outside the Vine programme"
        Signal.new(key: :incentivized, label: "Undisclosed compensation", points: points, max: 10, detail: detail)
      end

      # Review hijacking: a seller bolts a new product onto an old listing's
      # variation set and inherits its reviews. The tell is reviews that talk
      # about something else entirely.
      #
      # Deliberately hard to trigger. Honest reviews routinely share no
      # vocabulary with a keyword-stuffed title ("Held up through a full season
      # of mowing" vs "Heavy Duty Garden Loppers Steel Blade"), so anything less
      # than a near-total mismatch across a deep sample is noise, and noise here
      # would discredit every other signal in the list.
      def mismatch_signal(title, reviews)
        subject = content_words(title).to_set
        bodies = reviews.filter_map do |r|
          words = content_words("#{r["title"]} #{r["body"]}")
          words.to_set if words.any?
        end
        if subject.size < 3 || bodies.size < MISMATCH_MIN_SAMPLE
          return na(:mismatch, "Reviews match the product",
                    "needs a descriptive title and #{MISMATCH_MIN_SAMPLE}+ reviews with text " \
                    "(have #{bodies.size}) — re-run with --pages 3")
        end

        unrelated = bodies.count { |b| (b & subject).empty? }
        share = unrelated / bodies.size.to_f
        points = scaled(share, floor: 0.90, ceiling: 1.0, max: 8)
        detail =
          if points.zero?
            "#{bodies.size - unrelated}/#{bodies.size} reviews mention something from the product title"
          else
            "#{unrelated}/#{bodies.size} reviews share no wording with the title — possible merged listing"
          end
        Signal.new(key: :mismatch, label: "Reviews match the product", points: points, max: 8, detail: detail)
      end

      def repeat_reviewer_signal(reviews)
        names = reviews.filter_map { |r| r["author"]&.strip&.downcase }.reject(&:empty?)
        return thin(:repeat_reviewers, "Distinct reviewers") if names.size < MIN_SAMPLE

        repeated = names.tally.select { |_, n| n > 1 }
        share = repeated.sum { |_, n| n } / names.size.to_f
        points = scaled(share, floor: 0.0, ceiling: 0.40, max: 5)
        detail = repeated.empty? ? "#{names.size} distinct reviewer names" :
                 "#{repeated.size} reviewer name(s) appear more than once"
        Signal.new(key: :repeat_reviewers, label: "Distinct reviewers", points: points, max: 5, detail: detail)
      end

      # --- scoring -----------------------------------------------------

      def level_for(score)
        return "unknown" if score.nil?
        case score
        when 0...20 then "low"
        when 20...40 then "some"
        when 40...65 then "elevated"
        else "high"
        end
      end

      # Confidence is about the sample, not the verdict. A 12-point score off
      # eight reviews and six off two hundred are not the same claim.
      def confidence_for(reviews, computed, total)
        return "none" if computed.zero?
        return "low" if reviews.size < BURST_MIN_SAMPLE || computed < total - 1
        reviews.size >= 40 && computed == total ? "high" : "medium"
      end

      private

      def na(key, label, why)
        Signal.new(key: key, label: label, points: nil, max: 0, detail: why)
      end

      def thin(key, label)
        na(key, label, "needs #{MIN_SAMPLE}+ reviews in the sample")
      end

      # Linear ramp from `floor` (0 points) to `ceiling` (full points).
      def scaled(share, floor:, ceiling:, max:)
        return 0 if share <= floor
        return max if share >= ceiling
        (((share - floor) / (ceiling - floor)) * max).round
      end

      def normalize_histogram(histogram)
        return {} unless histogram.is_a?(Hash)
        histogram.each_with_object({}) do |(star, pct), out|
          key = Integer(star.to_s, exception: false)
          value = Integer(pct.to_s, exception: false)
          out[key] = value if key&.between?(1, 5) && value
        end
      end

      def content_words(text)
        text.to_s.downcase.scan(WORD_RE).select { |w| meaningful?(w) }
      end

      def meaningful?(word)
        word.length >= MIN_WORD_LENGTH && !STOPWORDS.include?(word)
      end

      # Content words grouped by clause, so adjacency in a bigram means the two
      # words really did sit side by side. A dropped word breaks the run rather
      # than closing the gap — "the screen is cracked" must not yield "screen
      # cracked". Note that short function words ("is", "of") are dropped for
      # being under the length floor, before the stoplist is ever consulted, so
      # the break has to key off "was this word kept", not "was it a stopword".
      def segments(text)
        text.to_s.downcase.split(CLAUSE_SPLIT_RE).flat_map do |clause|
          kept = clause.scan(WORD_RE).map { |w| meaningful?(w) ? w : nil }
          kept.chunk_while { |a, b| !a.nil? && !b.nil? }.map(&:compact).reject(&:empty?)
        end
      end

      def jaccard(a, b)
        union = (a | b).size
        union.zero? ? 0.0 : (a & b).size / union.to_f
      end

      def tally(words)
        words.tally.sort_by { |word, count| [-count, word] }
      end

      def percentage(count, total)
        total.zero? ? nil : ((count / total.to_f) * 100).round
      end

      def numeric(value) = value.is_a?(Numeric) ? value.to_f : nil

      def parse_date(raw)
        raw && Date.iso8601(raw.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
