require "pathname"
require "optparse"

module Amazon
  class CLI
    COMMANDS = %w[login sync list show search config buy help].freeze

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
      when "sync"   then Commands::Sync.new(global).run(argv)
      when "list"   then Commands::List.new(global).run(argv)
      when "show"   then Commands::Show.new(global).run(argv)
      when "search" then Commands::Search.new(global).run(argv)
      when "config" then Commands::Config.new(global).run(argv)
      when "buy"    then Commands::Buy.new(global).run(argv)
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

        Commands:
          login    Open a browser so you can sign in (handles captcha/2FA)
          sync     Pull recent orders from Amazon into local store
          list     List orders from local store
          show     Show one order in detail
          search   Search orders by item title / ASIN / order id
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
