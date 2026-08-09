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
  # Browser- and 1Password-bound: `login` drives a real Chrome window and
  # `order sync` shells out to `op` and the amazon-orders worker, so both are
  # verified by live runs. Everything else is graded, including worker.rb —
  # its NDJSON protocol is driven against a stub subprocess.
  add_filter '/lib/amazon/commands/login.rb'
  add_filter '/lib/amazon/commands/order/sync.rb'
  minimum_coverage line: 99, branch: 95
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
require 'amazon/commands/args'
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

# All tests share one XDG root, so wipe the archive before seeding — otherwise
# one test's orders leak into the next one's assertions, and a deliberately
# corrupted index breaks every test that runs after it.
def reset_store!
  FileUtils.rm_rf(Amazon::Config.orders_dir)
  FileUtils.rm_f(Amazon::Config.index_path)
end

def seed_order!(order)
  reset_store!
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

  def test_read_disabled_always_misses_and_reruns
    fresh = Amazon::Cache.new('y', read: false)
    calls = 0
    2.times { fresh.fetch('k') { calls += 1 } }
    assert_equal 2, calls
    assert_nil fresh.read('k'), 'reads stay disabled on this instance'
  end

  # `--fresh` means "don't trust the disk", not "don't record what I fetched".
  # If it skipped the write, the stale entry would keep its original mtime and a
  # plain run right after a --fresh one would serve the *older* value.
  def test_read_disabled_still_refreshes_the_stored_entry
    ns = "fresh-#{rand(1_000_000)}"
    Amazon::Cache.new(ns).write('k', { 'v' => 'stale' })

    Amazon::Cache.new(ns, read: false).fetch('k') { { 'v' => 'new' } }

    assert_equal({ 'v' => 'new' }, Amazon::Cache.new(ns).read('k'))
  end

  def test_write_disabled_stores_nothing
    ns = "nowrite-#{rand(1_000_000)}"
    cache = Amazon::Cache.new(ns, write: false)
    cache.fetch('k') { { 'v' => 1 } }
    assert_nil cache.read('k')
  end

  # An empty result is what selector drift looks like from Ruby's side. Caching
  # it turns one bad scrape into a sticky "no results" for the whole TTL.
  def test_empty_results_are_not_cached
    ns = "empty-#{rand(1_000_000)}"
    cache = Amazon::Cache.new(ns)
    calls = 0
    2.times { cache.fetch('k') { calls += 1; [] } }
    assert_equal 2, calls, 'an empty array must not satisfy the second call'
    assert_nil cache.read('k')
  end

  def test_stored_empty_array_reads_as_a_miss
    ns = "storedempty-#{rand(1_000_000)}"
    cache = Amazon::Cache.new(ns)
    path = File.join(Amazon::Config.cache_dir, 'live', ns, "#{Digest::SHA256.hexdigest('k')[0, 16]}.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, '[]')
    assert_nil cache.read('k')
  end

  # false is a legitimate cached value; only empty collections are suspect.
  def test_false_is_a_real_cache_hit
    ns = "falsy-#{rand(1_000_000)}"
    cache = Amazon::Cache.new(ns)
    calls = 0
    2.times { cache.fetch('k') { calls += 1; false } }
    assert_equal 1, calls
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

# --- Argument validation ----------------------------------------------
#
# `Integer()` raises ArgumentError/TypeError, neither of which is a
# RuntimeError, so before Commands::Args these escaped CLI#run's rescue and
# printed a backtrace at the user for a typo'd flag.

class ArgValidationTest < Minitest::Test
  def setup
    write_config!
    seed_order!(SAMPLE_ORDER.dup)
  end

  def assert_usage_error(argv, expect)
    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(argv) }
    assert_includes err, expect
    refute_includes err, 'backtrace'
    refute_match(/\.rb:\d+:in /, err, 'a usage error must not print a backtrace')
  end

  def test_non_numeric_limit_is_a_usage_error
    assert_usage_error(%w[search foo --limit abc], '--limit needs a number')
    assert_usage_error(%w[order list --limit abc], '--limit needs a number')
    assert_usage_error(%w[order list --year abc], '--year needs a number')
    assert_usage_error(%w[order search foo --year abc], '--year needs a number')
  end

  def test_missing_value_after_numeric_flag_is_a_usage_error
    assert_usage_error(%w[search foo --limit], '--limit needs a number')
    assert_usage_error(%w[order list --year], '--year needs a number')
  end

  def test_unknown_flags_are_rejected_rather_than_taken_as_positionals
    assert_usage_error(%w[item --limit 5 B0747R1M51], 'unknown option: --limit')
    assert_usage_error(%w[search --bogus filament], 'unknown option: --bogus')
    assert_usage_error(%w[order show --jsn 111-0000000-0000001], 'unknown option: --jsn')
    assert_usage_error(%w[order search --nope filament], 'unknown option: --nope')
  end

  def test_integer_list_arg_parses_and_validates
    helper = Object.new.extend(Amazon::Commands::Args)
    assert_equal [2024, 2025], helper.integer_list_arg!('--years', '2024,2025')
    assert_equal [2024], helper.integer_list_arg!('--years', ' 2024 ,')

    err = assert_raises(Amazon::Commands::Args::BadArgument) { helper.integer_list_arg!('--years', nil) }
    assert_includes err.message, 'comma-separated'
    assert_raises(Amazon::Commands::Args::BadArgument) { helper.integer_list_arg!('--years', ',,') }
    assert_raises(Amazon::Commands::Args::BadArgument) { helper.integer_list_arg!('--years', '2024,nope') }
  end

  def test_reject_unknown_flag_allows_positionals
    helper = Object.new.extend(Amazon::Commands::Args)
    assert_nil helper.reject_unknown_flag!('filament')
    assert_nil helper.reject_unknown_flag!(nil)
  end
