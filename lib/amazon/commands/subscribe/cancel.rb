module Amazon
  module Commands
    module Subscribe
      # `amazon subscribe cancel` — end a subscription for good.
      #
      # Same shape as `skip`, with the guards tightened: cancelling is the one
      # thing here that can't be undone from the CLI, so the dry run reads back
      # Amazon's own consequence list and `--yes` verifies across every page of
      # the active list rather than the first thirty.
      class Cancel
        include Args
        include Cached

        def initialize(global)
          @global = global
        end

        def run(argv)
          target = nil
          confirm = false
          reason = nil
          while (a = argv.shift)
            case a
            when "--yes", "-y" then confirm = true
            when "--reason" then reason = argv.shift
            when /\A--reason=(.+)\z/ then reason = Regexp.last_match(1)
            when "-h", "--help"
              puts help_text
              return 0
            when /\A-/
              warn "unknown cancel option: #{a}"
              return 2
            else
              reject_second_target!(target, a)
              target = a
            end
          end

          unless target
            warn "usage: amazon subscribe cancel <id-or-search> [--yes] [--reason WHY]"
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
            worker.cancel(target, confirm: confirm, reason: reason)
          ensure
            Cached.invalidate! if confirm
          end
          return refuse(worker.not_found) unless result

          Amazon::Formatter.new(json: @global.json).cancellation(result)
          Mutation.exit_code(applied: result["cancelled"], verified: result["verified"])
        end

        private

        def reject_second_target!(existing, extra)
          return unless existing

          raise Args::BadArgument,
                "cancel takes one subscription at a time (got #{existing.inspect} and #{extra.inspect})"
        end

        def refuse(reason)
          Mutation.refuse(reason, "the cancellation")
        end

        def help_text
          <<~HELP
            Usage: amazon subscribe cancel <id-or-search> [--yes] [--reason WHY] [--json]

            Ends a Subscribe & Save subscription. This is not a skip: the
            subscription stops existing, its discount goes with it, and any
            order of this item that hasn't entered the delivery process yet is
            cancelled too — including one in the box shipping next.

            Without --yes nothing is changed. Amazon's cancellation page is
            read back to you — what you've saved so far, what you lose, and
            what happens to the pending order — and the command exits 2.

            With --yes the cancellation is confirmed and then verified by
            paging through your whole active list to confirm it's gone.

            Amazon marks the reason optional, so none is sent unless you pass
            one. `--reason` accepts the keys printed by the dry run, e.g.
            --reason stopped_using, --reason accident.

            Cancelling is not reversible from here. Amazon's page says you can
            reactivate the item later on the website.

            Options:
              --yes, -y      Actually cancel it
              --reason WHY   Tell Amazon why (optional)
              --json         JSON output
          HELP
        end
      end
    end
  end
end
