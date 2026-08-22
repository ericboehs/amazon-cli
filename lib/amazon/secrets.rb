require "open3"

module Amazon
  # Reads secrets out of 1Password.
  #
  # Two commands need the same two values and neither should keep a copy: the
  # sync worker signs in over HTTP, and `amazon login` fills the same password
  # into a browser window. The value travels from `op` to a subprocess pipe and
  # is never written to a file, a log line, or an exception message.
  module Secrets
    Error = Class.new(RuntimeError)

    class << self
      def read(ref)
        out, err, status = Open3.capture3(*command(ref))
        raise Error, failure_message(ref, err) unless status.success?

        value = out.chomp
        # `op` can exit 0 and print nothing — an empty field, or a reference to
        # a field that doesn't exist in some versions. An empty password then
        # survives `.compact` on the Ruby side and is only caught by a `or
        # None` in Python, which is an invariant enforced across a process
        # boundary by accident.
        raise Error, "#{ref} is empty in 1Password — check the field name" if value.empty?

        value
      end

      # 1Password's account shorthand. `my` is the default for a personal
      # account and was hardcoded and undocumented, so anyone whose account is
      # named anything else got "op read failed" with no hint that the account
      # was the problem.
      def account = ENV.fetch("AMAZON_OP_ACCOUNT", "my")

      def command(ref)
        ["bash", "-lc",
         "op signin --account #{shellword(account)} >/dev/null && op read #{shellword(ref)}"]
      end

      private

      # `op` sends both failures to the same stream, and "your vault is locked"
      # and "that field does not exist" want completely different responses.
      #
      # The pattern is what `op` actually says, checked against it rather than
      # guessed: a bad `--account` reports `found no accounts for filter "x"`,
      # which an invented /signin|session/ did not match.
      ACCOUNT_TROUBLE = /sign\s*in|not signed in|session|authenticat|no accounts|account/i

      def failure_message(ref, err)
        said = err.to_s.strip
        if said.match?(ACCOUNT_TROUBLE)
          "1Password wouldn't sign in to account #{account.inspect}: #{said}\n" \
            "Set AMAZON_OP_ACCOUNT if your account shorthand isn't #{account.inspect}, " \
            "or run `op signin` once by hand."
        else
          "op read failed for #{ref}: #{said}"
        end
      end

      def shellword(str)
        # Refs like op://Personal/Amazon/password are safe; still quote
        # defensively — in the block form, because in a gsub *replacement*
        # string `\'` is not an escaped quote, it's $POSTMATCH. The two-arg
        # version of this pasted the rest of the string in after every
        # apostrophe: "it's" quoted itself as 'it's's'.
        "'" + str.gsub("'") { "'\\''" } + "'"
      end
    end
  end
end
