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
      FileUtils.rm_rf(@dir)
    end

    private

    def empty_collection?(value)
      value.respond_to?(:empty?) && value.empty?
    end

    def path_for(key)
      @dir.join("#{Digest::SHA256.hexdigest(key.to_s)[0, 16]}.json")
    end
  end
end
