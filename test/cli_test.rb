#!/usr/bin/env ruby
# frozen_string_literal: true

# Run with: ruby test/cli_test.rb
# Covers the Ruby CLI surface: dispatch, formatting, cache, and the ASIN index.
# Network-bound code (Worker's subprocess plumbing) is stubbed, not exercised.

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'minitest'
  gem 'simplecov'
end

require 'simplecov'
require 'tmpdir'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)

SimpleCov.start do
  enable_coverage :branch
  primary_coverage :line
  command_name 'cli_test'
  root ROOT
  # Each suite gates only its own files; without this, running cli_test and
  # web_test in sequence merges their results and each gate grades the union.
  use_merging false
  add_filter '/test/'
  add_filter '/web.rb'
  # Network- and browser-bound code: these drive the Python worker and a real
  # Chrome window, so they're exercised by live runs rather than unit tests.
  add_filter '/lib/amazon/worker.rb'
  add_filter '/lib/amazon/commands/login.rb'
  add_filter '/lib/amazon/commands/order/sync.rb'
  minimum_coverage line: 98, branch: 95
end

# Isolate all XDG state before anything reads it.
TMP = Dir.mktmpdir('amazon-cli-test')
ENV['XDG_CONFIG_HOME'] = File.join(TMP, 'config')
ENV['XDG_DATA_HOME']   = File.join(TMP, 'data')
ENV['XDG_STATE_HOME']  = File.join(TMP, 'state')
Minitest.after_run { FileUtils.remove_entry(TMP) if File.directory?(TMP) }

$LOAD_PATH.unshift(File.join(ROOT, 'lib'))
require 'amazon/config'
require 'amazon/cache'
require 'amazon/store'
require 'amazon/worker'
require 'amazon/formatter'
require 'amazon/cli'
require 'amazon/commands/login'
require 'amazon/commands/config'
require 'amazon/commands/buy'
require 'amazon/commands/item'
require 'amazon/commands/search'
require 'amazon/commands/order'
require 'amazon/commands/order/sync'
require 'amazon/commands/order/list'
require 'amazon/commands/order/show'
require 'amazon/commands/order/search'

require 'minitest/autorun'

# --- helpers -----------------------------------------------------------

def capture_io_streams
  old_out, old_err = $stdout, $stderr
  out, err = StringIO.new, StringIO.new
  $stdout, $stderr = out, err
  yield
  [out.string, err.string]
ensure
  $stdout, $stderr = old_out, old_err
end

# Swap Amazon::Worker.new for something that doesn't touch the network.
# `builder` receives the constructor args and returns the stand-in (or raises).
def with_worker(builder)
  original = Amazon::Worker.method(:new)
  Amazon::Worker.define_singleton_method(:new) { |*args, **kw| builder.call(*args, **kw) }
  yield
ensure
  Amazon::Worker.define_singleton_method(:new, original)
end

# Replace a command class with a stand-in that just records it ran.
def with_command(mod, name, result: 0)
  original = mod.const_get(name)
  fake = Class.new do
    define_method(:initialize) { |_global| }
    define_method(:run) { |_argv| result }
  end
  mod.send(:remove_const, name)
  mod.const_set(name, fake)
  yield
ensure
  mod.send(:remove_const, name)
  mod.const_set(name, original)
end

def write_config!
  Amazon::Config.ensure_dirs!
  File.write(Amazon::Config.config_path, JSON.generate({ 'email' => 'test@example.com' }))
end

def seed_order!(order)
  store = Amazon::Store.new
  store.write_order(order)
  store.commit_index!
  store
end

SAMPLE_ORDER = {
  'order_id' => '111-0000000-0000001',
  'order_placed' => '2023-12-10',
  'grand_total' => 46.07,
  'items' => [
    { 'title' => '3D Pen Filament 320 Feet',
      'link' => 'https://www.amazon.com/dp/B0747R1M51?ref_=ppx',
      'price' => 17.99 },
    { 'title' => 'No link item', 'price' => 5.00 }
  ]
}.freeze

# --- Formatter ---------------------------------------------------------

