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
      end
    end
  end
end
