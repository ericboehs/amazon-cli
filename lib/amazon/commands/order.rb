module Amazon
  module Commands
    # Dispatcher for the `amazon order …` namespace — everything that reads the
    # local order archive. Live product lookups live at the top level
    # (`amazon item`, `amazon search`).
    class OrderNamespace
      SUBCOMMANDS = %w[sync list show search].freeze

      def initialize(global)
        @global = global
      end

      def run(argv)
        sub = argv.shift
        case sub
        when nil, "help", "-h", "--help"
          puts help_text
          sub.nil? ? 2 : 0
        when "sync"   then Order::Sync.new(@global).run(argv)
        when "list"   then Order::List.new(@global).run(argv)
        when "show"   then Order::Show.new(@global).run(argv)
        when "search" then Order::Search.new(@global).run(argv)
        else
          warn "unknown order subcommand: #{sub}"
          warn help_text
          2
        end
      end

      private

      def help_text
        <<~HELP
          Usage: amazon order <subcommand> [options]

          Subcommands:
            sync     Pull orders from Amazon into the local store
            list     List orders from the local store
            show     Show one order in detail
            search   Search your order history by item title / ASIN / order id

          Run `amazon order <subcommand> --help` for subcommand options.
        HELP
      end
    end
  end
end