class FormatterTest < Minitest::Test
  def fmt(**kw) = Amazon::Formatter.new(color: false, **kw)

  def test_item_renders_all_fields
    out, = capture_io_streams do
      fmt.item(
        'asin' => 'B0747R1M51', 'url' => 'https://www.amazon.com/dp/B0747R1M51',
        'title' => 'PLA Filament', 'price' => 12.99, 'list_price' => 19.99,
        'availability' => 'In Stock', 'delivery_raw' => 'FREE delivery Tuesday, July 28',
        'delivery_date' => (Date.today + 2).iso8601, 'seller' => 'Dikale US',
        'rating' => 4.6, 'reviews' => 4640, 'coupon' => '10% off',
        'purchases' => [{ 'date' => '2023-12-10', 'price' => 17.99, 'order_id' => '111-1' }]
      )
    end
    assert_includes out, 'PLA Filament'
    assert_includes out, '$12.99'
    assert_includes out, 'was $19.99'
    assert_includes out, 'In Stock'
    assert_includes out, 'Dikale US'
    assert_includes out, '4.6★'
    assert_includes out, '(4,640 ratings)'
    assert_includes out, '10% off'
    assert_includes out, "You've bought this 1x"
    assert_includes out, '(-$5.00)'
  end

  def test_item_handles_missing_price_and_no_purchases
    out, = capture_io_streams { fmt.item('asin' => 'B1', 'title' => 'T', 'purchases' => []) }
    assert_includes out, '(no buybox price)'
    refute_includes out, "You've bought"
  end

  def test_item_nil_and_json
    out, = capture_io_streams { fmt.item(nil) }
    assert_includes out, '(not found)'

    out, = capture_io_streams { fmt(json: true).item({ 'asin' => 'B1' }) }
    assert_equal 'B1', JSON.parse(out)['asin']
  end

  def test_live_search_annotates_prior_purchase_and_sponsored
    out, = capture_io_streams do
      fmt.live_search([
        { 'asin' => 'B1', 'title' => 'Cheap now', 'price' => 12.99, 'rating' => 4.6,
          'reviews' => 4640, 'delivery_raw' => 'FREE delivery Tue', 'sponsored' => false,
          'prior_purchase' => { 'date' => '2023-12-10', 'price' => 17.99 } },
        { 'asin' => 'B2', 'title' => 'Ad', 'price' => 42.99, 'sponsored' => true }
      ], 'q')
    end
    assert_includes out, '↳ bought 2023-12-10 for $17.99'
    assert_includes out, '(-$5.00)'
    assert_includes out, '[sponsored]'
  end

  def test_live_search_price_went_up_and_same
    out, = capture_io_streams do
      fmt.live_search([
        { 'asin' => 'B1', 'title' => 'Pricier', 'price' => 20.00,
          'prior_purchase' => { 'date' => '2020-01-01', 'price' => 15.00 } },
        { 'asin' => 'B2', 'title' => 'Flat', 'price' => 10.0,
          'prior_purchase' => { 'date' => '2020-01-01', 'price' => 10.0 } }
      ], 'q')
    end
    assert_includes out, '(+$5.00)'
    assert_includes out, '(same)'
  end

  def test_live_search_empty_and_json
    out, = capture_io_streams { fmt.live_search([], 'nope') }
    assert_includes out, '(no live results for "nope")'

    out, = capture_io_streams { fmt(json: true).live_search([{ 'asin' => 'B1' }], 'q') }
    assert_equal 'B1', JSON.parse(out).first['asin']
  end

  def test_delivery_phrase_relative_labels
    today, tomorrow = Date.today.iso8601, (Date.today + 1).iso8601
    out, = capture_io_streams do
      fmt.item('title' => 'T', 'delivery_raw' => 'FREE delivery', 'delivery_date' => today)
    end
    assert_includes out, 'delivery today'

    out, = capture_io_streams do
      fmt.item('title' => 'T', 'delivery_raw' => 'delivery', 'delivery_date' => tomorrow)
    end
    assert_includes out, 'delivery tomorrow'
  end

  def test_delivery_phrase_falls_back_to_raw_when_unparsed
    out, = capture_io_streams do
      fmt.item('title' => 'T', 'delivery_raw' => 'Usually ships in 2 months', 'delivery_date' => nil)
    end
    assert_includes out, 'Usually ships in 2 months'
  end

  def test_delivery_phrase_survives_bad_iso_date
    out, = capture_io_streams do
      fmt.item('title' => 'T', 'delivery_raw' => 'soonish', 'delivery_date' => 'not-a-date')
    end
    assert_includes out, 'soonish'
  end

  def test_color_enabled_emits_escapes
    out, = capture_io_streams do
      Amazon::Formatter.new(color: true).live_search(
        [{ 'asin' => 'B1', 'title' => 'T', 'price' => 5.0,
           'prior_purchase' => { 'date' => '2020-01-01', 'price' => 9.0 } }], 'q'
      )
    end
    assert_includes out, "\e[32m" # green: cheaper than you paid
  end

  def test_item_rating_without_review_count
    out, = capture_io_streams { fmt.item('title' => 'T', 'rating' => 4.2, 'purchases' => []) }
    assert_includes out, '4.2★'
    refute_includes out, 'ratings)'
  end

  def test_live_search_row_without_metadata
    out, = capture_io_streams { fmt.live_search([{ 'asin' => 'B1', 'title' => 'Bare', 'price' => 1.0 }], 'q') }
    assert_includes out, 'Bare'
    refute_includes out, '★'
  end

  def test_show_renders_payment_link_and_shipments
    order = SAMPLE_ORDER.merge(
      'ship_to' => 'Eric Boehs',
      'payment_method' => 'Visa',
      'payment_method_last_4' => '4242',
      'order_details_link' => 'https://example.com/order',
      'shipments' => [
        { 'delivery_status' => 'Delivered Jul 4', 'tracking_link' => 'https://track/1' },
        { 'delivery_status' => nil, 'tracking_link' => nil }
      ]
    )
    out, = capture_io_streams { fmt.show(order) }
    assert_includes out, '•••• 4242'
    assert_includes out, 'https://example.com/order'
    assert_includes out, 'Delivered Jul 4'
    assert_includes out, 'https://track/1'
    assert_includes out, '(unknown)'
  end

  def test_show_item_with_quantity
    order = SAMPLE_ORDER.merge('items' => [{ 'title' => 'Widget', 'quantity' => 3, 'price' => 2.5 }])
    out, = capture_io_streams { fmt.show(order) }
    assert_includes out, 'x3 Widget'
  end

  def test_money_passes_through_non_numeric_strings
    out, = capture_io_streams { fmt.list([{ 'date' => 'd', 'order_id' => 'X', 'total' => 'Not Available' }]) }
    assert_includes out, 'Not Available'
  end

  def test_show_falls_back_through_total_fields
    order = { 'order_id' => 'X', 'items' => [], 'subtotal' => 9.99 }
    out, = capture_io_streams { fmt.show(order) }
    assert_includes out, '$9.99'
  end

  def test_existing_order_formatters_still_work
    out, = capture_io_streams { fmt.list([{ 'date' => '2023-01-01', 'order_id' => 'X', 'total' => 5.0 }]) }
    assert_includes out, 'order_id'

    out, = capture_io_streams { fmt.list([]) }
    assert_includes out, 'no orders'

    out, = capture_io_streams { fmt.show(SAMPLE_ORDER.dup) }
    assert_includes out, 'Items (2)'

    out, = capture_io_streams { fmt.show(nil) }
    assert_includes out, '(not found)'

    out, = capture_io_streams { fmt.search([SAMPLE_ORDER.dup], 'filament') }
    assert_includes out, '3D Pen Filament'

    out, = capture_io_streams { fmt.search([], 'zzz') }
    assert_includes out, 'no matches'
  end