end

# --- Multi-order archive ----------------------------------------------
#
# The original fixtures were a single order with a single purchase, which made
# the sort, the limit, and last_purchase's "most recent" premise all vacuous.

MULTI_ORDERS = [
  { 'order_id' => '111-0000000-0000001', 'order_placed' => '2023-12-10', 'grand_total' => 46.07,
    'items' => [{ 'title' => 'Filament (old)', 'link' => 'https://www.amazon.com/dp/B0747R1M51', 'price' => 17.99 }] },
  { 'order_id' => '222-0000000-0000002', 'order_placed' => '2025-03-02', 'grand_total' => 20.00,
    'items' => [{ 'title' => 'Filament (new)', 'link' => 'https://www.amazon.com/dp/B0747R1M51', 'price' => 14.50 }] },
  { 'order_id' => '333-0000000-0000003', 'order_placed' => '2024-06-15', 'grand_total' => 99.99,
    'items' => [{ 'title' => 'Something else', 'link' => 'https://www.amazon.com/dp/B0CH7T8QTR', 'price' => 99.99 }] }
].freeze

def seed_multi!
  reset_store!
  store = Amazon::Store.new
  MULTI_ORDERS.each { |o| store.write_order(Marshal.load(Marshal.dump(o))) }
  store.commit_index!
  store
end

class MultiOrderStoreTest < Minitest::Test
  def test_list_sorts_newest_first_across_years
    store = seed_multi!
    assert_equal %w[222-0000000-0000002 333-0000000-0000003 111-0000000-0000001],
                 store.list.map { |r| r['order_id'] }
  end

  def test_list_limit_keeps_the_newest
    store = seed_multi!
    assert_equal ['222-0000000-0000002'], store.list(limit: 1).map { |r| r['order_id'] }
  end

  def test_list_year_filter
    store = seed_multi!
    assert_equal ['333-0000000-0000003'], store.list(year: 2024).map { |r| r['order_id'] }
  end

  def test_last_purchase_returns_the_most_recent_not_just_the_first
    store = seed_multi!
    last = store.last_purchase('B0747R1M51')
    assert_equal '2025-03-02', last['date']
    assert_in_delta 14.50, last['price']
    assert_equal 2, store.purchases_by_asin['B0747R1M51'].size
  end

  def test_purchases_are_ordered_newest_first
    store = seed_multi!
    dates = store.purchases_by_asin['B0747R1M51'].map { |p| p['date'] }
    assert_equal %w[2025-03-02 2023-12-10], dates
  end

  def test_unknown_asin_has_no_purchases
    store = seed_multi!
    assert_nil store.last_purchase('B000000000')
    assert_nil store.purchases_by_asin['B000000000']
  end
end

# --- Totals -----------------------------------------------------------
#
# Only grand_total is the amount actually charged; total_before_tax excludes
# tax and subtotal excludes tax *and* shipping. Old orders amazon-orders can't
# fully parse fall back to those, so the archive has to record which it used.

