module Amazon
  module Commands
    module Order
      class Search
        def initialize(global)
          @global = global
        end

        def run(argv)
          query = nil
          year = nil
          while (a = argv.shift)
            case a
            when "--year" then year = Integer(argv.shift)
            when "-h", "--help"
              puts "Usage: amazon order search <query> [--year YYYY] [--json]"
              return 0
            else
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
          Amazon::Formatter.new(json: @global[:json]).search(hits, query)
          0
        end
      end
    end
  end
end