end

class FormatterEdgeCaseTest < Minitest::Test
  def fmt(**kw) = Amazon::Formatter.new(color: false, **kw)

  def test_payment_method_without_last_four
    order = SAMPLE_ORDER.merge('payment_method' => 'Gift Card', 'payment_method_last_4' => nil)
    out, = capture_io_streams { fmt.show(order) }
    assert_includes out, 'Payment: Gift Card'
    refute_includes out, '••••'
  end

  def test_show_item_without_price
    order = SAMPLE_ORDER.merge('items' => [{ 'title' => 'Freebie' }])
    out, = capture_io_streams { fmt.show(order) }
    assert_includes out, '• Freebie'
    refute_includes out, 'Freebie —'
  end

  def test_order_search_json_and_order_without_matching_item
    out, = capture_io_streams { fmt(json: true).search([SAMPLE_ORDER.dup], 'q') }
    assert_equal '111-0000000-0000001', JSON.parse(out).first['order_id']

    out, = capture_io_streams { fmt.search([{ 'order_id' => 'X', 'items' => [] }], 'q') }
    assert_includes out, '(no items)'
  end

  def test_price_delta_skips_non_numeric_prices
    out, = capture_io_streams do
      fmt.live_search([{ 'asin' => 'B1', 'title' => 'T', 'price' => nil,
                         'prior_purchase' => { 'date' => '2020-01-01', 'price' => nil } }], 'q')
    end
    assert_includes out, 'bought 2020-01-01'
    refute_includes out, '(-$'
    refute_includes out, '(+$'
  end

  def test_long_titles_are_truncated_to_terminal_width
    old = ENV['COLUMNS']
    ENV['COLUMNS'] = '80'
    out, = capture_io_streams do
      Amazon::Formatter.new(color: false).live_search(
        [{ 'asin' => 'B1', 'title' => 'x' * 300, 'price' => 1.0 }], 'q'
      )
    end
    assert_includes out, '…'
    assert out.lines.first.length < 200, 'title should be truncated'
  ensure
    old ? ENV['COLUMNS'] = old : ENV.delete('COLUMNS')
  end

  def test_red_used_when_price_rose
    out, = capture_io_streams do
      Amazon::Formatter.new(color: true).live_search(
        [{ 'asin' => 'B1', 'title' => 'T', 'price' => 20.0,
           'prior_purchase' => { 'date' => '2020-01-01', 'price' => 5.0 } }], 'q'
      )
    end
    assert_includes out, "\e[31m"
  end