class TotalSourceTest < Minitest::Test
  # `order list` refuses to run without a config, and test order is randomized.
  def setup = write_config!

  def write(order)
    reset_store!
    store = Amazon::Store.new
    store.write_order(order)
    store.commit_index!
    store.index['orders'][order['order_id']]
  end

  def test_grand_total_is_recorded_as_authoritative
    meta = write('order_id' => 'a', 'order_placed' => '2025-01-01', 'grand_total' => 10.0,
                 'total_before_tax' => 9.0, 'subtotal' => 8.0)
    assert_in_delta 10.0, meta['total']
    assert_equal 'grand_total', meta['total_source']
    refute Amazon::Store.estimated_total?(meta)
  end

  def test_missing_grand_total_falls_back_and_is_flagged
    meta = write('order_id' => 'b', 'order_placed' => '2025-01-01', 'total_before_tax' => 9.0, 'subtotal' => 8.0)
    assert_in_delta 9.0, meta['total']
    assert_equal 'total_before_tax', meta['total_source']
    assert Amazon::Store.estimated_total?(meta)
  end

  def test_subtotal_only_is_flagged
    meta = write('order_id' => 'c', 'order_placed' => '2025-01-01', 'subtotal' => 8.0)
    assert_equal 'subtotal', meta['total_source']
    assert Amazon::Store.estimated_total?(meta)
  end

  def test_order_with_no_total_at_all
    meta = write('order_id' => 'd', 'order_placed' => '2025-01-01')
    assert_nil meta['total']
    assert_nil meta['total_source']
    refute Amazon::Store.estimated_total?(meta), 'no total is unknown, not estimated'
  end

  # Rows written before total_source existed have no marker; don't flag them all.
  def test_legacy_rows_without_total_source_are_not_flagged
    refute Amazon::Store.estimated_total?('total' => 10.0)
  end

  def test_list_output_marks_estimated_totals
    seed_order!('order_id' => 'e', 'order_placed' => '2025-01-01', 'subtotal' => 8.0)
    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[order list]) }
    assert_includes out, '~$8.00'
    assert_includes out, 'excludes tax'
  end

  def test_list_output_leaves_real_totals_unmarked
    seed_order!(SAMPLE_ORDER.dup)
    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[order list]) }
    assert_includes out, '$46.07'
    refute_includes out, '~$'
    refute_includes out, 'excludes tax'
  end
end

# --- Corruption tolerance ---------------------------------------------

class CorruptStoreTest < Minitest::Test
  def setup = write_config!

  # These tests deliberately poison the shared XDG store. Without this, a
  # later test that builds a Store without seeding first inherits the corrupt
  # index and errors — order-dependent, so it only shows up on some seeds.
  def teardown = reset_store!

  def test_unreadable_order_file_is_skipped_not_fatal
    store = seed_multi!
    path = File.join(Amazon::Config.data_dir, store.index['orders']['111-0000000-0000001']['file'])
    File.write(path, '{"items": [trunc')

    fresh = Amazon::Store.new
    _, err = capture_io_streams do
      # The other two orders still resolve.
      assert_equal 1, fresh.purchases_by_asin['B0747R1M51'].size
    end
    assert_includes err, 'skipping unreadable order 111-0000000-0000001'
  end

  def test_missing_order_file_is_skipped
    store = seed_multi!
    File.delete(File.join(Amazon::Config.data_dir, store.index['orders']['333-0000000-0000003']['file']))

    fresh = Amazon::Store.new
    _, err = capture_io_streams { assert_nil fresh.last_purchase('B0CH7T8QTR') }
    assert_includes err, 'skipping unreadable order 333-0000000-0000003'
  end

  def test_corrupt_index_raises_an_actionable_message
    seed_multi!
    File.write(Amazon::Config.index_path, '{"orders": {trunc')
    err = assert_raises(Amazon::Store::Error) { Amazon::Store.new.index }
    assert_includes err.message, 'is corrupt'
    assert_includes err.message, 'sync --full'
  end

  def test_corrupt_index_surfaces_as_exit_1_not_a_backtrace
    seed_multi!
    File.write(Amazon::Config.index_path, '{"orders": {trunc')
    _, err = capture_io_streams { assert_equal 1, Amazon::CLI.run(%w[order list]) }
    assert_includes err, 'is corrupt'
  end

  # Write-then-rename, so an interrupted sync can't leave a half-written index.
  def test_index_write_leaves_no_temp_files_behind
    seed_multi!
    leftovers = Dir.glob(File.join(Amazon::Config.data_dir, '.*tmp'))
    assert_empty leftovers
  end
end

# --- Worker subprocess plumbing ---------------------------------------
#
# Run against a stub worker script rather than the real Python one: this is
# where the NDJSON protocol, the prompt round-trip, and the exit-status check
# actually live, and all three are cheap to drive from a subprocess that isn't
# Playwright.

