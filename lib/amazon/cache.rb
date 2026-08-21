require "json"
require "fileutils"
require "digest"

module Amazon
  # Short-TTL disk cache for live lookups, so repeated `amazon item B0…` calls
  # (or piping the same search into jq twice) don't re-hit Amazon.
  class Cache
    DEFAULT_TTL = 900 # 15 minutes

    # `read:` and `write:` are separate because `--fresh` means "don't trust
    # what's on disk", not "don't record what I just fetched". Disabling both
    # would leave the stale entry in place with its original mtime, so a
    # `--fresh` run followed by a plain one inside the TTL served the *older*
    # price.
    def initialize(namespace, ttl: DEFAULT_TTL, read: true, write: true)
      @namespace = namespace
      @dir = Config.cache_dir.join("live", namespace)
      @ttl = ttl
      @read = read
      @write = write
    end

    # Whether the last `fetch` was served from disk. Callers need to tell the
    # two apart: warnings the worker emitted while scraping went to this run's
    # stderr on a miss and to nobody at all on a hit.
    attr_reader :hit

    # Yields and stores on miss; returns cached value on hit.
    def fetch(key)
      cached = read(key)
      @hit = !cached.nil?
      return cached if @hit

      value = yield
      write(key, value)
      value
    end

    # Re-print the notes the worker attached to a degraded scrape, but only for
    # a payload that came off disk. On a miss the worker said all of this on
    # this run's stderr as it scraped; on a hit it said it to a run that has
    # already finished, and what's left is a partial report that looks exactly
    # like a whole one.
    def replay_degradations(data)
      return unless @hit && data.is_a?(Hash)
      Array(data["_degraded"]).each { |msg| warn "amazon: [cached] #{msg}" }
    end

    def read(key)
      return nil unless @read && @ttl.positive?

      path = path_for(key)
      return nil unless path.exist?
      return nil if Time.now - path.mtime > @ttl

      value = JSON.parse(File.read(path))
      return nil if empty_collection?(value)
      value
    rescue JSON::ParserError
      nil
    end

    def write(key, value)
      return value unless @write
      # An empty result is what selector drift looks like from here. Storing it
      # would turn one bad scrape into a sticky "no results" for the full TTL,
      # with only the undiscoverable --fresh to escape it.
      return value if empty_collection?(value)

      path = path_for(key)
      FileUtils.mkdir_p(path.dirname)
      File.write(path, JSON.generate(value))
      value
    end

    def age(key)
      path = path_for(key)
      path.exist? ? (Time.now - path.mtime).to_i : nil
    end

    # Drop every entry in this namespace.
    #
    # Per-key invalidation is the wrong grain for anything that shares a
    # subject. `amazon subscribe list` and `subscribe upcoming` are two
    # renderings of one account state, so refreshing one while the other still
    # serves a 25-minute-old copy of the same subscriptions reproduces exactly
    # the staleness the TTL exists to bound. The same goes for a write: a
    # cancellation changes both views, and only one of them knows it happened.
    def clear
      # `rm_rf` defaults to force: true, which swallows every SystemCallError.
      # That is wrong here specifically: this is the whole mechanism behind
      # `Cached.invalidate!`, so a cache directory that can't be removed —
      # read-only mount, a permissions repair gone sideways — silently leaves
      # a cancelled subscription looking active for the rest of the TTL. A
      # failure to forget is worth a line on stderr.
      FileUtils.remove_entry(@dir) if @dir.exist?
      true
    rescue SystemCallError => e
      warn "amazon: couldn't clear the #{@namespace} cache at #{@dir} (#{e.message}) — " \
           "readings may be stale; pass --fresh"
      false
    end

    private

    def empty_collection?(value)
      return true if value.respond_to?(:empty?) && value.empty?
      return false unless value.is_a?(Hash)

      # A payload that *wraps* its rows is as empty as the rows it wraps, but
      # `Hash#empty?` counts keys and says otherwise — so `subscribe list`,
      # which caches `{"rows" => [], "total" => nil}`, walked straight past
      # the guard above and pinned a failed scrape for the full TTL. That is
      # the exact bug this method was written to prevent, arriving in a
      # container.
      #
      # Only wrappers qualify: every value has to be a collection or nil. A
      # record with real fields and one empty list in it — a subscription
      # detail with no actions — is a genuine result and stays cacheable.
      values = value.values
      collections = values.select { |v| v.is_a?(Array) || v.is_a?(Hash) }
      collections.any? &&
        values.all? { |v| v.nil? || v.is_a?(Array) || v.is_a?(Hash) } &&
        collections.all? { |v| empty_collection?(v) }
    end

    def path_for(key)
      @dir.join("#{Digest::SHA256.hexdigest(key.to_s)[0, 16]}.json")
    end
  end
end