end

# --- Config paths ------------------------------------------------------

class ConfigPathsTest < Minitest::Test
  def test_xdg_paths_fall_back_to_home_when_unset
    saved = ENV.to_h.slice('XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME')
    saved.each_key { |k| ENV.delete(k) }

    assert_equal Pathname(Dir.home).join('.config'), Amazon::Config.xdg_config_home
    assert_equal Pathname(Dir.home).join('.local/share'), Amazon::Config.xdg_data_home
    assert_equal Pathname(Dir.home).join('.local/state'), Amazon::Config.xdg_state_home
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  def test_load_raises_when_config_missing
    Amazon::Config.ensure_dirs!
    path = Amazon::Config.config_path
    backup = path.exist? ? File.read(path) : nil
    FileUtils.rm_f(path)

    err = assert_raises(RuntimeError) { Amazon::Config.load }
    assert_includes err.message, 'config not found'

    # write_default! creates the file only when it's absent.
    Amazon::Config.write_default!
    assert path.exist?
    assert_includes File.read(path), 'you@example.com'
  ensure
    File.write(path, backup) if backup
  end

  def test_defaults_are_merged
    cfg = Amazon::Config.new({ 'email' => 'a@b.c' })
    assert_equal 2, cfg.default_year_window
    assert cfg.color?
    assert_equal 'a@b.c', cfg.email
    refute Amazon::Config.new({ 'output' => { 'color' => false } }).color?
  end
end

# --- Cache -------------------------------------------------------------