def with_python_cmd(script_body)
  original = Amazon::Worker.instance_method(:python_cmd)
  script = "require 'json'\n#{script_body}"
  Amazon::Worker.send(:define_method, :python_cmd) { |_script| ['ruby', '-e', script] }
  yield
ensure
  Amazon::Worker.send(:define_method, :python_cmd, original)
  Amazon::Worker.send(:private, :python_cmd)
end

class WorkerProtocolTest < Minitest::Test
  def worker(**kw) = Amazon::Worker.new(**kw)

  # Playwright and friends print to stdout uninvited; a stray line must not
  # abort the run, and it's only worth surfacing under -v.
  def test_non_json_stdout_is_skipped
    body = <<~SCRIPT
      STDIN.gets
      puts 'Downloading Chromium 131.0 ...'
      puts({event: 'item', data: { 'asin' => 'B1' }}.to_json)
      puts({event: 'done', count: 1}.to_json)
    SCRIPT
    with_python_cmd(body) do
      data = nil
      _, err = capture_io_streams { data = worker(verbose: true).item('B1') }
      assert_equal 'B1', data['asin']
      assert_includes err, 'non-JSON output: Downloading Chromium'

      _, err = capture_io_streams { worker.item('B1') }
      assert_empty err
    end
  end

  # The regression: item/search dropped every log event unless -v was passed,
  # so `live.py`'s selector-rot warning — which exists precisely to tell you the
  # output you're reading is missing fields — could never reach anyone. Each
  # field degrades to null on its own, so the report still looks complete.
  def test_worker_warnings_reach_stderr_without_verbose
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'log', level: 'warn', msg: "4/6 expected fields were empty"}.to_json)
      puts({event: 'log', level: 'info', msg: 'fetching B1'}.to_json)
      puts({event: 'item', data: { 'asin' => 'B1' }}.to_json)
      puts({event: 'done', count: 1}.to_json)
    SCRIPT
    with_python_cmd(body) do
      _, err = capture_io_streams { worker.item('B1') }
      assert_includes err, '[worker:warn] 4/6 expected fields were empty'
      # Routine progress still stays behind the flag.
      refute_includes err, 'fetching B1'

      _, err = capture_io_streams { worker(verbose: true).item('B1') }
      assert_includes err, '[worker:info] fetching B1'
    end
  end

  def test_search_warnings_reach_stderr_without_verbose
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'log', level: 'warn', msg: 'search markup may have changed'}.to_json)
      puts({event: 'done', count: 0}.to_json)
    SCRIPT
    with_python_cmd(body) do
      _, err = capture_io_streams { worker.search('q') }
      assert_includes err, '[worker:warn] search markup may have changed'
    end
  end

  # A worker that omits `level` is emitting ordinary progress, not a warning —
  # defaulting the other way would make every info line unsuppressable.
  def test_a_level_less_log_is_treated_as_info
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'log', msg: 'no level here'}.to_json)
      puts({event: 'done', count: 0}.to_json)
    SCRIPT
    with_python_cmd(body) do
      _, err = capture_io_streams { worker.search('q') }
      assert_empty err
    end
  end

  def test_item_reads_the_item_event
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'item', data: { 'asin' => 'B1', 'title' => 'T' }}.to_json)
      puts({event: 'done', count: 1}.to_json)
    SCRIPT
    with_python_cmd(body) do
      assert_equal 'B1', worker.item('B1')['asin']
    end
  end

  def test_search_collects_result_events
    body = <<~SCRIPT
      STDIN.gets
      2.times { |i| puts({event: 'result', data: { 'asin' => "B\#{i}" }}.to_json) }
      puts({event: 'done', count: 2}.to_json)
    SCRIPT
    with_python_cmd(body) do
      assert_equal %w[B0 B1], worker.search('q', limit: 5).map { |r| r['asin'] }
    end
  end

  def test_the_request_reaches_the_worker_on_stdin
    body = <<~SCRIPT
      req = JSON.parse(STDIN.gets)
      puts({event: 'item', data: req}.to_json)
      puts({event: 'done', count: 1}.to_json)
    SCRIPT
    with_python_cmd(body) do
      echoed = worker.item('https://www.amazon.com/dp/B0747R1M51')
      assert_equal 'item', echoed['action']
      assert_equal 'https://www.amazon.com/dp/B0747R1M51', echoed['asin']
    end
  end

  # The bug this guards: `return` from inside the popen3 block skipped the exit
  # check entirely, so a worker that emitted `done` and then died in teardown
  # was reported as a clean success.
  def test_a_crash_after_done_is_not_reported_as_success
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'done', count: 0}.to_json)
      STDOUT.flush
      exit 3
    SCRIPT
    with_python_cmd(body) do
      err = assert_raises(Amazon::Worker::Error) { worker.search('q') }
      assert_includes err.message, 'exited 3'
    end
  end

  def test_a_clean_exit_after_done_succeeds
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'done', count: 0}.to_json)
    SCRIPT
    with_python_cmd(body) { assert_empty worker.search('q') }
  end

  # An `error` event carries a better message than the exit code does, so it
  # must win rather than being masked by "python worker exited 1".
  def test_error_event_beats_the_exit_status
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'error', msg: 'no saved session — run: amazon login', kind: 'not_logged_in'}.to_json)
      STDOUT.flush
      exit 1
    SCRIPT
    with_python_cmd(body) do
      err = assert_raises(Amazon::Worker::Error) { worker.item('B1') }
      assert_equal 'no saved session — run: amazon login', err.message
      refute_includes err.message, 'exited 1'
    end
  end

  def test_unkinded_errors_get_the_live_lookup_prefix
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'error', msg: 'boom'}.to_json)
    SCRIPT
    with_python_cmd(body) do
      err = assert_raises(Amazon::Worker::Error) { worker.item('B1') }
      assert_equal 'live lookup failed: boom', err.message
    end
  end

  def test_blocked_errors_pass_through_verbatim
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'error', msg: 'Amazon served a captcha', kind: 'blocked'}.to_json)
    SCRIPT
    with_python_cmd(body) do
      err = assert_raises(Amazon::Worker::Error) { worker.search('q') }
      assert_equal 'Amazon served a captcha', err.message
    end
  end

  def test_non_json_lines_are_skipped_and_logged_when_verbose
    body = <<~SCRIPT
      STDIN.gets
      puts 'this is not json'
      puts({event: 'done', count: 0}.to_json)
    SCRIPT
    with_python_cmd(body) do
      _, err = capture_io_streams { assert_empty worker(verbose: true).search('q') }
      assert_includes err, 'non-JSON output'

      _, err = capture_io_streams { assert_empty worker.search('q') }
      refute_includes err, 'non-JSON output'
    end
  end

  def test_worker_log_events_respect_verbosity
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'log', msg: 'fetching B1'}.to_json)
      puts({event: 'item', data: { 'asin' => 'B1' }}.to_json)
      puts({event: 'done', count: 1}.to_json)
    SCRIPT
    with_python_cmd(body) do
      _, err = capture_io_streams { worker(verbose: true).item('B1') }
      assert_includes err, 'fetching B1'

      _, err = capture_io_streams { worker.item('B1') }
      refute_includes err, 'fetching B1'
    end
  end

  # Output written after `done` must be drained, or a chatty worker blocks on a
  # full pipe while we wait for it to exit.
  def test_a_worker_that_keeps_writing_after_done_does_not_deadlock
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'done', count: 0}.to_json)
      STDOUT.flush
      20_000.times { |i| puts "trailing noise line \#{i}" }
    SCRIPT
    with_python_cmd(body) do
      assert_empty worker.search('q')
    end
  end
