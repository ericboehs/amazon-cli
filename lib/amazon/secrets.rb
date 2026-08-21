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
        raise Error, "op read failed for #{ref}: #{err.strip}" unless status.success?

        out.chomp
      end

      def command(ref)
        ["bash", "-lc", "op signin --account my >/dev/null && op read #{shellword(ref)}"]
      end

      private

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
