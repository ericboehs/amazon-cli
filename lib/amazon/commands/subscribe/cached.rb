module Amazon
  module Commands
    module Subscribe
      # Shared cache policy for the `subscribe` subcommands.
      #
      # Subscription state is slow-moving — a schedule you set months ago and a
      # delivery six weeks out — but each read costs ~10 seconds of browser, so
      # every subcommand caches for half an hour.
      #
      # One namespace for all three views on purpose. `list`, `upcoming` and
      # `show` are three renderings of the same account, so `--fresh` on any of
      # them drops all of them: refreshing the list while `upcoming` still
      # serves a 25-minute-old copy of the same subscriptions is the staleness
      # the flag was reached for. The writes use the same door — a cancellation
      # invalidates every view, not the one that issued it.
      module Cached
        NAMESPACE = "subscribe".freeze
        TTL = 1800 # 30 minutes

        # Yields on a miss and stores the result. `fresh:` clears the whole
        # namespace first rather than bypassing this one key, so the run that
        # asked for current data doesn't leave two other views stale behind it.
        def cached(key, fresh:)
          cache = Amazon::Cache.new(NAMESPACE, ttl: TTL, read: !fresh)
          cache.clear if fresh
          value = cache.fetch(key) { yield }
          if cache.hit
            # The worker's warnings were spoken on the run that scraped this,
            # to a process that has since exited. Without replaying them a
            # partial list served from disk looks exactly like a whole one —
            # `item` and `reviews` already do this; the subscribe path had
            # neither half.
            cache.replay_degradations(value)
            note_cache_age(cache, key)
          end
          value
        end

        # Anything that changes a subscription on Amazon's side must call this;
        # otherwise the next read serves the state from before the change and
        # looks like the change didn't take.
        def self.invalidate!
          Amazon::Cache.new(NAMESPACE).clear
        end

        private

        # A cached read prints nothing about *when* it was read, and a schedule
        # that changed twenty minutes ago is indistinguishable from one that
        # didn't. Quiet enough to ignore, present enough to explain a surprise.
        def note_cache_age(cache, key)
          age = cache.age(key)
          return if age.nil? || @global.json

          warn "amazon: [cached #{humanize_age(age)} ago — --fresh to re-read]"
        end

        def humanize_age(seconds)
          return "#{seconds}s" if seconds < 60

          minutes = seconds / 60
          minutes == 1 ? "1 minute" : "#{minutes} minutes"
        end
      end
    end
  end
end
