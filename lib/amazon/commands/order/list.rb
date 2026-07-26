module Amazon
  module Commands
    module Order
      class List
        include Args

        def initialize(global)
          @global = global
        end

        def run(argv)
          year = nil
          limit = nil
          while (a = argv.shift)
            case a
            when "--year"  then year = integer_arg!("--year", argv.shift)
            when "--limit" then limit = integer_arg!("--limit", argv.shift)
            when "-h", "--help"
              puts help_text
              return 0
            else
              warn "unknown list option: #{a}"
              return 2
            end
          end

          Amazon::Config.load # ensures dirs exist via load
          store = Amazon::Store.new
          rows = store.list(year: year, limit: limit)
          Amazon::Formatter.new(json: @global.json).list(rows)
          0
        end

        private

        def help_text
          <<~HELP
            Usage: amazon order list [options]

            Options:
              --year YYYY    Limit to one year
              --limit N      Show only the most recent N orders
              --json         JSON output
          HELP
        end
      end
    end
  end
end
