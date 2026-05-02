module Amazon
  module Commands
    class Buy
      def initialize(global)
        @global = global
      end

      def run(_argv)
        warn "amazon buy: not yet implemented"
        warn "  Planned to use Playwright with a persistent logged-in session."
        warn "  See ~/.claude/plans/expressive-bubbling-glacier.md for the design."
        2
      end
    end
  end
end