end

class WorkerHelpersTest < Minitest::Test
  def test_python_cmd_prefers_the_uv_venv_when_present
    w = Amazon::Worker.new
    cmd = w.send(:python_cmd, 'live.py')
    assert_equal 'live.py', cmd.last
    venv = File.join(Amazon::Worker::PYWORKER, '.venv', 'bin', 'python')
    assert_equal(File.executable?(venv) ? venv : 'python3', cmd.first)
  end

  def test_parse_event_returns_nil_on_junk
    w = Amazon::Worker.new
    assert_nil w.send(:parse_event, 'not json')
    assert_equal({ 'event' => 'done' }, w.send(:parse_event, '{"event":"done"}'))
  end

  def test_live_error_formats_by_kind
    w = Amazon::Worker.new
    assert_equal 'x', w.send(:live_error, 'kind' => 'not_logged_in', 'msg' => 'x')
    assert_equal 'x', w.send(:live_error, 'kind' => 'blocked', 'msg' => 'x')
    assert_equal 'live lookup failed: x', w.send(:live_error, 'msg' => 'x')
  end
end

class ProgressTest < Minitest::Test
  def progress(**kw) = Amazon::Worker::Progress.new(**kw)

  def test_quiet_progress_prints_nothing
    _, err = capture_io_streams do
      p = progress(quiet: true)
      p.start('year' => 2025, 'count' => 3)
      p.tick('i' => 1, 'n' => 3, 'order_id' => 'x', 'title' => 't')
      p.finish('count' => 3)
    end
    assert_empty err
  end

  def test_progress_reports_year_ticks_and_totals
    _, err = capture_io_streams do
      p = progress
      p.start('year' => 2025, 'count' => 2)
      p.tick('i' => 1, 'n' => 2, 'date' => '2025-01-01', 'grand_total' => 12.5,
             'order_id' => '111-1', 'title' => 'Widget')
      p.finish('count' => 2, 'skipped' => 4)
    end
    assert_includes err, 'year 2025: 2 orders'
    assert_includes err, '$12.50'
    assert_includes err, '111-1'
    assert_includes err, 'done: 2 orders (4 skipped)'
  end

  def test_tick_handles_missing_date_and_total
    _, err = capture_io_streams do
      p = progress
      p.tick('i' => 0, 'n' => 0, 'order_id' => 'x', 'title' => nil)
    end
    assert_includes err, 'ETA --:--'
  end

  def test_finish_without_skips_omits_the_suffix
    _, err = capture_io_streams { progress.finish('count' => 1) }
    assert_includes err, 'done: 1 orders'
    refute_includes err, 'skipped'
  end

  def test_clear_is_a_noop_off_a_tty
    _, err = capture_io_streams { progress.clear }
    assert_empty err
  end

  def test_eta_formats_hours_and_minutes
    p = progress
    p.instance_variable_set(:@start_time, Time.now - 3600)
    assert_match(/ETA \d+:\d\d:\d\d/, p.send(:format_eta, 1, 100))

    p2 = progress
    p2.instance_variable_set(:@start_time, Time.now - 10)
    assert_match(/ETA\s+\d+:\d\d/, p2.send(:format_eta, 1, 5))
  end

  def test_bar_renders_empty_and_partial
    p = progress
    assert_includes p.send(:bar, 0, 0), '░'
    assert_includes p.send(:bar, 5, 10), '█'
  end

  # On a TTY the progress line is redrawn in place and truncated to the
  # terminal width; off one it's plain lines. Progress reads $stderr.tty? at
  # construction, so the fake has to be installed before `new`.
  def with_tty_stderr(columns: '60')
    original, original_cols = $stderr, ENV['COLUMNS']
    tty = StringIO.new
    def tty.tty? = true
    $stderr = tty
    ENV['COLUMNS'] = columns
    yield tty
    tty.string
  ensure
    $stderr = original
    ENV['COLUMNS'] = original_cols
  end

  def test_tty_tick_redraws_in_place_and_truncates
    out = with_tty_stderr do |_|
      progress.tick('i' => 1, 'n' => 2, 'date' => '2025-01-01', 'grand_total' => 12.5,
                    'order_id' => '111-1', 'title' => 'A' * 200)
    end
    assert_includes out, "\r\e[2K"
    line = out.split("\r\e[2K").last
    assert_equal 59, line.length, 'line should be truncated to COLUMNS - 1'
  end

  def test_tty_clear_erases_a_drawn_line_once
    out = with_tty_stderr do |_|
      p = progress
      p.tick('i' => 1, 'n' => 2, 'order_id' => 'x', 'title' => 't')
      p.clear
      p.clear # already cleared — must not emit a second escape
    end
    assert_equal 2, out.scan("\r\e[2K").size
  end
