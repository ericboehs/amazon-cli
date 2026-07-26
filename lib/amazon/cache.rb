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

    # Yields and stores on miss; returns cached value on hit.
    def fetch(key)
      hit = read(key)
      return hit unless hit.nil?

      value = yield
      write(key, value)
      value
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

    private

    def empty_collection?(value)
      value.respond_to?(:empty?) && value.empty?
    end

    def path_for(key)
      @dir.join("#{Digest::SHA256.hexdigest(key.to_s)[0, 16]}.json")
    end
  end
end
