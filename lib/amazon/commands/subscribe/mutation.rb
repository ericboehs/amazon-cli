module Amazon
  module Commands
    module Subscribe
      # What `skip`, `cancel` and `schedule` exit with.
      #
      # One place, because three copies of this rule had already drifted into
      # three answers: skip and cancel exited 2 for a dry run while schedule
      # exited 0, so `amazon subscribe schedule X --qty 3` reported success to
      # a script having changed nothing. The three commands do different things
      # to a subscription but they make the same promise about it, and a promise
      # kept in three places is kept differently.
      #
      # The states are the tri-state `verified` contract carried out to the
      # shell, because a script gets one integer and stdout scrolls past:
      #
      #   0  it is done, and we re-read Amazon to check
      #   1  it is not done — Amazon accepted the click and the change isn't there
      #   2  nothing was attempted (a dry run, or a refusal)
      #   3  it was attempted and we could not check
      #
      # 3 exists so that `--yes && deploy` doesn't treat "couldn't confirm" as
      # confirmation. Collapsing it into 0 reports a shipped box as skipped;
      # collapsing it into 1 cries wolf on a mutation that almost certainly
      # worked, and a warning that is usually wrong gets silenced. The whole
      # point of keeping three outcomes inside the worker is lost if they exit
      # as two.
      module Mutation
        DONE = 0
        FAILED = 1
        NOT_ATTEMPTED = 2
        UNVERIFIED = 3

        module_function

        # `applied` is the command's own key — "confirmed", "cancelled",
        # "applied" — already read out of the result, since those names are
        # part of the --json contract and not worth breaking to unify.
        def exit_code(applied:, verified:)
          return NOT_ATTEMPTED unless applied
          return UNVERIFIED if verified.nil?

          verified ? DONE : FAILED
        end
      end
    end
  end
end
