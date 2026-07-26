require "json"
require "fileutils"
require "digest"

module Amazon
  # Short-TTL disk cache for live lookups, so repeated `amazon item B0…` calls
  # (or piping the same search into jq twice) don't re-hit Amazon.
  class Cache
    DEFAULT_TTL = 900 # 15 minutes

    def initialize(namespace, ttl: DEFAULT_TTL, enabled: true)
      @dir = Config.cache_dir.join("live", namespace)
      @ttl = ttl
      @enabled = enabled
    end

    # Yields and stores on miss; returns cached value on hit.
    def fetch(key)
      hit = read(key)
      return hit if hit

      value = yield
      write(key, value)
      value
    end

    def read(key)
      return nil unless @enabled && @ttl.positive?

      path = path_for(key)
      return nil unless path.exist?
      return nil if Time.now - path.mtime > @ttl

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    def write(key, value)
      return value unless @enabled

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

    def path_for(key)
      @dir.join("#{Digest::SHA256.hexdigest(key.to_s)[0, 16]}.json")
    end
  end
end