end

class WorkerSyncTest < Minitest::Test
  def sync_args(**kw)
    { email: 'e@x.com', password: 'pw', years: [2025] }.merge(kw)
  end

  def test_sync_collects_orders_and_reports_progress
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'total', year: 2025, count: 2}.to_json)
      puts({event: 'progress', i: 1, n: 2, date: '2025-01-01', grand_total: 12.5,
            order_id: '111-1', title: 'Widget'}.to_json)
      puts({event: 'order', data: { 'order_id' => '111-1' }}.to_json)
      puts({event: 'order', data: { 'order_id' => '111-2' }}.to_json)
      puts({event: 'done', count: 2, skipped: 1}.to_json)
    SCRIPT
    with_python_cmd(body) do
      orders = nil
      _, err = capture_io_streams { orders = Amazon::Worker.new.sync(**sync_args) }
      assert_equal %w[111-1 111-2], orders.map { |o| o['order_id'] }
      assert_includes err, 'year 2025: 2 orders'
      assert_includes err, 'done: 2 orders (1 skipped)'
    end
  end

  def test_sync_passes_the_request_through_to_the_worker
    body = <<~SCRIPT
      req = JSON.parse(STDIN.gets)
      puts({event: 'order', data: req}.to_json)
      puts({event: 'done', count: 1}.to_json)
    SCRIPT
    with_python_cmd(body) do
      orders = nil
      capture_io_streams do
        orders = Amazon::Worker.new(quiet: true).sync(
          **sync_args(known_order_ids: %w[a b], rate_limit: { 'detail_delay' => 0.5 })
        )
      end
      req = orders.first
      assert_equal 'sync', req['action']
      assert_equal [2025], req['years']
      assert_equal %w[a b], req['known_order_ids']
      assert_in_delta 0.5, req['detail_delay']
    end
  end

  # A total failure raises; a failure after some orders were fetched keeps them
  # and records why, so the command can exit non-zero.
  def test_sync_raises_when_it_got_nothing
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'error', msg: 'CaptchaForm'}.to_json)
    SCRIPT
    with_python_cmd(body) do
      err = assert_raises(Amazon::Worker::Error) { capture_io_streams { Amazon::Worker.new.sync(**sync_args) } }
      assert_includes err.message, 'CaptchaForm'
    end
  end

  def test_sync_keeps_partial_results_and_records_the_error
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'order', data: { 'order_id' => '111-1' }}.to_json)
      puts({event: 'error', msg: 'connection reset'}.to_json)
    SCRIPT
    with_python_cmd(body) do
      w = Amazon::Worker.new(quiet: true)
      orders = nil
      capture_io_streams { orders = w.sync(**sync_args) }
      assert_equal 1, orders.size
      assert_equal 'connection reset', w.partial_error
    end
  end

  def test_partial_error_is_nil_after_a_complete_sync
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'done', count: 0}.to_json)
    SCRIPT
    with_python_cmd(body) do
      w = Amazon::Worker.new(quiet: true)
      capture_io_streams { w.sync(**sync_args) }
      assert_nil w.partial_error
    end
  end

  def test_worker_warn_logs_show_without_verbose_but_info_logs_do_not
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'log', level: 'warn', msg: 'markup may have changed'}.to_json)
      puts({event: 'log', level: 'info', msg: 'chatty detail'}.to_json)
      puts({event: 'done', count: 0}.to_json)
    SCRIPT
    with_python_cmd(body) do
      _, err = capture_io_streams { Amazon::Worker.new(quiet: true).sync(**sync_args) }
      assert_includes err, 'markup may have changed'
      refute_includes err, 'chatty detail'

      _, err = capture_io_streams { Amazon::Worker.new(quiet: true, verbose: true).sync(**sync_args) }
      assert_includes err, 'chatty detail'
    end
  end
