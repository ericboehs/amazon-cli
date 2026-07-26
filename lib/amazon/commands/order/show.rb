module Amazon
  module Commands
    module Order
      class Show
        def initialize(global)
          @global = global
        end

        def run(argv)
          order_id = nil
          while (a = argv.shift)
            case a
            when "-h", "--help"
              puts "Usage: amazon order show <order-id> [--json]"
              return 0
            else
              order_id ||= a
            end
          end

          unless order_id
            warn "show: order id is required"
            return 2
          end

          Amazon::Config.load
          store = Amazon::Store.new
          order = store.read(order_id)
          Amazon::Formatter.new(json: @global[:json]).show(order)
          order ? 0 : 1
        end
      end
    end
  end
end
