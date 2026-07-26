require "pathname"
require "optparse"

module Amazon
  class CLI
    COMMANDS = %w[login search item order config buy help].freeze

    def self.run(argv)
      new.run(argv)
    end

    def run(argv)
      argv = argv.dup
      global = parse_global!(argv)
      cmd = argv.shift || "help"

      case cmd
      when "help", "-h", "--help"
        puts help_text
        return 0
      when "login"  then Commands::Login.new(global).run(argv)
      when "search" then Commands::Search.new(global).run(argv)
      when "item"   then Commands::Item.new(global).run(argv)
      when "order"  then Commands::OrderNamespace.new(global).run(argv)
      when "config" then Commands::Config.new(global).run(argv)
      when "buy"    then Commands::Buy.new(global).run(argv)
      when *Commands::OrderNamespace::SUBCOMMANDS
        warn "amazon: `#{cmd}` moved to `amazon order #{cmd}`"
        2
      else
        warn "unknown command: #{cmd}"
        warn help_text
        2
      end
    rescue Worker::Error, RuntimeError => e
      warn "amazon: #{e.message}"
      1
    end

    private

    def parse_global!(argv)
      opts = { json: false, quiet: false, verbose: false }
      keep = []
      while (a = argv.shift)
        case a
        when "--json"           then opts[:json] = true
        when "-q", "--quiet"    then opts[:quiet] = true
        when "-v", "--verbose"  then opts[:verbose] = true
        else
          keep << a
        end
      end
      argv.replace(keep)
      opts
    end

    def help_text
      <<~HELP
        Usage: amazon <command> [options]

        Live (queries Amazon now):
          search   Search Amazon listings; flags items you've bought before
          item     Show live price, stock, and delivery date for an ASIN/URL

        Your orders (local archive):
          order sync     Pull orders from Amazon into the local store
          order list     List orders
          order show     Show one order in detail
          order search   Search your order history

        Other:
          login    Open a browser so you can sign in (handles captcha/2FA)
          config   Show or edit config
          buy      (not yet implemented)
          help     Show this help

        Global flags:
          --json       Emit JSON instead of formatted output
          -q/--quiet   Suppress non-essential output
          -v/--verbose Verbose worker logs

        Run `amazon <command> --help` for command-specific options.
      HELP
    end
  end
end
