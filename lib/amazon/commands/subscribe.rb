module Amazon
  module Commands
    # Dispatcher for the `amazon subscribe …` namespace — Subscribe & Save.
    #
    # Named `subscribe` rather than `sns` or `subscribe-and-save`: the first is
    # jargon and the second is a mouthful nobody types twice. Everything under
    # it is read-only today; skip, schedule changes and cancellation are
    # deliberately absent rather than half-implemented, because a subcommand
    # that mutates a subscription and can't prove it worked is worse than one
    # that doesn't exist.
    class SubscribeNamespace
      SUBCOMMANDS = %w[list upcoming show].freeze

      def initialize(global)
        @global = global
      end

      def run(argv)
        sub = argv.shift
        case sub
        when nil, "help", "-h", "--help"
          puts help_text
          sub.nil? ? 2 : 0
        when "list"     then Subscribe::List.new(@global).run(argv)
        when "upcoming" then Subscribe::Upcoming.new(@global).run(argv)
        when "show"     then Subscribe::Show.new(@global).run(argv)
        else
          warn "unknown subscribe subcommand: #{sub}"
          warn help_text
          2
        end
      end

      private

      def help_text
        <<~HELP
          Usage: amazon subscribe <subcommand> [options]

          Subcommands:
            list      Your Subscribe & Save subscriptions and their schedules
            upcoming  Scheduled deliveries: what ships when, and by when you
                      can still change it
            show      One subscription in full: ASIN, seller, savings to date

          All three read Amazon live through the session `amazon login` saved,
          and cache for 30 minutes. None of them changes anything.

          Run `amazon subscribe <subcommand> --help` for subcommand options.
        HELP
      end
    end
  end
end
