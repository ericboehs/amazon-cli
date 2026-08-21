module Amazon
  module Commands
    module Subscribe
      # `amazon subscribe schedule` — change how much arrives, and how often.
      #
      # The reversible mutation of the three, and the only one with a before
      # and an after worth printing side by side. It takes an id or a title
      # search like everything else here.
      class Schedule
        include Args
        include Cached

        def initialize(global)
          @global = global
        end

        def run(argv)
          target = nil
          confirm = false
          wants = {}
          while (a = argv.shift)
            case a
            when "--yes", "-y" then confirm = true
            when "--qty", "--quantity" then wants[:quantity] = argv.shift
            when /\A--(?:qty|quantity)=(.+)\z/ then wants[:quantity] = Regexp.last_match(1)
            when "--every", "--frequency" then wants[:frequency] = argv.shift
            when /\A--(?:every|frequency)=(.+)\z/ then wants[:frequency] = Regexp.last_match(1)
            when "--next" then wants[:next_date] = argv.shift
            when /\A--next=(.+)\z/ then wants[:next_date] = Regexp.last_match(1)
            when "-h", "--help"
              puts help_text
              return 0
            when /\A-/
              warn "unknown schedule option: #{a}"
              return 2
            else
              reject_second_target!(target, a)
              target = a
            end
          end

          unless target
            warn "usage: amazon subscribe schedule <id-or-search> [--qty N] [--every \"2 months\"] [--yes]"
            return 2
          end

          # Asking to apply nothing is a mistake worth catching before a
          # browser opens, not after Amazon's form has been submitted with
          # every field set to what it already said.
          if confirm && wants.values.compact.empty?
            warn "amazon: nothing to change — pass --qty, --every, or --next"
            return 2
          end

          Amazon::Config.load
          worker = Amazon::Worker.new(verbose: @global.verbose)
          # On attempt, not on outcome. The old form only cleared the cache
          # if a result came back, so a click that landed and *then* threw —
          # the browser dying during verification, say — left `subscribe list`
          # describing the world from before the change for the next half
          # hour, while the command that made it exited saying it failed. A
          # cleared cache costs one re-read; a wrong one costs trust.
          result = begin
            worker.schedule(target, confirm: confirm, **wants)
          ensure
            Cached.invalidate! if confirm
          end
          return refuse(worker.not_found) unless result

          Amazon::Formatter.new(json: @global.json).schedule(result)
          # With no --qty/--every/--next this asked a question rather than
          # requesting a change, and it answered: that is a 0, not a dry run.
          return 0 if wants.empty? && !confirm

          Mutation.exit_code(applied: result["applied"], verified: result["verified"])
        end

        private

        def reject_second_target!(existing, extra)
          return unless existing

          raise Args::BadArgument,
                "schedule takes one subscription at a time (got #{existing.inspect} and #{extra.inspect})"
        end

        def refuse(reason)
          warn "amazon: #{reason || "nothing to change"}"
          2
        end

        def help_text
          <<~HELP
            Usage: amazon subscribe schedule <id-or-search> [--qty N] [--every EVERY]
                                             [--next MONTH] [--yes] [--json]

            Changes how much of an item arrives and how often. With no flags it
            prints the current schedule and everything Amazon will accept for
            it, which is the fastest way to find out that a product only offers
            quantities 1-3.

            Unlike `skip` and `cancel` this one is reversible: run it again.

            Amazon puts quantity, frequency and the next delivery date in one
            form behind one Apply button, so applying any of them submits all
            three. The dry run prints the date that form will send even when
            you didn't ask to move it — it is not always the date your
            subscription currently shows.

            --every takes what you'd say out loud: "2 months", "3 weeks",
            "6mo". --next takes a month name. Anything Amazon doesn't offer is
            refused with the list of what it does.

            Options:
              --qty N        New quantity per delivery
              --every EVERY  New interval, e.g. "2 months"
              --next MONTH   Move the next delivery, e.g. "November"
              --yes, -y      Actually apply the change
              --json         JSON output
          HELP
        end
      end
    end
  end
end