end

class WorkerPromptTest < Minitest::Test
  def with_stdin(text)
    original = $stdin
    $stdin = StringIO.new(text)
    yield
  ensure
    $stdin = original
  end

  def test_otp_prompt_round_trips_through_stdin
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'otp_required', prompt: 'Enter OTP'}.to_json)
      STDOUT.flush
      code = STDIN.gets.to_s.chomp
      puts({event: 'item', data: { 'asin' => code }}.to_json)
      puts({event: 'done', count: 1}.to_json)
    SCRIPT
    with_python_cmd(body) do
      with_stdin("123456\n") do
        data = nil
        _, err = capture_io_streams { data = Amazon::Worker.new.item('B1') }
        assert_equal '123456', data['asin']
        assert_includes err, 'Enter OTP'
      end
    end
  end

  def test_free_text_prompt_shows_choices_and_returns_the_answer
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'prompt', prompt: 'Pick one', choices: ['1) phone', '2) email']}.to_json)
      STDOUT.flush
      answer = STDIN.gets.to_s.chomp
      puts({event: 'item', data: { 'asin' => answer }}.to_json)
      puts({event: 'done', count: 1}.to_json)
    SCRIPT
    with_python_cmd(body) do
      with_stdin("2\n") do
        data = nil
        _, err = capture_io_streams { data = Amazon::Worker.new.item('B1') }
        assert_equal '2', data['asin']
        assert_includes err, '1) phone'
        assert_includes err, 'Pick one'
      end
    end
  end

  def test_otp_prompt_defaults_its_label
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'otp_required'}.to_json)
      STDOUT.flush
      STDIN.gets
      puts({event: 'done', count: 0}.to_json)
    SCRIPT
    with_python_cmd(body) do
      with_stdin("000000\n") do
        _, err = capture_io_streams { Amazon::Worker.new.search('q') }
        assert_includes err, 'OTP'
      end
    end
  end
end