class CacheTest < Minitest::Test
  def setup
    Amazon::Config.ensure_dirs!
    @cache = Amazon::Cache.new("test-#{rand(1_000_000)}")
  end

  def test_fetch_misses_then_hits
    calls = 0
    2.times { @cache.fetch('k') { calls += 1; { 'v' => calls } } }
    assert_equal 1, calls, 'second fetch should hit cache'
    assert_equal({ 'v' => 1 }, @cache.read('k'))
  end

  def test_expired_entry_is_a_miss
    @cache.write('k', { 'v' => 1 })
    expired = Amazon::Cache.new('x', ttl: 0)
    assert_nil expired.read('k')
  end

  def test_entry_older_than_ttl_is_a_miss
    ns = "stale-#{rand(1_000_000)}"
    cache = Amazon::Cache.new(ns, ttl: 60)
    cache.write('k', { 'v' => 1 })
    path = Dir[File.join(Amazon::Config.cache_dir, 'live', ns, '*.json')].first
    File.utime(Time.now - 3600, Time.now - 3600, path)

    assert_nil cache.read('k'), 'an hour-old entry should miss a 60s TTL'
  end

  def test_disabled_cache_always_misses_and_reruns
    disabled = Amazon::Cache.new('y', enabled: false)
    calls = 0
    2.times { disabled.fetch('k') { calls += 1 } }
    assert_equal 2, calls
    assert_nil disabled.read('k')
  end

  def test_age_and_missing_key
    assert_nil @cache.read('absent')
    assert_nil @cache.age('absent')
    @cache.write('k', { 'v' => 1 })
    assert_operator @cache.age('k'), :>=, 0
  end

  def test_corrupt_entry_is_treated_as_miss
    ns = "corrupt-#{rand(1_000_000)}"
    cache = Amazon::Cache.new(ns)
    cache.write('k', { 'v' => 1 })
    path = Dir[File.join(Amazon::Config.cache_dir, 'live', ns, '*.json')].first
    refute_nil path, 'cache should have written a file'
    File.write(path, 'not json{')
    assert_nil cache.read('k')
  end
end

# --- Store ASIN index --------------------------------------------------

class StoreAsinTest < Minitest::Test
  def test_asin_from_link_shapes
    assert_equal 'B0747R1M51', Amazon::Store.asin_from('https://www.amazon.com/dp/B0747R1M51?ref_=x')
    assert_equal 'B0747R1M51', Amazon::Store.asin_from('https://www.amazon.com/gp/product/B0747R1M51')
    assert_nil Amazon::Store.asin_from('https://www.amazon.com/something-else')
    assert_nil Amazon::Store.asin_from(nil)
  end

  def test_write_order_requires_id_and_defaults_year
    write_config!
    store = Amazon::Store.new
    assert_raises(RuntimeError) { store.write_order({ 'items' => [] }) }

    store.write_order({ 'order_id' => 'X-1', 'items' => [] }) # no order_placed
    store.commit_index!
    assert_equal Time.now.year, store.index['orders']['X-1']['year']
  end

  def test_each_order_without_block_returns_enumerator
    write_config!
    seed_order!(SAMPLE_ORDER.dup)
    assert_kind_of Enumerator, Amazon::Store.new.each_order
  end

  def test_search_matches_on_order_id
    write_config!
    store = seed_order!(SAMPLE_ORDER.dup)
    assert_equal 1, store.search('111-0000000-0000001').size
  end

  def test_purchases_by_asin_and_last_purchase
    write_config!
    store = seed_order!(SAMPLE_ORDER.dup)

    purchases = store.purchases_by_asin
    assert_equal 1, purchases['B0747R1M51'].size
    assert_equal 17.99, purchases['B0747R1M51'].first['price']
    assert_equal '2023-12-10', store.last_purchase('B0747R1M51')['date']
    assert_nil store.last_purchase('B000000000'), 'unknown ASIN has no prior purchase'
  end
end

# --- CLI dispatch ------------------------------------------------------

