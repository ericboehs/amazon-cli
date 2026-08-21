require "digest"
require "fileutils"
require "net/http"
require "uri"

module Amazon
  # Product thumbnails in the terminal, rendered by chafa.
  #
  # chafa is the whole graphics stack here on purpose: it negotiates with the
  # terminal itself and emits kitty graphics, sixel, iTerm2 blobs, or unicode
  # half-blocks depending on what answered. Detecting that here would mean
  # reimplementing it worse, and the fallback path — coloured text — is the one
  # thing every terminal can already do.
  #
  # Every renderer chafa picks writes a block exactly `cols` wide and `rows`
  # tall and leaves the cursor at column 1 of the line *below* it, which is
  # what makes text-beside-image possible without knowing which protocol won.
  class Thumbnail
    COMMAND = "chafa"

    # Amazon's own "no image available" graphic. Some subscriptions carry it
    # instead of a photo, and rendering it spends a download and six rows to
    # say nothing — worse than the blank space it would replace.
    PLACEHOLDER = %r{/no-img\.}

    # Amazon serves any size from the same URL via the `._SS<n>_.` modifier, so
    # asking for one that matches the cell block beats downloading a 500px JPEG
    # to throw 80% of it away. Displays are 2x, and chafa downsamples better
    # than it upsamples.
    PIXELS_PER_ROW = 40

    FETCH_TIMEOUT = 5
    FETCH_THREADS = 8

    attr_reader :cols, :rows

    # `rows` drives everything: the width follows from it, because terminal
    # cells are about twice as tall as they are wide and a thumbnail that
    # ignores that is a portrait of a squashed bottle.
    def initialize(rows:, cols: nil, stream: $stdout)
      @rows = rows
      @cols = cols || rows * 2
      @stream = stream
      @cache = {}
    end

    # Why images can't be drawn, or nil if they can.
    #
    # Both cases are the user's to fix, and both are silent failures otherwise:
    # a pipe fills with escape codes, a missing chafa prints nothing at all.
    def unsupported_reason
      return "images need a terminal — ignoring --image" unless @stream.tty?
      return nil if self.class.command?

      "--image needs #{COMMAND} (brew install #{COMMAND}) — showing text only"
    end

    def self.command?
      return @command unless @command.nil?
      @command = system("command -v #{COMMAND} > /dev/null 2>&1")
    end

    # Test seam, and a way for a caller to say "don't shell out".
    class << self
      attr_writer :command
    end

    # Warm the cache concurrently. Rendering is sequential — chafa hands out
    # kitty image ids from a counter, and racing invocations can draw the same
    # id twice, which paints one product's photo onto another's row — but
    # downloading 59 thumbnails one at a time is a minute of waiting.
    def prefetch(urls)
      queue = Queue.new
      urls.uniq.select { |u| drawable?(u) }.each { |u| queue << u }
      Array.new([FETCH_THREADS, queue.size].min) do
        Thread.new do
          while (url = next_in(queue))
            @cache[url] = download(url)
          end
        end
      end.each(&:join)
    end

    # The escape sequence that draws `url` as a cols×rows block, or nil if
    # there is nothing to draw. Nil is a layout instruction as much as an
    # error: the caller still indents its text, so a missing photo leaves a
    # gap and the column of text stays straight.
    def block(url)
      return nil unless drawable?(url)

      path = @cache.fetch(url) { @cache[url] = download(url) }
      return nil if path.nil?

      render(path)
    end

    private

    # Worth a download and six rows of screen. Both callers ask, because a
    # prefetch that queues what `block` will refuse to draw spends the network
    # on nothing.
    def drawable?(url)
      !(url.nil? || url.empty? || url.match?(PLACEHOLDER))
    end

    def next_in(queue)
      queue.pop(true)
    rescue ThreadError
      nil
    end

    def render(path)
      out = IO.popen(render_command(path), err: File::NULL, &:read)
      # The block form waits, so $? is always this command's status. A chafa
      # that can't read the file exits non-zero; one that isn't installed
      # raises below.
      $?.success? ? out : nil
    rescue SystemCallError
      nil
    end

    def render_command(path)
      [COMMAND, "--size=#{@cols}x#{@rows}", path.to_s]
    end

    def download(url)
      path = cache_path(url)
      return path if path.exist? && path.size.positive?

      body = get(sized(url))
      return nil if body.nil? || body.empty?

      FileUtils.mkdir_p(path.dirname)
      # Written under a unique name and moved into place: two `amazon`
      # processes sharing a cache must never let one read the half of a file
      # the other is still writing.
      tmp = path.dirname.join("#{path.basename}.#{Process.pid}.#{Thread.current.object_id}")
      File.binwrite(tmp, body)
      File.rename(tmp, path)
      path
    rescue SystemCallError, IOError
      nil
    end

    def get(url, redirects: 2)
      uri = URI.parse(url)
      return nil unless uri.is_a?(URI::HTTPS) || uri.is_a?(URI::HTTP)

      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: FETCH_TIMEOUT, read_timeout: FETCH_TIMEOUT) do |http|
        http.get(uri.request_uri)
      end
      return res.body if res.is_a?(Net::HTTPSuccess)
      # Resolved against the URL that was asked for: a Location header is
      # allowed to be relative, and treating "/final.jpg" as a whole URL drops
      # the redirect on the floor and reports the image as missing.
      if res.is_a?(Net::HTTPRedirection) && res["location"] && redirects.positive?
        return get((uri + res["location"]).to_s, redirects: redirects - 1)
      end

      nil
    rescue StandardError
      # A thumbnail is decoration. Nothing about a slow CDN, a captive portal,
      # or a DNS failure should take down a subscription listing.
      nil
    end

    # Rewrite Amazon's size modifier, and only that one. The image URLs carry
    # other modifiers (`._CB1234_.`) whose meaning isn't "scale", so anything
    # not recognised is fetched as served rather than guessed at.
    def sized(url)
      url.sub(/\._SS\d+_\./, "._SS#{@rows * PIXELS_PER_ROW}_.")
    end

    # Keyed by the URL as asked for, size included: the same product at 6 rows
    # and at 14 is two different downloads.
    def cache_path(url)
      key = Digest::SHA256.hexdigest(sized(url))[0, 16]
      Config.cache_dir.join("thumbs", "#{key}.img")
    end
  end
end
