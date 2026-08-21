module Amazon
  module Commands
    module Subscribe
      # `amazon subscribe skip` — drop one item from the next delivery.
      #
      # The first mutation in this namespace, so it sets the pattern: nothing
      # happens without --yes, the dry run is Amazon's own confirmation dialog
      # rather than a description of it, and the result is verified by
      # re-reading the page instead of trusting the click.
      class Skip
        include Args
        include Cached

        def initialize(global)
          @global = global
        end

        def run(argv)
          target = nil
          confirm = false
          while (a = argv.shift)
            case a
            when "--yes", "-y" then confirm = true
            when "-h", "--help"
              puts help_text
              return 0
            when /\A-/
              warn "unknown skip option: #{a}"
              return 2
            else
              # One at a time. A bulk skip is a different command with a
              # different confirmation, and getting it wrong here would be
              # expensive in a way that a bad `list` never is.
              reject_second_target!(target, a)
              target = a
            end
          end

          unless target
            warn "usage: amazon subscribe skip <id-or-search> [--yes]"
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
            worker.skip(target, confirm: confirm)
          ensure
            Cached.invalidate! if confirm
          end
          return refuse(worker.not_found) unless result

          Amazon::Formatter.new(json: @global.json).skip(result)
          Mutation.exit_code(applied: result["confirmed"], verified: result["verified"])
        end

        private

        def reject_second_target!(existing, extra)
          return unless existing

          raise Args::BadArgument,
                "skip takes one subscription at a time (got #{existing.inspect} and #{extra.inspect})"
        end

        def refuse(reason)
          warn "amazon: #{reason || "nothing to skip"}"
          2
        end

        def help_text
          <<~HELP
            Usage: amazon subscribe skip <id-or-search> [--yes] [--json]

            Skips one item out of your next Subscribe & Save delivery, so it
            isn't shipped or charged for this time. The subscription itself is
            untouched and the item returns on the following delivery.

            Only the delivery that ships next can be skipped, and only until
            its last-edit date — `amazon subscribe upcoming` shows both. Later
            deliveries have nothing to skip yet.

            Without --yes nothing is changed: Amazon's own confirmation dialog
            is opened and read back to you, including its warning about
            coupons, and the command exits 2 having agreed to nothing.

            With --yes the skip is confirmed and then verified by re-reading
            the delivery — "asked" and "done" are not the same claim.

            Options:
              --yes, -y  Actually skip it
              --json     JSON output
          HELP
        end
      end
    end
  end
end