class CLIDispatchTest < Minitest::Test
  def setup = write_config!

  def test_help_lists_both_namespaces
    out, = capture_io_streams { Amazon::CLI.run(['help']) }
    assert_includes out, 'order sync'
    assert_includes out, 'item'
  end

  def test_moved_commands_point_at_order_namespace
    %w[sync list show].each do |cmd|
      _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run([cmd]) }
      assert_includes err, "`#{cmd}` moved to `amazon order #{cmd}`"
    end
  end

  def test_search_stays_top_level_and_is_live
    # `search` must NOT be caught by the moved-command branch.
    _, err = capture_io_streams { Amazon::CLI.run(%w[search]) }
    assert_includes err, 'query is required'
    refute_includes err, 'moved to'
  end

  def test_unknown_command
    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(['bogus']) }
    assert_includes err, 'unknown command'
  end

  def test_order_namespace_help_and_unknown_sub
    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[order --help]) }
    assert_includes out, 'Subcommands:'

    capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[order]) }

    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[order bogus]) }
    assert_includes err, 'unknown order subcommand'
  end

  def test_order_list_and_show_route_through_namespace
    seed_order!(SAMPLE_ORDER.dup)
    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[order list]) }
    assert_includes out, '111-0000000-0000001'

    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(['order', 'show', '111-0000000-0000001']) }
    assert_includes out, 'Items (2)'

    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[order show]) }
    assert_includes err, 'order id is required'
  end

  def test_order_list_options
    seed_order!(SAMPLE_ORDER.dup)

    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[order list --year 2023]) }
    assert_includes out, '111-0000000-0000001'

    out, = capture_io_streams { Amazon::CLI.run(%w[order list --year 1999]) }
    assert_includes out, 'no orders'

    out, = capture_io_streams { Amazon::CLI.run(%w[order list --limit 1]) }
    assert_equal 2, out.lines.size, 'header + one row'

    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[order list --help]) }
    assert_includes out, 'Usage: amazon order list'

    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[order list --bogus]) }
    assert_includes err, 'unknown list option'
  end

  def test_order_show_json_and_missing_order
    seed_order!(SAMPLE_ORDER.dup)

    out, = capture_io_streams { Amazon::CLI.run(['--json', 'order', 'show', '111-0000000-0000001']) }
    assert_equal '111-0000000-0000001', JSON.parse(out)['order_id']

    out, = capture_io_streams { assert_equal 1, Amazon::CLI.run(%w[order show 111-9999999-9999999]) }
    assert_includes out, '(not found)'

    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[order show --help]) }
    assert_includes out, 'Usage: amazon order show'
  end

  def test_order_search_year_filter_and_help
    seed_order!(SAMPLE_ORDER.dup)

    out, = capture_io_streams { Amazon::CLI.run(%w[order search filament --year 2023]) }
    assert_includes out, '3D Pen Filament'

    out, = capture_io_streams { Amazon::CLI.run(%w[order search filament --year 1999]) }
    assert_includes out, 'no matches'

    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[order search --help]) }
    assert_includes out, 'Usage: amazon order search'
  end

  def test_order_search_matches_history
    seed_order!(SAMPLE_ORDER.dup)
    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[order search filament]) }
    assert_includes out, '3D Pen Filament'

    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[order search]) }
    assert_includes err, 'query is required'
  end

  def test_global_flags_are_stripped_before_subcommand
    seed_order!(SAMPLE_ORDER.dup)
    out, = capture_io_streams { Amazon::CLI.run(%w[--json order list]) }
    assert_kind_of Array, JSON.parse(out)

    %w[-q --quiet -v --verbose].each do |flag|
      capture_io_streams { assert_equal 0, Amazon::CLI.run([flag, 'order', 'list']) }
    end
  end

  def test_login_and_order_sync_route_to_their_commands
    with_command(Amazon::Commands, :Login) do
      assert_equal 0, Amazon::CLI.run(%w[login])
    end
    with_command(Amazon::Commands::Order, :Sync) do
      assert_equal 0, Amazon::CLI.run(%w[order sync])
    end
  end

  def test_worker_errors_surface_as_exit_1
    with_worker(->(*) { raise Amazon::Worker::Error, 'no saved session' }) do
      _, err = capture_io_streams { assert_equal 1, Amazon::CLI.run(%w[item B0747R1M51]) }
      assert_includes err, 'no saved session'
    end
  end
