module Amazon
  module Commands
    module Order
      class Search
        include Args

        def initialize(global)
          @global = global
        end

        def run(argv)
          query = nil
          year = nil
          while (a = argv.shift)
            case a
            when "--year" then year = integer_arg!("--year", argv.shift)
            when "-h", "--help"
              puts "Usage: amazon order search <query> [--year YYYY] [--json]"
              return 0
            else
              reject_unknown_flag!(a)
              query ||= a
            end
          end

          unless query
            warn "search: query is required"
            return 2
          end

          Amazon::Config.load
          store = Amazon::Store.new
          hits = store.search(query, year: year)
          Amazon::Formatter.new(json: @global.json).search(hits, query, scope: store.scope(year: year))
          0
        end
      end
    end
  end
end
