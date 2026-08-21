module Amazon
  module Commands
    module Subscribe
      # --image handling, shared by the views that have a product photo to show.
      module Images
        # nil means "text only", and every caller treats the renderer as
        # optional decoration — so declining images, piping to a file, and not
        # having chafa installed all take the same path through the formatter
        # rather than three.
        def thumbnails(requested, rows)
          return nil unless requested
          # JSON is data. A picture is not data, and neither is the escape
          # sequence that draws one.
          return nil if @global.json

          renderer = Amazon::Thumbnail.new(rows: rows)
          reason = renderer.unsupported_reason
          return renderer unless reason

          warn "amazon: #{reason}"
          nil
        end
      end
    end
  end
end
