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
  # chafa fits the image *within* the box rather than filling it, so what
  # comes back is at most `cols`×`rows` and often shorter: a 400x80 product
  # shot asked for 12x6 draws 2 rows. What every renderer does agree on is
  # leaving the cursor at column 1 of the line below whatever it drew — which
  # is why `beside_image` saves and restores the cursor instead of counting
  # rows back up. The class comment used to claim the block was "exactly cols
  # wide and rows tall", which is the opposite of the reason that code exists.
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

    # How many photos were wanted and couldn't be had.
    #
    # Every failure in here returns nil, on purpose: a thumbnail is decoration
    # and none of it should interrupt a listing. But three nils deep, a blank
    # left margin is indistinguishable from a product that has no photo, and
    # the user is left to wonder whether the CLI or their network is broken.
    # Counting them costs nothing and lets the caller say one sentence at the
    # end instead of nothing at all.
    attr_reader :failures

    # `rows` drives everything: the width follows from it, because terminal
    # cells are about twice as tall as they are wide and a thumbnail that
    # ignores that is a portrait of a squashed bottle.
    #
    # Validated at the door because every consequence of a bad value shows up
    # far from the cause: `rows: nil` raised NoMethodError on `nil * 2` from
    # inside a worker thread, and `rows: -5` sailed through to `chafa
    # --size=-10x-5` ("Size must be specified as...") and to an image URL
    # asking Amazon for `._SS-200_.`, both of which fail as a blank space.
    def initialize(rows:, cols: nil, stream: $stdout)
      @rows = Integer(rows)
      @cols = Integer(cols || @rows * 2)
      raise ArgumentError, "thumbnail rows must be positive, got #{@rows}" unless @rows.positive?
      raise ArgumentError, "thumbnail cols must be positive, got #{@cols}" unless @cols.positive?

      @stream = stream
      @cache = {}
      # Not for control flow — for saying so afterwards. See `failures`.
      @failures = 0
      # Eight threads write to @cache and bump @failures. CRuby's GVL makes
      # that survivable in practice rather than by contract, and this costs
      # nothing on a Hash that is written 59 times.
      @state_lock = Mutex.new
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
      urls.select { |u| drawable?(u) }.uniq { |u| cache_key(u) }.each { |u| queue << u }
      Array.new([FETCH_THREADS, queue.size].min) do
        Thread.new do
          # A thumbnail is decoration; a decoration must not be able to end the
          # command. Anything raised in here used to be re-raised by `join`
          # into `CLI#run` — and printed twice, because Ruby also reports an
          # unhandled thread exception with a bare backtrace. `download`
          # guards its own IO, but that is a list of the failures someone
          # thought of, and this is the one that isn't.
          while (url = next_in(queue))
            store(url, safe_download(url))
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

      path = @state_lock.synchronize { @cache.fetch(cache_key(url), :miss) }
      path = store(url, safe_download(url)) if path == :miss
      return nil if path.nil?

      render(path)
    end

    private

    def store(url, path)
      @state_lock.synchronize { @cache[cache_key(url)] = path }
    end

    # One key for both caches, and it has to be the rewritten URL, because that
    # is what actually goes over the network. Keying the Hash on the URL as
    # asked for while `cache_path` keyed on `sized` meant one product requested
    # at two sizes was two entries pointing at one file — and `prefetch`'s
    # `uniq`, which also saw the raw URLs, let both into the queue for two
    # threads to race over. Downloading the same JPEG twice is cheap. Counting
    # it as two photos that couldn't be fetched is a lie to the user.
    def cache_key(url) = sized(url)

    # Distinct from `download`'s own rescue: that one knows which failures are
    # expected, this one exists because the list is never complete.
    def safe_download(url)
      path = download(url)
      count_failure if path.nil?
      path
    rescue StandardError
      count_failure
      nil
    end

    # `@failures += 1` is a read and a separate write, run by up to
    # FETCH_THREADS workers. The GVL makes a lost update unlikely on CRuby
    # rather than impossible, and offers nothing at all on JRuby or
    # TruffleRuby — and an undercount here reads to the user as "some photos
    # are just missing", which is the one thing this counter exists to rule
    # out. Reuses the cache's lock: nothing calls this while holding it.
    def count_failure
      @state_lock.synchronize { @failures += 1 }
    end

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

    # Keyed by the URL as rewritten, size included: the same product at 6 rows
    # and at 14 is two different downloads, and at two requested sizes within
    # one run it is one.
    def cache_path(url)
      key = Digest::SHA256.hexdigest(cache_key(url))[0, 16]
      Config.cache_dir.join("thumbs", "#{key}.img")
    end
  end
end