end

# --- Live commands (worker stubbed) ------------------------------------

class FakeWorker
  ITEM = {
    'asin' => 'B0747R1M51', 'title' => 'PLA Filament', 'price' => 12.99,
    'availability' => 'In Stock', 'delivery_raw' => 'FREE delivery Tuesday, July 28',
    'delivery_date' => '2026-07-28', 'seller' => 'Dikale US'
  }.freeze
  RESULTS = [
    { 'asin' => 'B0747R1M51', 'title' => 'PLA Filament', 'price' => 12.99, 'sponsored' => false },
    { 'asin' => 'B0000000AD', 'title' => 'Sponsored thing', 'price' => 99.0, 'sponsored' => true }
  ].freeze

  def item(_asin) = ITEM.dup
  def search(_query, limit: 10) = RESULTS.first(limit).map(&:dup)
end

class LiveCommandsTest < Minitest::Test
  def setup
    write_config!
    seed_order!(SAMPLE_ORDER.dup)
  end

  def test_item_merges_purchase_history
    out, = with_worker(->(*) { FakeWorker.new }) do
      capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[item B0747R1M51 --fresh]) }
    end
    assert_includes out, 'PLA Filament'
    assert_includes out, "You've bought this 1x"
    assert_includes out, '2023-12-10'
  end

  def test_item_accepts_url_and_json
    out, = with_worker(->(*) { FakeWorker.new }) do
      capture_io_streams do
        Amazon::CLI.run(['--json', 'item', 'https://www.amazon.com/dp/B0747R1M51', '--fresh'])
      end
    end
    parsed = JSON.parse(out)
    assert_equal 1, parsed['purchases'].size
  end

  def test_item_exits_1_when_worker_returns_nothing
    nil_worker = Class.new { def item(_asin) = nil }.new
    with_worker(->(*) { nil_worker }) do
      capture_io_streams { assert_equal 1, Amazon::CLI.run(%w[item B0747R1M51 --fresh]) }
    end
  end

  def test_item_requires_target_and_supports_help
    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[item]) }
    assert_includes err, 'ASIN or product URL is required'

    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[item --help]) }
    assert_includes out, 'Usage: amazon item'
  end

  def test_search_annotates_and_filters_sponsored
    out, = with_worker(->(*) { FakeWorker.new }) do
      capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[search filament --fresh]) }
    end
    assert_includes out, '↳ bought 2023-12-10 for $17.99'
    assert_includes out, '[sponsored]'

    out, = with_worker(->(*) { FakeWorker.new }) do
      capture_io_streams { Amazon::CLI.run(%w[search filament --no-sponsored --fresh]) }
    end
    refute_includes out, '[sponsored]'
  end

  def test_search_limit_and_help
    out, = with_worker(->(*) { FakeWorker.new }) do
      capture_io_streams { Amazon::CLI.run(%w[search filament --limit 1 --fresh]) }
    end
    refute_includes out, 'Sponsored thing'

    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[search --help]) }
    assert_includes out, 'amazon order search'
  end
end

# --- Config / misc commands -------------------------------------------

class ConfigCommandTest < Minitest::Test
  def setup = write_config!

  def test_config_show_and_path
    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[config show]) }
    assert_includes out, 'test@example.com'

    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[config path]) }
    assert_includes out, 'config.json'
  end

  def test_config_help_and_unknown_action
    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[config --help]) }
    assert_includes out, 'Usage: amazon config'

    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[config bogus]) }
    assert_includes err, 'unknown config action'
  end

  def test_config_edit_shells_out_to_editor
    ENV['VISUAL'] = 'true' # a no-op editor that exits 0
    capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[config edit]) }

    ENV['VISUAL'] = 'false' # editor exits non-zero
    capture_io_streams { assert_equal 1, Amazon::CLI.run(%w[config edit]) }
  ensure
    ENV.delete('VISUAL')
  end

  def test_buy_is_stubbed
    capture_io_streams { Amazon::CLI.run(%w[buy]) }
  end
end
