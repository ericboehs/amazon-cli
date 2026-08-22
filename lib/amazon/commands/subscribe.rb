module Amazon
  module Commands
    # Dispatcher for the `amazon subscribe …` namespace — Subscribe & Save.
    #
    # Named `subscribe` rather than `sns` or `subscribe-and-save`: the first is
    # jargon and the second is a mouthful nobody types twice.
    #
    # `list`, `upcoming` and `show` read; `skip`, `cancel` and `schedule`
    # write. The writes were held back until they could prove they worked,
    # because a subcommand that mutates a subscription and reports success
    # from a click that returned without error is worse than one that doesn't
    # exist — so each re-reads Amazon afterwards and reports three outcomes,
    # not two.
    class SubscribeNamespace
      SUBCOMMANDS = %w[list upcoming show skip cancel schedule].freeze

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
        when "skip"     then Subscribe::Skip.new(@global).run(argv)
        when "cancel"   then Subscribe::Cancel.new(@global).run(argv)
        when "schedule" then Subscribe::Schedule.new(@global).run(argv)
        else
          warn "unknown subscribe subcommand: #{sub}"
          warn "did you mean: #{SUBCOMMANDS.join(', ')}?"
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
            skip      Drop one item from the next delivery (needs --yes)
            cancel    End a subscription for good (needs --yes)
            schedule  Change quantity or how often it ships (needs --yes)

          The first three read Amazon live through the session `amazon login`
          saved, and cache for 30 minutes. `skip` and `cancel` change things,
          and none of them will without --yes. `skip` misses one delivery;
          `cancel` ends the subscription and the pending order with it;
          `schedule` changes quantity or interval and can be run again.

          Run `amazon subscribe <subcommand> --help` for subcommand options.
        HELP
      end
    end
  end
end