class WorkerStderrTest < Minitest::Test
  def test_worker_stderr_is_shown_only_when_verbose
    body = <<~SCRIPT
      STDIN.gets
      STDERR.puts 'traceback from the worker'
      STDERR.flush
      puts({event: 'done', count: 0}.to_json)
    SCRIPT
    with_python_cmd(body) do
      _, err = capture_io_streams { Amazon::Worker.new(verbose: true).search('q') }
      assert_includes err, 'traceback from the worker'

      _, err = capture_io_streams { Amazon::Worker.new.search('q') }
      refute_includes err, 'traceback from the worker'
    end
  end
end

# --- Session reuse ----------------------------------------------------
#
# These build the files `amazon login` actually writes. An earlier version of
# this check looked for an "expires" key inside cookies.json — which that file
# has never contained — so it always reported "not authenticated" and every
# sync did a full login. Fixtures shaped like the real thing are the point.

class SessionCookieTest < Minitest::Test
  FUTURE = 1_809_648_000 # 2027-05-01
  PAST   = 1_714_521_600 # 2024-05-01

  def setup
    @dir = Amazon::Config.cache_dir
    FileUtils.mkdir_p(@dir)
    FileUtils.rm_f([@dir.join('cookies.json'), @dir.join('storage_state.json')])
  end
  alias teardown setup

  # A flat name => value map, exactly as amazon-orders consumes it.
  def write_jar(**extra)
    File.write(@dir.join('cookies.json'), JSON.generate(
      { 'session-id' => '131-000', 'ubid-main' => '133-000', 'x-main' => 'abc' }.merge(extra)
    ))
  end

  def write_storage_state(cookies)
    File.write(@dir.join('storage_state.json'), JSON.generate('cookies' => cookies, 'origins' => []))
  end

  def cookie(name, expires)
    { 'name' => name, 'value' => 'v', 'domain' => '.amazon.com', 'path' => '/', 'expires' => expires }
  end

  def authenticated?
    sync = Amazon::Commands::Order::Sync.new(
      Amazon::GlobalOptions.new(json: false, quiet: true, verbose: false)
    )
    sync.send(:cookies_authenticated?)
  end

  def test_unexpired_session_skips_the_password_prompt
    write_jar
    write_storage_state([cookie('session-id', FUTURE), cookie('x-main', FUTURE)])
    assert authenticated?
  end

  def test_expired_session_falls_back_to_a_real_login
    write_jar
    write_storage_state([cookie('x-main', PAST)])
    refute authenticated?
  end

  # The regression: the jar alone carries no timestamps, so it can never on its
  # own prove the session is live.
  def test_jar_without_storage_state_is_not_enough
    write_jar
    refute authenticated?
  end

  def test_storage_state_without_the_session_cookie
    write_jar
    write_storage_state([cookie('session-id', FUTURE)])
    refute authenticated?
  end

  # -1 is Playwright's marker for a cookie that dies with the browser; it says
  # nothing about a jar reloaded from disk.
  def test_browser_session_cookie_is_not_proof
    write_jar
    write_storage_state([cookie('x-main', -1)])
    refute authenticated?
  end

  def test_missing_expiry_field
    write_jar
    write_storage_state([{ 'name' => 'x-main', 'value' => 'v' }])
    refute authenticated?
  end

  def test_no_jar_at_all
    write_storage_state([cookie('x-main', FUTURE)])
    refute authenticated?
  end

  def test_jar_without_x_main
    File.write(@dir.join('cookies.json'), JSON.generate('session-id' => '131-000'))
    write_storage_state([cookie('x-main', FUTURE)])
    refute authenticated?
  end

  # A cookie is deleted over HTTP by being set to empty, so a bounced sync
  # leaves the name in the jar with nothing in it. `key?` called that a session:
  # the next sync skipped the password lookup and posted the placeholder at
  # Amazon's login form, which is the exact wedge this check exists to prevent.
  def test_an_emptied_out_session_cookie_is_not_a_session
    write_jar('x-main' => '')
    write_storage_state([cookie('x-main', FUTURE)])
    refute authenticated?
  end

  def test_corrupt_files_are_treated_as_no_session
    File.write(@dir.join('cookies.json'), '{"x-main": trunc')
    write_storage_state([cookie('x-main', FUTURE)])
    refute authenticated?

    write_jar
    File.write(@dir.join('storage_state.json'), 'not json at all')
    refute authenticated?
  end

  def test_unexpected_storage_state_shape
    write_jar
    File.write(@dir.join('storage_state.json'), JSON.generate('cookies' => 'nope'))
    refute authenticated?
  end
end
