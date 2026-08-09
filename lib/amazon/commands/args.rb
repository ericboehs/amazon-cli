module Amazon
  module Commands
    # Argument-parsing helpers shared by every command.
    #
    # `Integer()` raises ArgumentError on junk and TypeError on nil, and neither
    # descends from RuntimeError — so an unguarded `Integer(argv.shift)` escapes
    # CLI#run's rescue and prints a backtrace at the user for a typo. Every
    # numeric or list flag goes through here instead, and every command rejects
    # flags it doesn't know rather than silently treating them as positionals.
    module Args
      class BadArgument < RuntimeError; end

      def integer_arg!(flag, raw)
        raise BadArgument, "#{flag} needs a number" if raw.nil?
        Integer(raw)
      rescue ArgumentError, TypeError
        raise BadArgument, "#{flag} needs a number, got #{raw.inspect}"
      end

      # For counts, where zero and below are not smaller requests but nonsense.
      # `--limit -1` used to reach Array#first, whose ArgumentError is not a
      # RuntimeError and so escaped the CLI's rescue as a raw backtrace.
      def positive_arg!(flag, raw)
        n = integer_arg!(flag, raw)
        raise BadArgument, "#{flag} must be 1 or more" unless n.positive?
        n
      end

      def integer_list_arg!(flag, raw)
        raise BadArgument, "#{flag} needs a comma-separated list of numbers" if raw.nil?
        parts = raw.split(",").map(&:strip).reject(&:empty?)
        raise BadArgument, "#{flag} needs a comma-separated list of numbers, got #{raw.inspect}" if parts.empty?
        parts.map { |p| integer_arg!(flag, p) }
      end

      # Commands that take a positional argument must still reject unknown
      # flags, or a typo'd `--jsn` is silently swallowed as the positional.
      def reject_unknown_flag!(arg)
        raise BadArgument, "unknown option: #{arg}" if arg.to_s.start_with?("-")
      end
    end
  end
end
