module Amazon
  module Commands
    module Subscribe
      # --image/--no-image handling, shared by the views that have a product
      # photo to show. Photos are the default; the flag exists to turn them off
      # and to force the explanation when they don't appear.
      module Images
        # nil means "text only", and every caller treats the renderer as
        # optional decoration — so declining images, piping to a file, and not
        # having chafa installed all take the same path through the formatter
        # rather than three.
        #
        # `requested` is deliberately three-valued: true (--image), false
        # (--no-image), and nil for neither.
        def thumbnails(requested, rows)
          return nil if requested == false
          # JSON is data. A picture is not data, and neither is the escape
          # sequence that draws one.
          return nil if @global.json

          renderer = Amazon::Thumbnail.new(rows: rows)
          reason = renderer.unsupported_reason
          return renderer unless reason

          # Only explain when the flag was actually typed. Now that photos are
          # the default, warning unconditionally would make every pipe and
          # every chafa-less machine apologise for a thing nobody asked for.
          warn "amazon: #{reason}" if requested
          nil
        end

        # Say once, after the listing, that some photos are missing. Without
        # this a failed download is three layers of silent nil and a blank
        # margin that looks exactly like a product with no picture.
        def report_missing_images(renderer)
          return unless renderer&.failures&.positive?

          count = renderer.failures
          said = "amazon: #{count} #{count == 1 ? "photo" : "photos"} could not be fetched"
          # The count answers "how many" and cannot answer "why", and the two
          # answers lead opposite ways: a CDN timeout is worth retrying, a
          # NameError in the fetcher is worth reporting. Both arrive here as
          # the same sentence, so the exception goes behind --verbose rather
          # than into every listing that loses a photo to a flaky network.
          said += " (first error: #{error_detail(renderer.first_error)})" if @global.verbose && renderer.first_error
          warn said
        end

        private

        # Class included on purpose: "execution expired" alone doesn't say
        # whether it was the connection or the read, and `Errno::ENOSPC` says
        # more than "No space left on device" does about whose disk.
        def error_detail(err)
          "#{err.class}: #{err.message}"
        end
      end
    end
  end
end
