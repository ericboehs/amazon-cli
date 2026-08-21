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
  # 1Password-bound: `order sync` shells out to `op` and the amazon-orders
  # worker, so it's verified by live runs. Everything else is graded, including
  # worker.rb and login.rb — the browser lives on the far side of a subprocess,
  # and their NDJSON protocol is driven against a stub one.
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
require 'amazon/secrets'
require 'amazon/cache'
require 'amazon/store'
require 'amazon/reviews'
require 'amazon/worker'
require 'amazon/thumbnail'
require 'amazon/formatter'
require 'amazon/cli'
require 'amazon/commands/args'
require 'amazon/commands/login'
require 'amazon/commands/config'
require 'amazon/commands/buy'
require 'amazon/commands/item'
require 'amazon/commands/reviews'
require 'amazon/commands/search'
require 'amazon/commands/order'
require 'amazon/commands/order/sync'
require 'amazon/commands/order/list'
require 'amazon/commands/order/show'
require 'amazon/commands/order/search'
require 'amazon/commands/subscribe'
require 'amazon/commands/subscribe/cached'
require 'amazon/commands/subscribe/images'
require 'amazon/commands/subscribe/list'
require 'amazon/commands/subscribe/show'
require 'amazon/commands/subscribe/skip'
require 'amazon/commands/subscribe/cancel'
require 'amazon/commands/subscribe/upcoming'

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

def write_config!(extra = {})
  Amazon::Config.ensure_dirs!
  File.write(Amazon::Config.config_path, JSON.generate({ 'email' => 'test@example.com' }.merge(extra)))
end

# Swaps the 1Password reader for a hash. Nothing in the suite may shell out to
# `op` — it would prompt for a fingerprint on the developer's machine and hang
# forever on CI.
def with_secrets(values)
  original = Amazon::Secrets.method(:read)
  Amazon::Secrets.define_singleton_method(:read) do |ref|
    value = values[ref]
    raise Amazon::Secrets::Error, "op read failed for #{ref}: not signed in" if value.nil?

    value
  end
  yield
ensure
  Amazon::Secrets.define_singleton_method(:read, original)
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

# For formatter tests exercising a path other than the empty result. `scope:`
# is required on the real signature, so there is no "unknown denominator" to
# fall back to and every caller states one.
EMPTY_SCOPE = { stored: 0, searched: 0, years: [], year: nil }.freeze

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
    out, = capture_io_streams { fmt.list([{ 'date' => 'd', 'order_id' => 'X', 'total' => 'Not Available' }], scope: EMPTY_SCOPE) }
    assert_includes out, 'Not Available'
  end

  def test_show_falls_back_through_total_fields
    order = { 'order_id' => 'X', 'items' => [], 'subtotal' => 9.99 }
    out, = capture_io_streams { fmt.show(order) }
    assert_includes out, '$9.99'
  end

  def test_existing_order_formatters_still_work
    out, = capture_io_streams do
      fmt.list([{ 'date' => '2023-01-01', 'order_id' => 'X', 'total' => 5.0 }], scope: EMPTY_SCOPE)
    end
    assert_includes out, 'order_id'

    out, = capture_io_streams { fmt.list([], scope: EMPTY_SCOPE) }
    assert_includes out, 'no orders'

    out, = capture_io_streams { fmt.show(SAMPLE_ORDER.dup) }
    assert_includes out, 'Items (2)'

    out, = capture_io_streams { fmt.show(nil) }
    assert_includes out, '(not found)'

    out, = capture_io_streams { fmt.search([SAMPLE_ORDER.dup], 'filament', scope: EMPTY_SCOPE) }
    assert_includes out, '3D Pen Filament'

    out, = capture_io_streams { fmt.search([], 'zzz', scope: EMPTY_SCOPE) }
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
    out, = capture_io_streams { fmt(json: true).search([SAMPLE_ORDER.dup], 'q', scope: EMPTY_SCOPE) }
    assert_equal '111-0000000-0000001', JSON.parse(out).first['order_id']

    out, = capture_io_streams { fmt.search([{ 'order_id' => 'X', 'items' => [] }], 'q', scope: EMPTY_SCOPE) }
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

  # Mirrors the real signature: reviews ride along on the item lookup rather
  # than costing a second page load.
  def item(_asin, reviews: false, review_pages: 0, sort: 'helpful')
    data = ITEM.dup
    return data unless reviews

    @last_review_args = { pages: review_pages, sort: sort }
    data.merge(
      'rating' => 4.8,
      'reviews' => 2400,
      'histogram' => { '5' => 94, '4' => 3, '3' => 1, '2' => 0, '1' => 2 },
      'reviews_sample' => REVIEW_SAMPLE.map(&:dup)
    )
  end

  attr_reader :last_review_args

  def search(_query, limit: 10) = RESULTS.first(limit).map(&:dup)

  REVIEW_SAMPLE = [
    { 'id' => 'R1', 'rating' => 5.0, 'verified' => true, 'vine' => false, 'author' => 'Ann',
      'date' => '2026-03-01', 'title' => 'Great', 'helpful_votes' => 4,
      'body' => 'Prints beautifully and the colours came out vivid across every spool.' },
    { 'id' => 'R2', 'rating' => 5.0, 'verified' => false, 'vine' => false, 'author' => 'Bob',
      'date' => '2026-03-02', 'title' => 'Great', 'helpful_votes' => nil,
      'body' => 'Prints beautifully and the colours came out vivid across every spool.' },
    { 'id' => 'R3', 'rating' => 1.0, 'verified' => true, 'vine' => true, 'author' => 'Cal',
      'date' => '2026-03-03', 'title' => 'Jammed', 'helpful_votes' => 9,
      'body' => 'The filament jammed the extruder twice. Filament diameter varies wildly.' },
    { 'id' => 'R4', 'rating' => 2.0, 'verified' => true, 'vine' => false, 'author' => 'Dee',
      'date' => '2026-03-04', 'title' => 'Jammed again', 'helpful_votes' => 2,
      'body' => 'The filament jammed the extruder on my third print. Diameter varies wildly.' },
    { 'id' => 'R5', 'rating' => 3.0, 'verified' => true, 'vine' => false, 'author' => 'Eli',
      'date' => '2026-03-05', 'title' => 'Mixed', 'helpful_votes' => nil,
      'body' => 'Fine for rough drafts, though the filament jammed once during a long run.' }
  ].freeze
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
    nil_worker = Class.new { def item(_asin, **) = nil }.new
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

  def test_search_rejects_a_limit_below_one
    # Merely useless here rather than fatal, but a flag that silently accepts
    # a value it cannot honour is worth closing at the same time as reviews'.
    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[search filament --limit 0]) }
    assert_includes err, '--limit must be 1 or more'
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

# `login` was excluded from coverage on the grounds that it drives a real Chrome
# window. It doesn't — login.py does, on the far side of a subprocess. What
# login.rb does is read NDJSON off a pipe and decide what the user is told,
# which is the same thing worker.rb does and is graded the same way.
def with_login_python(script_body)
  klass = Amazon::Commands::Login
  original = klass.instance_method(:python_cmd)
  script = "require 'json'\n#{script_body}"
  klass.send(:define_method, :python_cmd) { ['ruby', '-e', script] }
  yield
ensure
  klass.send(:define_method, :python_cmd, original)
  klass.send(:private, :python_cmd)
end

class LoginCommandTest < Minitest::Test
  def login(quiet: false, verbose: false)
    Amazon::Commands::Login.new(Amazon::GlobalOptions.new(json: false, quiet: quiet, verbose: verbose))
  end

  def test_help_needs_no_subprocess
    out, = capture_io_streams { assert_equal 0, login.run(%w[--help]) }
    assert_includes out, 'Usage: amazon login'
    assert_includes out, 'order history'
  end

  def test_it_relays_the_worker_events
    body = <<~SCRIPT
      puts({event: 'navigate', url: 'https://www.amazon.com/your-orders/orders'}.to_json)
      puts({event: 'log', msg: 'waiting (540s left)'}.to_json)
      puts({event: 'done', count: 23, cookies_path: '/tmp/cookies.json'}.to_json)
    SCRIPT
    with_login_python(body) do
      _, err = capture_io_streams { assert_equal 0, login.run([]) }
      assert_includes err, '→ https://www.amazon.com/your-orders/orders'
      assert_includes err, 'waiting (540s left)'
      assert_includes err, 'saved 23 cookies to /tmp/cookies.json'
    end
  end

  def test_quiet_keeps_the_result_and_drops_the_narration
    body = <<~SCRIPT
      puts({event: 'log', msg: 'waiting (540s left)'}.to_json)
      puts({event: 'navigate', url: 'https://www.amazon.com/'}.to_json)
      puts({event: 'done', count: 23, cookies_path: '/tmp/cookies.json'}.to_json)
    SCRIPT
    with_login_python(body) do
      _, err = capture_io_streams { login.run([]) }
      assert_includes err, 'waiting (540s left)'

      _, err = capture_io_streams { login(quiet: true).run([]) }
      refute_includes err, 'waiting'
      refute_includes err, '→ '
      # -q suppresses progress, not the one line saying whether it worked.
      assert_includes err, 'saved 23 cookies'
    end
  end

  def test_an_error_event_is_printed_and_the_exit_code_carried_out
    body = <<~SCRIPT
      puts({event: 'error', msg: 'the browser window was closed before order history loaded'}.to_json)
      exit 1
    SCRIPT
    with_login_python(body) do
      _, err = capture_io_streams { assert_equal 1, login.run([]) }
      assert_includes err, 'amazon login: the browser window was closed'
    end
  end

  # The reason this file is graded now. login.py has statements outside every
  # handler — the two writes, the chmods, `page.goto` — and a disk-full OSError
  # comes out as a traceback on stderr with nothing on stdout. That was
  # discarded unless -v happened to be passed, so the user got exit 1 and not a
  # single line of output.
  def test_a_silent_crash_surfaces_its_stderr
    body = <<~SCRIPT
      warn 'Traceback (most recent call last):'
      warn 'OSError: [Errno 28] No space left on device'
      exit 1
    SCRIPT
    with_login_python(body) do
      _, err = capture_io_streams { assert_equal 1, login.run([]) }
      assert_includes err, 'the browser worker failed'
      assert_includes err, 'No space left on device'
    end
  end

  def test_stderr_is_not_repeated_when_the_worker_already_explained_itself
    body = <<~SCRIPT
      warn 'noisy playwright deprecation notice'
      puts({event: 'error', msg: 'timed out waiting for sign-in (10 min)'}.to_json)
      exit 1
    SCRIPT
    with_login_python(body) do
      _, err = capture_io_streams { assert_equal 1, login.run([]) }
      assert_includes err, 'timed out waiting for sign-in'
      refute_includes err, 'the browser worker failed'
    end
  end

  def test_verbose_relays_stderr_as_it_arrives_without_the_tail
    body = <<~SCRIPT
      warn 'OSError: [Errno 28] No space left on device'
      exit 1
    SCRIPT
    with_login_python(body) do
      _, err = capture_io_streams { assert_equal 1, login(verbose: true).run([]) }
      assert_equal 1, err.scan('No space left on device').length
    end
  end

  def test_a_clean_exit_with_no_stderr_says_nothing_extra
    with_login_python("exit 0") do
      _, err = capture_io_streams { assert_equal 0, login.run([]) }
      assert_empty err
    end
  end

  # A truncated line and a bug in the parser used to look identical: `rescue nil`
  # swallowed every StandardError and returned nil for both.
  def test_non_json_output_is_skipped_and_only_shown_under_v
    body = <<~SCRIPT
      puts '{"event": "log", "msg": "trunc'
      puts({event: 'done', count: 1, cookies_path: '/tmp/c.json'}.to_json)
    SCRIPT
    with_login_python(body) do
      _, err = capture_io_streams { assert_equal 0, login(verbose: true).run([]) }
      assert_includes err, '[login] non-JSON output: {"event": "log", "msg": "trunc'
      assert_includes err, 'saved 1 cookies'

      _, err = capture_io_streams { assert_equal 0, login.run([]) }
      refute_includes err, 'non-JSON'
    end
  end

  def test_blank_lines_are_ignored
    body = <<~SCRIPT
      puts ''
      puts({event: 'done', count: 1, cookies_path: '/tmp/c.json'}.to_json)
    SCRIPT
    with_login_python(body) do
      _, err = capture_io_streams { assert_equal 0, login.run([]) }
      assert_includes err, 'saved 1 cookies'
    end
  end

  def test_the_real_command_prefers_the_venv_interpreter_when_present
    cmd = login.send(:python_cmd)
    assert_equal 'login.py', cmd.last
    assert_match(/python3?\z/, cmd.first)
  end
end

class WorkerProtocolTest < Minitest::Test
  def worker(**kw) = Amazon::Worker.new(**kw)

  # Playwright and friends print to stdout uninvited; a stray line must not
  # abort the run. It is still said out loud, because the parent cannot tell a
  # chatty library apart from a worker cut off mid-`emit`, and only one of
  # those is harmless.
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
      assert_includes err, 'non-JSON output: Downloading Chromium'
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

  # -q is documented as suppressing *non-essential* output, and a warning that
  # the data you are reading is incomplete is the essential case. Pinned as a
  # test because the opposite reading is the tempting one: `quiet:` used to be
  # passed in here and did nothing, so the obvious tidy-up was to wire it into
  # log_event — which would have re-hidden exactly the warning this path exists
  # to surface.
  def test_quiet_does_not_suppress_a_worker_warning
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'log', level: 'warn', msg: "4/6 expected fields were empty"}.to_json)
      puts({event: 'log', level: 'info', msg: 'fetching B1'}.to_json)
      puts({event: 'item', data: { 'asin' => 'B1' }}.to_json)
      puts({event: 'done', count: 1}.to_json)
    SCRIPT
    with_python_cmd(body) do
      _, err = capture_io_streams { worker(quiet: true).item('B1') }
      assert_includes err, '[worker:warn] 4/6 expected fields were empty'
      refute_includes err, 'fetching B1'
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

  # The invariant, which reads as obviously true and wasn't: nothing more
  # severe than a warn can be quieter than a warn. `level == "warn"` is an
  # equality test wearing a threshold's clothes, so `error` printed only under
  # -v — and a typo'd `warning` vanished entirely. Both fail in the direction
  # of losing the more important message.
  def test_nothing_is_quieter_than_a_warn
    %w[warn error critical fatal warning].each do |level|
      body = <<~SCRIPT
        STDIN.gets
        puts({event: 'log', level: '#{level}', msg: 'the parser is gone'}.to_json)
        puts({event: 'done', count: 0}.to_json)
      SCRIPT
      with_python_cmd(body) do
        _, err = capture_io_streams { worker.search('q') }
        assert_includes err, "[worker:#{level}] the parser is gone"
      end
    end
  end

  # A half-written line is what a worker killed mid-`emit` leaves behind, which
  # makes it the highest-information moment on the channel — and it was gated
  # behind -v, a flag you can only set on the run before the one that failed.
  # The channel breaking is not a log level the worker chose, so verbosity has
  # no business being able to turn it off.
  def test_a_half_written_event_is_reported_without_verbose
    body = <<~SCRIPT
      STDIN.gets
      print '{"event":"order","data":{"id"'
      STDOUT.flush
      exit 1
    SCRIPT
    with_python_cmd(body) do
      _, err = capture_io_streams do
        assert_raises(Amazon::Worker::Error) { worker.search('q') }
      end
      assert_includes err, 'non-JSON output: {"event":"order","data":{"id"'
    end
  end

  # By the time the run ends, the broken line has scrolled past everything the
  # worker printed on its way down, and a bare "exited 1" reads as a failure
  # the worker chose and described. It didn't: we lost events.
  def test_a_run_that_lost_events_says_so_at_exit
    body = <<~SCRIPT
      STDIN.gets
      print '{"event":"order","data":{"id"'
      STDOUT.flush
      exit 1
    SCRIPT
    with_python_cmd(body) do
      err = nil
      capture_io_streams do
        err = assert_raises(Amazon::Worker::Error) { worker.search('q') }
      end
      assert_includes err.message, 'exited 1'
      assert_includes err.message, '1 unparseable line on the event channel'
    end
  end

  # Reporting the break must not become the failure: the truncated head of a
  # very large event is exactly the shape this prints.
  def test_a_vast_junk_line_is_reported_in_bounded_form
    body = <<~SCRIPT
      STDIN.gets
      puts '{' + ('x' * 100_000)
      puts({event: 'done', count: 0}.to_json)
    SCRIPT
    with_python_cmd(body) do
      _, err = capture_io_streams { assert_empty worker.search('q') }
      assert_includes err, '100001 chars'
      assert_operator err.length, :<, 500
    end
  end

  # Every other line this class writes is tagged — `[worker:warn]`, `[worker]
  # non-JSON output:`, Progress's `year …`. Raw subprocess output was the one
  # unlabelled stream, and under -v during a sync it interleaves with the
  # progress bar: paste that into an issue and nobody can tell which half is
  # the CLI and which is Python.
  def test_forwarded_worker_stderr_says_where_it_came_from
    body = <<~SCRIPT
      STDIN.gets
      STDERR.puts 'Traceback (most recent call last):'
      STDERR.flush
      puts({event: 'done', count: 0}.to_json)
    SCRIPT
    with_python_cmd(body) do
      _, err = capture_io_streams { assert_empty worker(verbose: true).search('q') }
      assert_includes err, '[worker:stderr] Traceback (most recent call last):'
    end
  end

  # `Thread#join` re-raises into the main thread, and it did so *before* the
  # exit-status check — so a failure while writing the diagnostics down
  # replaced the failure they described, and pointed the caller at the logging
  # path instead of at the worker. The forwarding channel must never preempt
  # the thing it forwards.
  def test_a_broken_reader_thread_does_not_replace_the_workers_own_error
    body = <<~SCRIPT
      STDIN.gets
      STDERR.puts 'the real diagnostics'
      STDERR.flush
      exit 2
    SCRIPT
    with_python_cmd(body) do
      w = worker
      w.define_singleton_method(:forward_stderr) { |*| raise Errno::EIO, 'the pipe went away' }
      raised = nil
      _, err = capture_io_streams do
        raised = assert_raises(Amazon::Worker::Error) { w.search('q') }
      end
      assert_includes raised.message, 'exited 2'
      assert_includes err, "forwarding the worker's stderr failed"
    end
  end

  # `fetch.py` captures a full traceback on its error paths and puts it on the
  # event as `trace`. Nothing read it — `sync` takes `msg`, `live_error` takes
  # `kind` and `msg` — so the stack naming which parser broke was serialized,
  # piped, parsed and dropped, at every verbosity: -v wasn't even an escape
  # hatch. A diagnostic that exists but cannot be reached is worse than none,
  # because the next person to debug this assumes it was never captured.
  def test_an_error_events_traceback_is_not_thrown_away
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'error',
            msg: "history fetch failed for 2024: 'NoneType' object has no attribute 'text'",
            trace: "Traceback (most recent call last):\\n  File \\"orders.py\\", line 91\\nAttributeError"}.to_json)
    SCRIPT
    with_python_cmd(body) do
      _, err = capture_io_streams do
        assert_raises(Amazon::Worker::Error) { worker.search('q') }
      end
      assert_includes err, '[worker:trace] Traceback (most recent call last):'
      assert_includes err, '[worker:trace]   File "orders.py", line 91'
    end
  end

  # Progress only redraws on a terminal, so this is the one place the suite
  # needs stderr to claim it is one.
  class FakeTty < StringIO
    def tty? = true
  end

  def with_tty_stderr
    old = $stderr
    $stderr = FakeTty.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end

  # `progress.clear` ran before anything knew whether the log event would print
  # anything. `fetch.py` emits info logs throughout the detail loop, so without
  # -v the bar was erased and redrawn with nothing in between: flicker for no
  # reason. The visibility decision moved into `log_event` and the side effect
  # that depends on it stayed outside.
  def test_a_log_that_prints_nothing_does_not_erase_the_progress_bar
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'total', year: 2026, listed: 2, new: 2, cached: 0}.to_json)
      puts({event: 'progress', year: 2026, i: 1, n: 2, order_id: 'ORD-A'}.to_json)
      puts({event: 'log', level: 'info', msg: 'routine'}.to_json)
      puts({event: 'progress', year: 2026, i: 2, n: 2, order_id: 'ORD-B'}.to_json)
      puts({event: 'done', count: 2, skipped: 0}.to_json)
    SCRIPT
    ENV['COLUMNS'] = '200'
    with_python_cmd(body) do
      out = with_tty_stderr { worker.sync(email: 'e', password: 'p', years: [2026]) }
      between = out[out.index('ORD-A')...out.index('ORD-B')]
      # One, and only one: the erase that belongs to the second bar's own
      # redraw. A second one is the invisible message erasing the first bar.
      assert_equal 1, between.scan("\e[2K").size, between.inspect
    end
  ensure
    ENV.delete('COLUMNS')
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

  # An unknown ASIN used to come back as a bare RuntimeError, which meant the
  # traceback went to stderr and the CLI stapled its last seven lines under a
  # "live lookup failed" prefix. What the user typed was a bad ASIN; what they
  # read was a Python stack ending in `raise RuntimeError` inside scrape_item.
  def test_a_missing_product_reads_as_a_bad_asin_not_a_crash
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'error', msg: 'no product page for B0DEMO1234 — check the ASIN', kind: 'no_product'}.to_json)
    SCRIPT
    with_python_cmd(body) do
      err = assert_raises(Amazon::Worker::Error) { worker.item('B0DEMO1234') }
      assert_equal 'no product page for B0DEMO1234 — check the ASIN', err.message
      refute_includes err.message, 'live lookup failed'
      refute_includes err.message, 'worker stderr'
    end
  end

  def test_a_missing_product_does_not_drag_the_stderr_tail_along
    # The other half of the same complaint. The tail is diagnostics for a bug
    # in us; here the worker's own message is the whole diagnosis, and the
    # traceback that used to fill this space was noise around it.
    body = <<~SCRIPT
      STDIN.gets
      warn 'Traceback (most recent call last):'
      warn '  File "live.py", line 595, in scrape_item'
      puts({event: 'error', msg: 'no product page for B0DEMO1234 — check the ASIN', kind: 'no_product'}.to_json)
    SCRIPT
    with_python_cmd(body) do
      err = nil
      capture_io_streams { err = assert_raises(Amazon::Worker::Error) { worker.item('B0DEMO1234') } }
      # The tail still attaches when the worker wrote one — that behaviour is
      # unchanged and load-bearing for real crashes. What changed is upstream:
      # live.py raises NoProduct, which `main` routes past the handler that
      # prints the traceback, so on the real path there is no tail to attach.
      # See ScrapeItemMissingProductTest in the Python suite.
      assert_includes err.message, 'no product page for B0DEMO1234'
      refute_includes err.message, 'live lookup failed'
    end
  end

  def test_non_json_lines_are_skipped_and_always_logged
    body = <<~SCRIPT
      STDIN.gets
      puts 'this is not json'
      puts({event: 'done', count: 0}.to_json)
    SCRIPT
    with_python_cmd(body) do
      _, err = capture_io_streams { assert_empty worker(verbose: true).search('q') }
      assert_includes err, 'non-JSON output'

      _, err = capture_io_streams { assert_empty worker.search('q') }
      assert_includes err, 'non-JSON output'
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

# The worker's stderr is where a Python traceback lands, and a traceback is the
# only thing that says *where* a crash happened. Gating it behind -v meant the
# person diagnosing a failure was the one person guaranteed not to see it: the
# run they need it for is the run that already happened.
class WorkerStderrTest < Minitest::Test
  def worker(**kw) = Amazon::Worker.new(**kw)

  def test_a_bare_non_zero_exit_reports_what_the_worker_said_on_stderr
    body = <<~SCRIPT
      STDIN.gets
      warn 'Traceback (most recent call last):'
      warn '  File "live.py", line 512, in scrape_item'
      warn "AttributeError: 'NoneType' object has no attribute 'count'"
      exit 1
    SCRIPT
    with_python_cmd(body) do
      err = assert_raises(Amazon::Worker::Error) { worker.item('B1') }
      assert_includes err.message, 'exited 1'
      assert_includes err.message, 'line 512, in scrape_item'
      assert_includes err.message, 'AttributeError'
    end
  end

  def test_an_error_event_keeps_the_traceback_that_explains_it
    # `emit("error", msg=f"{type(e).__name__}: {e}")` names the exception and
    # nothing else; live.py prints the traceback to stderr on the very next
    # line. Reporting one without the other is how "AttributeError: 'NoneType'
    # object has no attribute 'count'" became the whole bug report.
    body = <<~SCRIPT
      STDIN.gets
      warn '  File "live.py", line 512, in scrape_item'
      puts({event: 'error', msg: "AttributeError: 'NoneType' object has no attribute 'count'"}.to_json)
      STDOUT.flush
      exit 1
    SCRIPT
    with_python_cmd(body) do
      err = assert_raises(Amazon::Worker::Error) { worker.item('B1') }
      assert_includes err.message, 'AttributeError'
      assert_includes err.message, 'line 512, in scrape_item'
    end
  end

  # The counterpart: an expired session is not a crash, and a message telling
  # someone to run `amazon login` must not arrive wrapped in worker chatter.
  def test_a_clean_error_message_is_not_padded_with_an_empty_stderr
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'error', msg: 'no saved session — run: amazon login', kind: 'not_logged_in'}.to_json)
      STDOUT.flush
      exit 1
    SCRIPT
    with_python_cmd(body) do
      err = assert_raises(Amazon::Worker::Error) { worker.item('B1') }
      assert_equal 'no saved session — run: amazon login', err.message
    end
  end

  # Playwright can write megabytes before it falls over. Reporting a crash must
  # not itself become the failure.
  def test_only_the_tail_of_a_torrential_stderr_is_kept
    body = <<~SCRIPT
      STDIN.gets
      3_000.times { |i| warn "chatter \#{i}" }
      warn 'the actual traceback'
      exit 1
    SCRIPT
    with_python_cmd(body) do
      err = assert_raises(Amazon::Worker::Error) { worker.item('B1') }
      assert_includes err.message, 'the actual traceback'
      refute_includes err.message, 'chatter 0'
      assert_operator err.message.lines.size, :<=, Amazon::Worker::STDERR_TAIL_LINES + 3
    end
  end

  def test_verbose_mode_still_streams_stderr_as_it_arrives
    body = <<~SCRIPT
      STDIN.gets
      warn 'browser launched'
      puts({event: 'done', count: 0}.to_json)
    SCRIPT
    with_python_cmd(body) do
      _, err = capture_io_streams { worker(verbose: true).search('q') }
      assert_includes err, 'browser launched'
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
    # Captured because the junk line now prints unconditionally, and a test
    # that scribbles on the real stderr reads as a failure in the suite.
    capture_io_streams { assert_nil w.send(:parse_event, 'not json') }
    assert_equal({ 'event' => 'done' }, w.send(:parse_event, '{"event":"done"}'))
  end

  def test_live_error_formats_by_kind
    w = Amazon::Worker.new
    assert_equal 'x', w.send(:live_error, 'kind' => 'not_logged_in', 'msg' => 'x')
    assert_equal 'x', w.send(:live_error, 'kind' => 'blocked', 'msg' => 'x')
    # A mistyped ASIN is a user error, not a crash in us. It used to arrive as a
    # bare RuntimeError, so it got the "live lookup failed" prefix, a traceback
    # on stderr, and the last seven stderr lines stapled underneath — five lines
    # of Python internals for a typo whose answer is the sentence itself.
    assert_equal 'x', w.send(:live_error, 'kind' => 'no_product', 'msg' => 'x')
    assert_equal 'live lookup failed: x', w.send(:live_error, 'msg' => 'x')
  end

  def test_an_unknown_kind_still_gets_the_prefix
    # The prefix is the tell that we did not anticipate this failure. A new
    # kind added on the Python side without a matching entry here must keep it
    # rather than pass an unvetted message off as advice.
    w = Amazon::Worker.new
    assert_equal 'live lookup failed: x', w.send(:live_error, 'kind' => 'brand_new', 'msg' => 'x')
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
      p.start('year' => 2025, 'listed' => 6, 'new' => 2, 'cached' => 4)
      p.tick('i' => 1, 'n' => 2, 'date' => '2025-01-01', 'grand_total' => 12.5,
             'order_id' => '111-1', 'title' => 'Widget')
      p.finish('count' => 2, 'skipped' => 4)
    end
    assert_includes err, 'year 2025: 6 orders (2 new, 4 already stored)'
    assert_includes err, '$12.50'
    assert_includes err, '111-1'
    assert_includes err, 'done: 2 orders (4 already stored)'
  end

  # The bug Eric hit: 206 orders listed for 2026, all already on disk, reported
  # as "year 2026: 0 orders" on an account holding 222 of them — the same
  # sentence a year Amazon lists nothing for produces. Both lines are asserted
  # in one test and compared, because the defect was never in either string on
  # its own; it was that the two were equal.
  def test_a_fully_cached_year_does_not_read_like_an_empty_one
    _, cached_err = capture_io_streams do
      progress.start('year' => 2026, 'listed' => 206, 'new' => 0, 'cached' => 206)
    end
    _, empty_err = capture_io_streams do
      progress.start('year' => 2006, 'listed' => 0, 'new' => 0, 'cached' => 0)
    end
    assert_includes cached_err, 'year 2026: 206 orders, all already stored'
    assert_includes empty_err, 'year 2006: Amazon listed no orders'
    refute_equal cached_err.sub('2026', 'Y'), empty_err.sub('2006', 'Y')
  end

  def test_done_distinguishes_nothing_new_from_nothing_found
    _, nothing_new = capture_io_streams { progress.finish('count' => 0, 'skipped' => 206) }
    _, nothing_found = capture_io_streams { progress.finish('count' => 0, 'skipped' => 0) }
    assert_includes nothing_new, 'done: no new orders (206 already stored)'
    assert_includes nothing_found, 'done: no orders found'
    refute_equal nothing_new, nothing_found
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
      puts({event: 'total', year: 2025, listed: 2, new: 2, cached: 0}.to_json)
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
      assert_includes err, 'year 2025: 2 orders (2 new, 0 already stored)'
      assert_includes err, 'done: 2 orders (1 already stored)'
    end
  end

  # The sync log records what was written, which is zero on a healthy run over
  # an up-to-date archive. These are what let the line say which zero it was.
  def test_sync_totals_accumulate_across_years
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'total', year: 2025, listed: 10, new: 1, cached: 9}.to_json)
      puts({event: 'total', year: 2026, listed: 206, new: 0, cached: 206}.to_json)
      puts({event: 'done', count: 1, skipped: 215}.to_json)
    SCRIPT
    with_python_cmd(body) do
      w = Amazon::Worker.new(quiet: true)
      capture_io_streams { w.sync(**sync_args) }
      assert_equal 216, w.listed_count
      assert_equal 215, w.known_count
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

  # sync.rb is filtered out of the coverage gate, so nothing here is graded and
  # this line went years without a test. It is also the *persistent* record — a
  # console line is gone when the terminal scrolls, but `count=0` sat in the log
  # for months meaning two opposite things on different days.
  def sync_log_line(count, **kw)
    Amazon::Commands::Order::Sync
      .new(Amazon::GlobalOptions.new(json: false, quiet: true, verbose: false))
      .send(:append_sync_log, [2026], count, **kw)
    File.readlines(Amazon::Config.sync_log_path).last
  end

  def test_the_sync_log_separates_nothing_new_from_nothing_listed
    up_to_date = sync_log_line(0, listed: 206, known: 206)
    empty = sync_log_line(0, listed: 0, known: 0)
    assert_includes up_to_date, 'count=0  listed=206  known=206'
    assert_includes empty, 'count=0  listed=0  known=0'
    refute_equal up_to_date.split(nil, 2).last, empty.split(nil, 2).last
  end

  def test_the_sync_log_still_marks_partial_runs
    line = sync_log_line(3, listed: 10, known: 7, partial: "boom\nsecond line")
    assert_includes line, 'count=3  listed=10  known=7'
    assert_includes line, 'status=partial  error=boom second line'
  end
end

# --- Review analysis ---------------------------------------------------

# A unique all-alphabetic token per index. Digits can't be used: they break
# clauses and fall out of the word scanner, so "body 7" and "body 8" would
# reduce to the same content words and read as duplicates.
def tag(i) = "zz#{i.to_s.tr('0123456789', 'abcdefghij')}"

# Builds review samples for the heuristics. Defaults describe a plausibly
# honest review — distinct wording, verified, spread over the year — and each
# test perturbs only the field it is about.
def review(i, **over)
  {
    'id' => "R#{i}", 'rating' => 5.0, 'verified' => true, 'vine' => false,
    'author' => "Buyer #{i}", 'date' => "2025-#{format('%02d', 1 + (i % 12))}-14",
    'title' => "Review #{tag(i)}",
    'body' => "Spool #{tag(i)} #{tag(i + 100)} #{tag(i + 200)} #{tag(i + 300)} " \
              'arrived and printed cleanly overall.'
  }.merge(over)
end

def sample(n, **over) = (1..n).map { |i| review(i, **over) }

def analyze(reviews:, title: 'PLA Filament Spool 1.75mm Extruder Safe', **over)
  Amazon::Reviews.analyze({ 'title' => title, 'reviews_sample' => reviews }.merge(over))
end

def signal(result, key) = result['signals'].find { |s| s['key'] == key }

class ReviewsHistogramSignalTest < Minitest::Test
  def points(hist)
    signal(analyze(reviews: [], 'histogram' => hist), 'histogram')
  end

  def test_normal_j_curve_scores_zero
    s = points('5' => 58, '4' => 19, '3' => 9, '2' => 5, '1' => 9)
    assert_equal 0, s['points']
    assert_includes s['detail'], 'normal spread'
  end

  def test_five_star_wall_with_no_middle_scores_full
    s = points('5' => 96, '4' => 2, '3' => 1, '2' => 0, '1' => 1)
    assert_equal 20, s['points']
    assert_includes s['detail'], 'fatter middle'
  end

  def test_real_listings_score_zero
    # Measured off four unrelated, apparently legitimate products, one of them
    # a 30k-rating Anker charger. ~80% five-star with a mid-teens middle is the
    # Amazon baseline for consumer goods; scoring it would fire on everything
    # and teach the reader to ignore the report.
    [['5' => 79, '4' => 12, '3' => 5, '2' => 1, '1' => 3],
     ['5' => 81, '4' => 9, '3' => 4, '2' => 2, '1' => 4],
     ['5' => 80, '4' => 11, '3' => 4, '2' => 2, '1' => 3],
     ['5' => 83, '4' => 9, '3' => 3, '2' => 1, '1' => 4]].each do |(hist)|
      assert_equal 0, points(hist)['points'], hist.inspect
    end
  end

  def test_intermediate_bands
    assert_equal 16, points('5' => 92, '4' => 5, '3' => 2, '2' => 0, '1' => 1)['points']
    # A baseline five-star share can still be flagged by an implausibly thin
    # middle on its own -- but only weakly, since it is one tell rather than two.
    assert_equal 4, points('5' => 84, '4' => 4, '3' => 1, '2' => 0, '1' => 11)['points']
  end

  def test_a_missing_one_star_tail_is_itself_a_tell
    # Same five-star share and middle, only the tail differs: a product this
    # popular still collects duds, and a farm has no reason to buy them.
    with_tail = points('5' => 88, '4' => 6, '3' => 3, '2' => 0, '1' => 3)['points']
    without = points('5' => 88, '4' => 6, '3' => 3, '2' => 2, '1' => 1)['points']
    assert_equal 0, with_tail
    assert_equal 5, without
  end

  def test_missing_histogram_is_not_computable_rather_than_clean
    # The distinction matters: a signal scored 0 says "checked, looks fine";
    # nil says "couldn't check", and only nil leaves the denominator.
    s = points(nil)
    assert_nil s['points']
    assert_includes s['detail'], "didn't render"
    assert_nil points({})['points']
  end

  def test_junk_keys_and_values_are_discarded
    assert_nil points('rating' => 'lots', '9' => 50)['points']
  end

  def test_string_percentages_are_accepted
    # The worker emits ints, but a hand-edited cache entry or a JSON round trip
    # through the web UI can hand us strings.
    assert_equal 20, points('5' => '96', '4' => '2', '3' => '1', '2' => '0', '1' => '1')['points']
  end

  def test_a_partial_histogram_is_not_computable_rather_than_damning
    # Rows lost to selector drift used to read as 0%, so a listing whose 5★ row
    # was the only survivor scored as a five-star wall with no middle and no
    # tail -- the tool manufacturing the exact shape it exists to detect. The
    # healthy real listing below scores 0 intact; every truncation of it must
    # abstain rather than climb.
    assert_equal 0, points('5' => 79, '4' => 10, '3' => 5, '2' => 2, '1' => 4)['points']
    assert_nil points('5' => 79)['points']
    assert_nil points('5' => 96)['points']
    assert_nil points('5' => 79, '4' => 10, '3' => 5)['points']
    assert_includes points('5' => 96)['detail'], "didn't render"
  end

  def test_percentages_that_do_not_add_up_are_rejected
    # All five rows present and summing to 40 means some of them were misread.
    # Scoring that is scoring noise.
    assert_nil points('5' => 20, '4' => 8, '3' => 5, '2' => 4, '1' => 3)['points']
    assert_nil points('5' => 96, '4' => 40, '3' => 30, '2' => 20, '1' => 10)['points']
  end

  def test_rounding_slack_is_not_mistaken_for_a_partial_read
    # Amazon rounds every row to a whole percent, so a real histogram routinely
    # lands a point or two either side of 100.
    assert_equal 0, points('5' => 79, '4' => 12, '3' => 5, '2' => 1, '1' => 4)['points']
    assert_equal 0, points('5' => 78, '4' => 12, '3' => 5, '2' => 1, '1' => 3)['points']
  end
end

class ReviewsUnverifiedSignalTest < Minitest::Test
  def test_all_verified_scores_zero
    s = signal(analyze(reviews: sample(10)), 'unverified')
    assert_equal 0, s['points']
    assert_includes s['detail'], 'all 10 sampled reviews are verified'
  end

  def test_mostly_unverified_scores_high
    reviews = sample(10).each_with_index.map { |r, i| r.merge('verified' => i < 2) }
    s = signal(analyze(reviews: reviews), 'unverified')
    assert_equal 20, s['points']
    assert_includes s['detail'], '8/10'
  end

  def test_a_sample_with_no_verified_badge_anywhere_is_read_as_rot_not_fraud
    # Amazon renames data hooks routinely, and a renamed badge looks exactly
    # like a review farm: every card probes clean, so every review reads
    # unverified. Across a sample this size the renaming is far likelier, and
    # accusing the listing on the strength of a selector we can't confirm is
    # the failure mode this whole module is built to avoid.
    reviews = sample(30).map { |r| r.merge('verified' => false) }
    s = signal(analyze(reviews: reviews), 'unverified')
    assert_nil s['points']
    assert_includes s['detail'], 'badge'
    refute_includes s['detail'], '30/30'
  end

  def test_a_single_verified_review_proves_the_badge_still_reads
    # ...and the signal goes back to work, at full strength.
    reviews = sample(30).each_with_index.map { |r, i| r.merge('verified' => i.zero?) }
    s = signal(analyze(reviews: reviews), 'unverified')
    assert_equal 20, s['points']
    assert_includes s['detail'], '29/30'
  end

  def test_a_small_all_unverified_sample_still_scores
    # The rot reading only becomes the likelier one across a real population.
    # A handful of unverified reviews is ordinary and must still count.
    reviews = sample(8).map { |r| r.merge('verified' => false) }
    assert_equal 20, signal(analyze(reviews: reviews), 'unverified')['points']
  end

  def test_reviews_whose_badge_could_not_be_read_leave_the_denominator
    # nil is "the probe never completed", which is not evidence either way.
    # Counting it as unverified turned a detached card into an accusation.
    reviews = sample(10).each_with_index.map { |r, i| i < 5 ? r.merge('verified' => nil) : r }
    s = signal(analyze(reviews: reviews), 'unverified')
    assert_equal 0, s['points']
    assert_includes s['detail'], 'all 5 sampled reviews are verified'
  end

  def test_a_sample_read_thin_by_unknowns_is_not_computable
    # Seven of ten unreadable leaves three to judge on — below the floor the
    # signal already refuses to work under.
    reviews = sample(10).each_with_index.map { |r, i| i < 7 ? r.merge('verified' => nil) : r }
    assert_nil signal(analyze(reviews: reviews), 'unverified')['points']
  end

  def test_glowing_unverified_reviews_are_called_out
    reviews = sample(10).each_with_index.map { |r, i| r.merge('verified' => i < 5) }
    assert_includes signal(analyze(reviews: reviews), 'unverified')['detail'], '5 of them 4★ or better'
  end

  def test_unverified_low_star_reviews_omit_the_glowing_note
    reviews = sample(10).each_with_index.map { |r, i| r.merge('verified' => i < 5, 'rating' => 1.0) }
    refute_includes signal(analyze(reviews: reviews), 'unverified')['detail'], 'or better'
  end

  def test_thin_sample_is_not_computable
    s = signal(analyze(reviews: sample(3)), 'unverified')
    assert_nil s['points']
    assert_includes s['detail'], '5+ reviews'
  end
end

class ReviewsBurstSignalTest < Minitest::Test
  def test_needs_a_deep_sample_and_says_how_to_get_one
    s = signal(analyze(reviews: sample(8)), 'burst')
    assert_nil s['points']
    assert_includes s['detail'], '--pages 3'
  end

  def test_tight_cluster_scores_full
    reviews = (1..20).map { |i| review(i, 'date' => '2026-03-0%d' % (1 + (i % 3))) }
    s = signal(analyze(reviews: reviews), 'burst')
    assert_equal 20, s['points']
    assert_includes s['detail'], '(100%)'
  end

  def test_spread_out_reviews_score_zero
    reviews = (1..20).map { |i| review(i, 'date' => "2025-#{format('%02d', 1 + (i % 12))}-0#{1 + (i % 8)}") }
    assert_equal 0, signal(analyze(reviews: reviews), 'burst')['points']
  end

  def test_undated_reviews_do_not_count_toward_the_sample
    reviews = (1..20).map { |i| review(i, 'date' => nil) }
    assert_nil signal(analyze(reviews: reviews), 'burst')['points']
  end

  def test_malformed_dates_are_ignored_not_fatal
    reviews = (1..20).map { |i| review(i, 'date' => 'last Tuesday') }
    assert_nil signal(analyze(reviews: reviews), 'burst')['points']
  end

  def test_a_recency_sorted_sample_cannot_be_judged_on_timing
    # Asking Amazon for the newest reviews and then flagging the sample for
    # being new is circular: --sort recent clusters the dates by construction,
    # so a healthy product with 20 reviews this week scores a full 20/20 for
    # doing nothing but selling well.
    reviews = (1..20).map { |i| review(i, 'date' => '2026-03-0%d' % (1 + (i % 3))) }
    s = signal(analyze(reviews: reviews, 'reviews_sort' => 'recent'), 'burst')
    assert_nil s['points']
    assert_includes s['detail'], 'recent'
  end

  def test_the_default_sort_still_judges_timing
    reviews = (1..20).map { |i| review(i, 'date' => '2026-03-0%d' % (1 + (i % 3))) }
    assert_equal 20, signal(analyze(reviews: reviews, 'reviews_sort' => 'helpful'), 'burst')['points']
  end
end

class ReviewsDuplicateSignalTest < Minitest::Test
  TEMPLATE = 'These earbuds sound amazing and the battery life is excellent overall.'.freeze

  def test_distinct_bodies_score_zero
    s = signal(analyze(reviews: sample(8)), 'duplicates')
    assert_equal 0, s['points']
    assert_includes s['detail'], 'no near-duplicate phrasing'
  end

  def test_templated_bodies_score_full
    s = signal(analyze(reviews: sample(8, 'body' => TEMPLATE)), 'duplicates')
    assert_equal 15, s['points']
    assert_includes s['detail'], 'overlapping wording'
  end

  def test_short_bodies_are_not_comparable
    s = signal(analyze(reviews: sample(8, 'body' => 'Good.')), 'duplicates')
    assert_nil s['points']
    assert_includes s['detail'], 'substantial text'
  end

  def test_partial_duplication_scores_partially
    reviews = sample(8).each_with_index.map { |r, i| i < 2 ? r.merge('body' => TEMPLATE) : r }
    points = signal(analyze(reviews: reviews), 'duplicates')['points']
    assert_operator points, :>, 0
    assert_operator points, :<, 15
  end
end

class ReviewsIncentivizedSignalTest < Minitest::Test
  DISCLOSURE = 'I received this product for free in exchange for my honest review of the spool.'.freeze

  def test_clean_sample_scores_zero
    assert_equal 0, signal(analyze(reviews: sample(10)), 'incentivized')['points']
  end

  def test_disclosures_score
    reviews = sample(10).each_with_index.map { |r, i| i < 3 ? r.merge('body' => DISCLOSURE) : r }
    s = signal(analyze(reviews: reviews), 'incentivized')
    assert_equal 10, s['points']
    assert_includes s['detail'], '3/10'
  end

  def test_vine_reviews_are_excluded_from_the_penalty
    # Vine is Amazon's own disclosed programme; penalising it would flag honest
    # listings for participating in something Amazon runs.
    reviews = sample(10).map { |r| r.merge('body' => DISCLOSURE, 'vine' => true) }
    assert_equal 0, signal(analyze(reviews: reviews), 'incentivized')['points']
  end

  def test_phrasing_variants
    %w[
      at\ a\ discounted\ price
      in\ return\ for\ my\ honest\ opinion
      got\ this\ item\ free\ of\ no\ cost
    ].each do |phrase|
      reviews = sample(10).map { |r| r.merge('body' => "Nice spool, #{phrase.tr('\\', ' ')}.") }
      assert_operator signal(analyze(reviews: reviews), 'incentivized')['points'], :>, 0, phrase
    end
  end

  def test_thin_sample_is_not_computable
    assert_nil signal(analyze(reviews: sample(2)), 'incentivized')['points']
  end
end

class ReviewsMismatchSignalTest < Minitest::Test
  def test_occasional_echoes_of_the_title_keep_it_quiet
    # The realistic false positive this guards against: most honest reviewers
    # never repeat a keyword-stuffed title back, so only a *total* absence over
    # a deep sample counts as evidence.
    reviews = (1..30).map do |i|
      body = i % 5 == 0 ? "The loppers held up through a full season #{tag(i)}." : "Held up nicely #{tag(i)}."
      review(i, 'title' => "Fine #{tag(i)}", 'body' => body)
    end
    s = signal(analyze(reviews: reviews, title: 'Heavy Duty Garden Loppers Steel Blade'), 'mismatch')
    assert_equal 0, s['points']
    assert_includes s['detail'], 'mention something from the product title'
  end

  def test_total_mismatch_across_a_deep_sample_scores
    reviews = (1..30).map { |i| review(i, 'title' => 'Nice', 'body' => "Lovely scented candle #{tag(i)}.") }
    s = signal(analyze(reviews: reviews, title: 'Cordless Impact Driver Brushless Kit'), 'mismatch')
    assert_equal 8, s['points']
    assert_includes s['detail'], 'merged listing'
  end

  def test_shallow_sample_is_not_computable
    s = signal(analyze(reviews: sample(12)), 'mismatch')
    assert_nil s['points']
    assert_includes s['detail'], '--pages 3'
  end

  def test_a_title_with_no_content_words_is_not_computable
    assert_nil signal(analyze(reviews: sample(30), title: 'A B'), 'mismatch')['points']
  end

  def test_reviews_without_text_are_excluded_from_the_denominator
    assert_nil signal(analyze(reviews: sample(30, 'body' => '', 'title' => '')), 'mismatch')['points']
  end
end

class ReviewsRepeatReviewerSignalTest < Minitest::Test
  def test_distinct_names_score_zero
    s = signal(analyze(reviews: sample(10)), 'repeat_reviewers')
    assert_equal 0, s['points']
    assert_includes s['detail'], '10 distinct reviewer names'
  end

  def test_repeated_names_score
    s = signal(analyze(reviews: sample(10, 'author' => 'Same Person')), 'repeat_reviewers')
    assert_equal 5, s['points']
    assert_includes s['detail'], 'more than once'
  end

  def test_names_are_matched_case_and_space_insensitively
    reviews = sample(10).each_with_index.map { |r, i| r.merge('author' => i.even? ? ' Ann ' : 'ANN') }
    assert_equal 5, signal(analyze(reviews: reviews), 'repeat_reviewers')['points']
  end

  def test_anonymous_reviews_are_not_computable
    assert_nil signal(analyze(reviews: sample(10, 'author' => nil)), 'repeat_reviewers')['points']
    assert_nil signal(analyze(reviews: sample(10, 'author' => '  ')), 'repeat_reviewers')['points']
  end
end

class ReviewsScoringTest < Minitest::Test
  def test_a_clean_listing_scores_low
    result = analyze(reviews: sample(10), 'histogram' => { '5' => 58, '4' => 19, '3' => 9, '2' => 5, '1' => 9 })
    assert_equal 0, result['score']
    assert_equal 'low', result['level']
  end

  def test_a_farmed_listing_scores_high
    reviews = (1..20).map do |i|
      review(i, 'verified' => false, 'author' => 'Bot', 'date' => '2026-03-02',
                'body' => 'These earbuds sound amazing and the battery life is excellent overall.')
    end
    result = analyze(reviews: reviews, 'histogram' => { '5' => 96, '4' => 2, '3' => 0, '2' => 0, '1' => 2 })
    assert_equal 'high', result['level']
    assert_operator result['score'], :>, 75
  end

  def test_uncomputable_signals_leave_the_denominator_rather_than_scoring_zero
    # Two reviews can't support any per-review check. If those checks counted as
    # passes, a listing nobody can assess would look spotless — the single most
    # dangerous way for this to be wrong.
    result = analyze(reviews: sample(2), 'histogram' => { '5' => 96, '4' => 2, '3' => 0, '2' => 0, '1' => 2 })
    assert_equal 100, result['score']
    assert_equal 'high', result['level']
    assert_equal 'low', result['confidence']
  end

  def test_no_computable_signals_at_all_yields_no_score
    result = analyze(reviews: [])
    assert_nil result['score']
    assert_equal 'unknown', result['level']
    assert_equal 'none', result['confidence']
  end

  def test_level_bands
    assert_equal 'low', Amazon::Reviews.level_for(19)
    assert_equal 'some', Amazon::Reviews.level_for(20)
    assert_equal 'elevated', Amazon::Reviews.level_for(40)
    assert_equal 'high', Amazon::Reviews.level_for(65)
    assert_equal 'unknown', Amazon::Reviews.level_for(nil)
  end

  def test_confidence_rises_with_sample_depth
    deep = (1..45).map { |i| review(i, 'date' => "2025-#{format('%02d', 1 + (i % 12))}-0#{1 + (i % 8)}") }
    result = analyze(reviews: deep, 'histogram' => { '5' => 58, '4' => 19, '3' => 9, '2' => 5, '1' => 9 })
    assert_equal 'high', result['confidence']

    mid = (1..20).map { |i| review(i, 'date' => "2025-#{format('%02d', 1 + (i % 12))}-0#{1 + (i % 8)}") }
    assert_equal 'medium', analyze(reviews: mid,
                                   'histogram' => { '5' => 58, '4' => 19, '3' => 9, '2' => 5, '1' => 9 })['confidence']
  end

  # Observed on a real 3,706-rating listing: `--pages 3` stopped yielding new
  # reviews after page 1, and the report answered by advising `--pages 3`.
  def test_a_thin_sample_advises_going_deeper
    detail = analyze(reviews: sample(3))['signals']
                 .find { |s| s['key'] == 'burst' }['detail']
    assert_includes detail, 're-run with --pages 3'
  end

  def test_it_stops_advising_a_deeper_walk_once_amazon_has_refused_one
    detail = analyze(reviews: sample(3), 'reviews_walk' => 'exhausted')['signals']
                 .find { |s| s['key'] == 'burst' }['detail']
    refute_includes detail, 're-run with --pages'
    assert_includes detail, 'Amazon served no more for this session'
  end

  def test_the_mismatch_signal_takes_the_same_advice
    detail = analyze(reviews: sample(3), 'reviews_walk' => 'exhausted')['signals']
                 .find { |s| s['key'] == 'mismatch' }['detail']
    assert_includes detail, 'Amazon served no more for this session'
  end

  def hint(**over) = analyze(reviews: sample(3), **over)['signals'].find { |s| s['key'] == 'burst' }['detail']

  def test_a_walk_that_failed_says_so_rather_than_claiming_amazon_is_out
    # "That is everything Amazon would serve" after a timeout is a claim the
    # run has no basis for, and it suppresses the one useful instruction:
    # try again. The old boolean could not tell the two apart.
    detail = hint('reviews_walk' => 'failed')
    refute_includes detail, 'Amazon served no more'
    assert_includes detail, 'retry'
  end

  def test_a_complete_walk_suggests_a_depth_greater_than_the_one_already_run
    # The original complaint, in its surviving form: a full `--pages 3` still
    # advised `--pages 3`, because only an early stop was tracked.
    assert_includes hint('reviews_walk' => 'complete', 'review_pages' => 0), '--pages 3'
    assert_includes hint('reviews_walk' => 'complete', 'review_pages' => 3), '--pages 6'
    assert_includes hint('reviews_walk' => 'complete', 'review_pages' => 8), '--pages 10'
  end

  def test_at_the_maximum_depth_there_is_no_deeper_to_advise
    detail = hint('reviews_walk' => 'complete', 'review_pages' => 10)
    refute_includes detail, '--pages'
    assert_includes detail, 'deepest'
  end

  def test_a_cache_entry_written_before_the_three_states_still_reads
    # `reviews_exhausted` was the old wire field; entries carrying it live in
    # the cache for up to its TTL after an upgrade.
    assert_includes hint('reviews_exhausted' => true), 'Amazon served no more for this session'
    assert_includes hint('reviews_exhausted' => false), '--pages 3'
  end

  def test_handles_a_nil_payload
    result = Amazon::Reviews.analyze(nil)
    assert_equal 0, result['sample_size']
    assert_nil result['score']
  end

  def test_reports_sample_composition
    reviews = sample(10).each_with_index.map { |r, i| r.merge('verified' => i < 7, 'vine' => i == 9) }
    result = analyze(reviews: reviews)
    assert_equal 70, result['verified_pct']
    assert_equal 1, result['vine_count']
    assert_equal 10, result['sample_size']
  end

  # The signal stopped counting an unreadable badge as an unverified purchase;
  # this headline number did not, and it is the one people read first. A run
  # where the badge probe failed on half the cards announced "Verified: 50%"
  # over a listing where every readable card was verified.
  def test_the_verified_headline_ignores_badges_that_could_not_be_read
    reviews = sample(10).each_with_index.map { |r, i| r.merge('verified' => i < 5 ? true : nil) }
    result = analyze(reviews: reviews)
    assert_equal 100, result['verified_pct']
    assert_equal 5, result['verified_readable']
    assert_equal 10, result['sample_size']
  end

  def test_a_sample_with_no_readable_badges_has_no_percentage_to_report
    reviews = sample(10).map { |r| r.merge('verified' => nil) }
    assert_nil analyze(reviews: reviews)['verified_pct']
  end
end

class ReviewsAdjustedRatingTest < Minitest::Test
  def test_averages_only_trustworthy_reviews
    reviews = [
      review(1, 'rating' => 5.0),
      review(2, 'rating' => 5.0),
      review(3, 'rating' => 2.0),
      review(4, 'rating' => 5.0, 'verified' => false),
      review(5, 'rating' => 5.0, 'vine' => true),
      review(6, 'rating' => 5.0, 'body' => 'Received this product for free in exchange for my honest review.')
    ]
    assert_equal 4.0, analyze(reviews: reviews)['adjusted_rating']
  end

  def test_too_few_trustworthy_reviews_yields_nothing
    reviews = [review(1), review(2, 'verified' => false), review(3, 'verified' => false)]
    assert_nil analyze(reviews: reviews)['adjusted_rating']
  end

  def test_unrated_reviews_are_skipped
    reviews = (1..5).map { |i| review(i, 'rating' => nil) }
    assert_nil analyze(reviews: reviews)['adjusted_rating']
  end
end

class ReviewsThemesTest < Minitest::Test
  def test_extracts_repeated_complaints_from_critical_reviews
    reviews = (1..4).map do |i|
      review(i, 'rating' => 2.0, 'title' => 'Bad',
                'body' => 'The battery life is terrible and it stopped working after two weeks.')
    end
    phrases = analyze(reviews: reviews)['themes'].map { |t| t['phrase'] }
    assert_includes phrases, 'battery life'
    assert_includes phrases, 'stopped working'
  end

  def test_five_star_reviews_are_not_mined_for_complaints
    assert_empty analyze(reviews: sample(10, 'rating' => 5.0))['themes']
  end

  def test_bigrams_never_span_a_clause_or_the_title_boundary
    # "Great product" + "Stopped working" must not become "great stopped".
    reviews = (1..4).map do |i|
      review(i, 'rating' => 1.0, 'title' => 'Great product',
                'body' => 'Stopped working. Battery life is poor, packaging arrived crushed.')
    end
    phrases = analyze(reviews: reviews)['themes'].map { |t| t['phrase'] }
    refute_includes phrases, 'great stopped'
    refute_includes phrases, 'poor packaging'
    assert_includes phrases, 'stopped working'
  end

  def test_stopwords_do_not_join_their_neighbours
    reviews = (1..4).map { |i| review(i, 'rating' => 1.0, 'body' => 'The screen is cracked.') }
    phrases = analyze(reviews: reviews)['themes'].map { |t| t['phrase'] }
    refute_includes phrases, 'screen cracked'
    assert_includes phrases, 'screen'
  end

  def test_unique_wording_yields_no_themes
    reviews = (1..4).map do |i|
      review(i, 'rating' => 1.0, 'title' => tag(i), 'body' => "#{tag(i)} #{tag(i + 100)} #{tag(i + 200)}.")
    end
    assert_empty analyze(reviews: reviews)['themes']
  end

  def test_falls_back_to_unigrams_when_no_bigram_repeats
    reviews = (1..4).map do |i|
      review(i, 'rating' => 1.0, 'title' => tag(i), 'body' => "Leaking. #{tag(i)} #{tag(i + 100)}.")
    end
    phrases = analyze(reviews: reviews)['themes'].map { |t| t['phrase'] }
    assert_includes phrases, 'leaking'
  end

  def test_too_few_critical_reviews_to_generalise
    assert_empty analyze(reviews: [review(1, 'rating' => 1.0), review(2, 'rating' => 1.0)])['themes']
  end

  # "What critical reviews mention" is a claim about reviewers, not about word
  # frequency. Unigrams were already counted once per review; bigrams were not,
  # so one person who said "filament jammed" three times cleared the two-mention
  # bar alone and got printed as "(3x)" — three reviewers, as far as anyone
  # reading the report could tell.
  def test_one_reviewer_repeating_a_phrase_is_not_a_theme
    reviews = [
      review(1, 'rating' => 1.0, 'title' => tag(1),
                'body' => 'Filament jammed. Filament jammed again. Filament jammed a third time.'),
      review(2, 'rating' => 1.0, 'title' => tag(2), 'body' => "#{tag(20)} #{tag(21)}."),
      review(3, 'rating' => 1.0, 'title' => tag(3), 'body' => "#{tag(30)} #{tag(31)}.")
    ]
    assert_empty analyze(reviews: reviews)['themes']
  end

  def test_a_phrase_two_reviewers_use_is_still_a_theme
    reviews = [
      review(1, 'rating' => 1.0, 'title' => tag(1), 'body' => 'Filament jammed. Filament jammed again.'),
      review(2, 'rating' => 1.0, 'title' => tag(2), 'body' => 'Filament jammed on the first spool.'),
      review(3, 'rating' => 1.0, 'title' => tag(3), 'body' => "#{tag(30)} #{tag(31)}.")
    ]
    themes = analyze(reviews: reviews)['themes']
    jammed = themes.find { |t| t['phrase'] == 'filament jammed' }
    refute_nil jammed
    # Two reviewers, not the three times it appears.
    assert_equal 2, jammed['count']
  end
end

# --- Review formatting -------------------------------------------------

class ReviewsFormatterTest < Minitest::Test
  def fmt(**kw) = Amazon::Formatter.new(color: false, **kw)

  def data(**over)
    {
      'asin' => 'B0747R1M51', 'url' => 'https://www.amazon.com/dp/B0747R1M51',
      'title' => 'PLA Filament Spool', 'rating' => 4.8, 'reviews' => 2400,
      'histogram' => { '5' => 94, '4' => 3, '3' => 1, '2' => 0, '1' => 2 },
      'reviews_sample' => FakeWorker::REVIEW_SAMPLE.map(&:dup)
    }.merge(over)
  end

  def render(payload = data, **kw)
    analysis = Amazon::Reviews.analyze(payload)
    out, = capture_io_streams { fmt(**kw.slice(:json)).reviews(payload, analysis, **kw.except(:json)) }
    out
  end

  def test_the_verified_line_says_when_it_judged_fewer_cards_than_it_sampled
    sample = FakeWorker::REVIEW_SAMPLE.map(&:dup)
    sample[0]['verified'] = nil
    out = render(data('reviews_sample' => sample))
    # Reporting a percentage of 4 as "of 5 sampled" would overstate what was
    # actually read, which is the whole complaint against the old denominator.
    assert_includes out, 'of 4 readable'
    assert_includes out, '5 sampled'
  end

  def test_the_verified_line_stays_plain_when_every_badge_was_readable
    out = render
    assert_includes out, 'of 5 sampled'
    refute_includes out, 'readable'
  end

  def test_renders_the_whole_report
    out = render
    assert_includes out, 'PLA Filament Spool'
    assert_includes out, '4.8★'
    assert_includes out, '2,400 ratings'
    assert_includes out, 'Rating distribution'
    assert_includes out, '5★'
    assert_includes out, '94%'
    assert_includes out, 'Authenticity'
    assert_includes out, 'Verified:'
    assert_includes out, 'Vine:'
    assert_includes out, 'What critical reviews mention'
    assert_includes out, 'not a verdict'
  end

  def test_rows_the_scraper_never_read_render_as_unknown_not_zero
    # A drawn bar of 0% is a claim about the product. The rows that came back
    # are still worth showing, but the ones that didn't have to look absent,
    # or the picture reads as a five-star wall the page never showed.
    rows = render(data('histogram' => { '5' => 79 })).lines.grep(/\A  \d★ /)
    assert_equal 5, rows.size
    assert_includes rows.first, '79%'
    rows.drop(1).each do |row|
      assert_match(/\?\s*\z/, row)
      refute_includes row, '%'
    end
    # And the check itself abstains rather than scoring the rows it invented.
    assert_includes render(data('histogram' => { '5' => 79 })), "?  Rating distribution: Amazon didn't render"
  end

  def test_adjusted_rating_is_labelled_as_sample_only
    payload = data('reviews_sample' => (1..6).map { |i| review(i, 'rating' => 4.0) })
    out = render(payload)
    assert_includes out, 'Adjusted:  4.0★'
    assert_includes out, 'this sample only'
  end

  def test_omits_sections_it_has_no_data_for
    out = render(data('rating' => nil, 'reviews' => nil, 'histogram' => {}, 'reviews_sample' => []))
    assert_includes out, '(no rating)'
    # The histogram *section* is gone; the histogram *check* still reports why
    # it couldn't run, which is the point of listing uncomputable signals.
    refute_includes out, 'Rating distribution:  '
    assert_includes out, "?  Rating distribution: Amazon didn't render"
    refute_includes out, 'What critical reviews mention'
    refute_includes out, 'Adjusted:'
    refute_includes out, 'Vine:'
  end

  def test_nil_payload_and_json
    out, = capture_io_streams { fmt.reviews(nil, {}) }
    assert_includes out, '(not found)'

    out = render(data, json: true)
    parsed = JSON.parse(out)
    assert_equal 'B0747R1M51', parsed['asin']
    assert_equal 5, parsed['analysis']['sample_size']
  end

  def test_scored_signals_are_itemised_with_their_weight
    payload = data('reviews_sample' => (1..10).map { |i| review(i, 'verified' => false) })
    out = render(payload)
    assert_includes out, 'Verified purchases: 10/10 sampled reviews are unverified'
    assert_includes out, '[+20/20]'
  end

  def test_unrunnable_checks_are_shown_rather_than_silently_passing
    out = render
    assert_includes out, '?  Review timing:'
    assert_includes out, '--pages 3'
  end

  def test_every_risk_band_renders
    %w[low some elevated high].each do |level|
      analysis = { 'score' => 10, 'level' => level, 'confidence' => 'medium', 'signals' => [],
                   'sample_size' => 5, 'themes' => [] }
      out, = capture_io_streams { fmt.reviews(data, analysis) }
      assert_includes out, level == 'low' ? 'low risk' : "#{level} risk"
    end
  end

  def test_unscorable_analysis_says_so_instead_of_showing_zero
    analysis = { 'score' => nil, 'level' => 'unknown', 'confidence' => 'none', 'signals' => [],
                 'sample_size' => 0, 'themes' => [] }
    out, = capture_io_streams { fmt.reviews(data, analysis) }
    assert_includes out, 'not enough data to assess'
    refute_includes out, '0/100'
  end

  def test_verbatim_prints_review_text_and_badges
    out = render(data, verbatim: true)
    assert_includes out, 'Reviews (5 of 5)'
    assert_includes out, 'Prints beautifully'
    assert_includes out, 'verified'
    assert_includes out, 'vine'
    assert_includes out, '4 helpful'
  end

  def test_verbatim_respects_a_limit
    out = render(data, verbatim: true, limit: 2)
    assert_includes out, 'Reviews (2 of 5)'
    refute_includes out, 'Jammed'
  end

  def test_verbatim_tolerates_missing_review_fields
    bare = [{ 'id' => 'R1', 'title' => 'Terse', 'verified' => false, 'vine' => false }]
    out = render(data('reviews_sample' => bare), verbatim: true)
    assert_includes out, '?★'
    assert_includes out, 'Terse'
  end

  # The footer carried the same stale advice as the individual signals: it told
  # you to go deeper after Amazon had already refused to.
  def test_the_footer_stops_advising_a_deeper_walk_once_amazon_has_refused_one
    out = render(data('reviews_walk' => 'exhausted'))
    refute_includes out, 'Use --pages'
    assert_includes out, 'everything Amazon would serve'
  end

  def test_the_footer_still_advises_a_deeper_walk_on_a_shallow_fetch
    out = render(data)
    assert_includes out, 'Use --pages 3'
  end

  def test_the_footer_asks_for_a_deeper_number_than_the_one_already_run
    assert_includes render(data('reviews_walk' => 'complete', 'review_pages' => 3)), 'Use --pages 6'
  end

  def test_the_footer_reports_a_failed_walk_as_failed_not_as_exhausted
    out = render(data('reviews_walk' => 'failed'))
    refute_includes out, 'everything Amazon would serve'
    assert_includes out, 'retry'
  end

  def test_verbatim_with_no_reviews_prints_no_section
    out = render(data('reviews_sample' => []), verbatim: true)
    refute_includes out, 'Reviews ('
  end

  def test_long_review_bodies_wrap
    long = [review(1, 'body' => (%w[alpha bravo charlie delta echo] * 30).join(' '))]
    out = render(data('reviews_sample' => long), verbatim: true)
    body_lines = out.lines.select { |l| l.include?('alpha') }
    assert_operator body_lines.size, :>, 1
    assert(body_lines.all? { |l| l.chomp.length <= 200 })
  end

  def test_summary_block_is_condensed
    payload = data('reviews_sample' => (1..10).map { |i| review(i, 'verified' => false) })
    analysis = Amazon::Reviews.analyze(payload)
    out, = capture_io_streams { fmt.reviews_summary(analysis) }
    assert_includes out, 'Reviews:'
    assert_includes out, 'unverified'
    refute_includes out, 'Rating distribution'
  end

  def test_summary_reports_when_nothing_could_be_assessed
    out, = capture_io_streams { fmt.reviews_summary(Amazon::Reviews.analyze({})) }
    assert_includes out, 'not enough data to assess'
  end

  def test_summary_lists_complaint_themes
    critical = (1..4).map do |i|
      review(i, 'rating' => 1.0, 'title' => "Bad #{tag(i)}",
                'body' => 'The filament jammed constantly and the spool warped badly.')
    end
    analysis = Amazon::Reviews.analyze(data('reviews_sample' => critical))
    out, = capture_io_streams { fmt.reviews_summary(analysis) }
    assert_includes out, 'complaints:'
  end

  def test_summary_prints_nothing_in_json_mode
    out, = capture_io_streams { fmt(json: true).reviews_summary(Amazon::Reviews.analyze(data)) }
    assert_empty out
  end

  def test_color_marks_pass_and_fail_signals
    payload = data('reviews_sample' => (1..10).map { |i| review(i, 'verified' => false) })
    analysis = Amazon::Reviews.analyze(payload)
    out, = capture_io_streams { Amazon::Formatter.new(color: true).reviews(payload, analysis) }
    assert_includes out, "\e[31m"
    assert_includes out, "\e[32m"
  end
end

# --- reviews command ---------------------------------------------------

class ReviewsCommandTest < Minitest::Test
  def setup
    write_config!
    seed_order!(SAMPLE_ORDER.dup)
  end

  def run_cli(*args, worker: FakeWorker.new)
    with_worker(->(*) { worker }) { capture_io_streams { Amazon::CLI.run(args) } }
  end

  def test_default_report
    out, = run_cli('reviews', 'B0747R1M51', '--fresh')
    assert_includes out, 'Rating distribution'
    assert_includes out, 'Authenticity'
    refute_includes out, 'Prints beautifully'
  end

  def test_verbatim_prints_review_bodies
    out, = run_cli('reviews', 'B0747R1M51', '--verbatim', '--fresh')
    assert_includes out, 'Prints beautifully'
  end

  def test_critical_narrows_output_but_not_the_analysis
    out, = run_cli('reviews', 'B0747R1M51', '--critical', '--fresh')
    assert_includes out, 'Jammed'
    refute_includes out, 'Prints beautifully'
    # Scoring still ran on all five, not the three that got printed.
    assert_includes out, '5-review sample'
  end

  # The worker announces a degraded scrape once, while it is scraping. The
  # result is then cached, so every run inside the TTL renders the same partial
  # data with none of the warnings that came with it — and the run that looks
  # clean is the one where the user has no way of knowing it isn't.
  def test_a_cached_degraded_scrape_still_says_it_was_degraded
    degraded = Class.new do
      def item(_asin, **kw)
        FakeWorker.new.item('B1', **kw).merge(
          '_degraded' => ['4/6 expected fields were empty (seller, rating, image, price)']
        )
      end
    end.new
    _, first = run_cli('reviews', 'B0ROTTED', '--fresh', worker: degraded)
    # Not on the fetch: the worker already said it live, and saying it twice
    # trains people to skip it.
    refute_includes first, 'expected fields were empty'

    _, second = run_cli('reviews', 'B0ROTTED', worker: degraded)
    assert_includes second, 'expected fields were empty'
    assert_includes second, 'cached'
  end

  def test_a_cached_clean_scrape_says_nothing
    run_cli('reviews', 'B0CLEAN', '--fresh')
    _, err = run_cli('reviews', 'B0CLEAN')
    refute_includes err, 'cached'
  end

  def test_critical_with_no_low_ratings_explains_the_empty_result
    # Amazon's product-page picks skew positive, so this is common on real
    # listings; printing nothing would read as "no complaints exist".
    happy = Class.new do
      def item(_asin, **kw)
        d = FakeWorker.new.item('B1', **kw)
        d.merge('reviews_sample' => d['reviews_sample'].map { |r| r.merge('rating' => 5.0) })
      end
    end.new
    out, err = run_cli('reviews', 'B0HAPPY', '--critical', '--fresh', worker: happy)
    assert_includes err, 'no 1-3 star reviews'
    assert_includes err, '--pages 3'
    # Not --sort recent: it would suppress the timing check on the very sample
    # this advice is telling the user to go and fetch.
    refute_includes err, '--sort recent'
    refute_includes out, 'Reviews ('
  end

  def test_limit_caps_verbatim_output
    out, = run_cli('reviews', 'B0747R1M51', '--verbatim', '--limit', '1', '--fresh')
    assert_includes out, 'Reviews (1 of 5)'
  end

  def test_pages_and_sort_reach_the_worker
    worker = FakeWorker.new
    run_cli('reviews', 'B0747R1M51', '--pages', '2', '--sort', 'recent', '--fresh', worker: worker)
    assert_equal({ pages: 2, sort: 'recent' }, worker.last_review_args)
  end

  def test_json_carries_the_analysis
    out, = run_cli('--json', 'reviews', 'B0747R1M51', '--fresh')
    parsed = JSON.parse(out)
    assert_equal 5, parsed['analysis']['sample_size']
    assert parsed['analysis']['signals'].any?
  end

  def test_requires_a_target
    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[reviews]) }
    assert_includes err, 'ASIN or product URL is required'
  end

  def test_help
    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[reviews --help]) }
    assert_includes out, 'Usage: amazon reviews'
    assert_includes out, 'not a verdict'
  end

  def test_rejects_a_page_count_that_would_hammer_amazon
    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[reviews B1 --pages 99]) }
    assert_includes err, 'between 0 and 10'

    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[reviews B1 --pages -1]) }
    assert_includes err, 'between 0 and 10'
  end

  def test_rejects_a_limit_below_one
    # `reviews.first(-1)` raises ArgumentError, which is not a RuntimeError and
    # so escaped the CLI's rescue as a backtrace. --pages right beside it has
    # validated its range all along; --limit never did.
    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[reviews B1 --verbatim --limit -1]) }
    assert_includes err, '--limit must be 1 or more'

    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[reviews B1 --verbatim --limit 0]) }
    assert_includes err, '--limit must be 1 or more'
  end

  def test_rejects_bad_flag_values
    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[reviews B1 --pages lots]) }
    assert_includes err, 'needs a number'

    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[reviews B1 --sort cheapest]) }
    assert_includes err, 'helpful, recent'

    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[reviews B1 --nope]) }
    assert_includes err, 'unknown option'
  end

  def test_exits_1_when_the_worker_returns_nothing
    nil_worker = Class.new { def item(_asin, **) = nil }.new
    _, err = run_cli('reviews', 'B1', '--fresh', worker: nil_worker)
    assert_includes err, 'no product data'
  end

  def test_exit_status_is_1_when_nothing_came_back
    nil_worker = Class.new { def item(_asin, **) = nil }.new
    with_worker(->(*) { nil_worker }) do
      capture_io_streams { assert_equal 1, Amazon::CLI.run(%w[reviews B1 --fresh]) }
    end
  end

  def test_results_are_cached_between_runs
    calls = 0
    counting = Class.new do
      define_method(:item) { |_asin, **kw| calls += 1; FakeWorker.new.item('B1', **kw) }
    end.new
    run_cli('reviews', 'B0CACHED', '--fresh', worker: counting)
    run_cli('reviews', 'B0CACHED', worker: counting)
    assert_equal 1, calls
  end
end

class ItemWithReviewsTest < Minitest::Test
  def setup
    write_config!
    seed_order!(SAMPLE_ORDER.dup)
  end

  def test_appends_a_review_summary
    out, = with_worker(->(*) { FakeWorker.new }) do
      capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[item B0747R1M51 --reviews --fresh]) }
    end
    assert_includes out, 'PLA Filament'
    assert_includes out, 'Price:'
    assert_includes out, 'Reviews:'
  end

  def test_plain_item_lookup_is_unaffected
    out, = with_worker(->(*) { FakeWorker.new }) do
      capture_io_streams { Amazon::CLI.run(%w[item B0747R1M51 --fresh]) }
    end
    refute_includes out, 'Reviews:'
    refute_includes out, 'Authenticity'
  end

  def test_review_lookups_do_not_share_a_cache_entry_with_plain_ones
    # Serving a --reviews request from a plain entry would silently drop the
    # sample and report "not enough data" on a product that has plenty.
    worker = FakeWorker.new
    with_worker(->(*) { worker }) do
      capture_io_streams { Amazon::CLI.run(%w[item B0SPLIT --fresh]) }
      out, = capture_io_streams { Amazon::CLI.run(%w[item B0SPLIT --reviews]) }
      assert_includes out, 'Reviews:'
    end
  end

  def test_json_output_includes_the_analysis
    out, = with_worker(->(*) { FakeWorker.new }) do
      capture_io_streams { Amazon::CLI.run(%w[--json item B0747R1M51 --reviews --fresh]) }
    end
    assert JSON.parse(out)['analysis']['signals'].any?
  end

  def test_help_mentions_the_flag
    out, = capture_io_streams { Amazon::CLI.run(%w[item --help]) }
    assert_includes out, '--reviews'
    assert_includes out, 'amazon reviews'
  end

  def test_top_level_help_lists_the_command
    out, = capture_io_streams { Amazon::CLI.run(%w[help]) }
    assert_includes out, 'reviews'
  end
end

# The `total` event's collapsed count was one instance of a shape that repeats
# across the CLI: a zero printed without saying whether anything was looked at.
# Every test here asserts the *distinction* rather than the wording — two runs
# that used to print byte-identical output now don't.
class EmptyResultsSayWhatWasSearchedTest < Minitest::Test
  def setup
    write_config!
  end

  def fmt = Amazon::Formatter.new(color: false)

  def test_an_unsynced_archive_does_not_read_like_a_year_with_no_orders
    reset_store!
    unsynced, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[order list]) }

    seed_order!(SAMPLE_ORDER.dup)
    filtered, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[order list --year 1999]) }

    assert_includes unsynced, 'nothing stored yet'
    assert_includes unsynced, 'amazon order sync'
    assert_includes filtered, 'nothing from 1999'
    assert_includes filtered, '1 stored order'
    assert_includes filtered, 'stored years: 2023'
    refute_equal unsynced, filtered
  end

  def test_a_search_that_found_nothing_says_how_much_it_read
    reset_store!
    unsynced, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[order search filament]) }

    seed_order!(SAMPLE_ORDER.dup)
    searched, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[order search zzz]) }
    filtered, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[order search filament --year 1999]) }

    assert_includes unsynced, 'nothing stored yet'
    assert_includes searched, 'searched 1 stored order'
    assert_includes filtered, 'nothing from 1999'
    # All three are "no matches". Nothing else about them may coincide.
    [unsynced, searched, filtered].combination(2) do |a, b|
      refute_equal a, b
    end
  end

  # The advice was for a command that does not exist — `amazon sync` is not a
  # subcommand, so the one actionable thing the old line said was also wrong.
  def test_the_sync_advice_names_a_real_command
    reset_store!
    out, = capture_io_streams { Amazon::CLI.run(%w[order list]) }
    advice = out[/`([^`]+)`/, 1]
    refute_nil advice, "empty listing should suggest a command"

    argv = advice.split.drop(1) # drop the "amazon" program name
    _, err = capture_io_streams { Amazon::CLI.run(argv + ['--help']) }
    refute_includes err, 'unknown', "`#{advice}` is not a real subcommand"
  end

  def test_never_bought_does_not_read_like_never_synced
    never, = capture_io_streams do
      fmt.item('asin' => 'B1', 'title' => 'T', 'purchases' => [], 'purchases_searched' => 222)
    end
    unsynced, = capture_io_streams do
      fmt.item('asin' => 'B1', 'title' => 'T', 'purchases' => [], 'purchases_searched' => 0)
    end

    assert_includes never, 'not in your 222 stored orders'
    assert_includes unsynced, 'amazon order sync'
    refute_equal never, unsynced
  end

  # Threading the denominator through `item.rb` is the half that can rot
  # silently: drop the merge and the formatter falls back to printing nothing,
  # which is exactly the old behaviour and breaks no formatter test.
  def test_the_item_command_passes_the_denominator_it_actually_has
    reset_store!
    unsynced, = with_worker(->(*) { FakeWorker.new }) do
      capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[item B0747R1M51 --fresh]) }
    end
    assert_includes unsynced, 'no local orders to check'

    seed_order!(SAMPLE_ORDER.merge('order_id' => '111-0000000-0000009',
                                   'items' => [{ 'title' => 'Something else',
                                                 'link' => '/dp/B00UNRELATED' }]))
    stocked, = with_worker(->(*) { FakeWorker.new }) do
      capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[item B0747R1M51 --fresh]) }
    end
    assert_includes stocked, 'not in your 1 stored order'
    refute_equal unsynced, stocked
  end

  # Collapsing runs is what makes the line readable at two decades of history;
  # a gap is the one thing in it worth reading, so it must survive collapsing.
  def test_stored_years_collapse_to_runs_but_keep_their_gaps
    reset_store!
    store = Amazon::Store.new
    %w[2019 2020 2021 2024].each_with_index do |y, i|
      store.write_order(SAMPLE_ORDER.merge('order_id' => "111-0000000-000000#{i}",
                                           'order_placed' => "#{y}-06-01"))
    end
    store.commit_index!

    out, = capture_io_streams { Amazon::CLI.run(%w[order list --year 1995]) }
    assert_includes out, 'stored years: 2019–2021, 2024'
    assert_includes out, '4 stored orders'
  end

  # The denominator is a required argument, not a defaulted one: a caller that
  # doesn't know what it searched can't print an empty result at all. This is
  # the invariant living in the signature instead of in a runtime branch no
  # user could reach.
  def test_an_empty_result_cannot_be_printed_without_saying_what_was_searched
    assert_raises(ArgumentError) { fmt.list([]) }
    assert_raises(ArgumentError) { fmt.search([], 'zzz') }
  end

  # `item` dumps `data` wholesale in JSON mode, so the denominator reaches
  # `--json` as a side effect of a `merge` in `item.rb`. That made it true by
  # accident — a contract with no assertion at all, which is the inverse of a
  # guard that can't fail and just as quiet. `"purchases": []` is worse for a
  # script acting unattended than for a human who might smell something off.
  def test_the_json_payload_carries_the_denominator_too
    reset_store!
    out, = with_worker(->(*) { FakeWorker.new }) do
      capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[--json item B0747R1M51 --fresh]) }
    end
    payload = JSON.parse(out)
    assert_equal [], payload['purchases']
    assert_equal 0, payload['purchases_searched'], 'an empty purchases list needs its denominator'

    seed_order!(SAMPLE_ORDER.merge('order_id' => '111-0000000-0000009',
                                   'items' => [{ 'title' => 'Something else',
                                                 'link' => '/dp/B00UNRELATED' }]))
    out, = with_worker(->(*) { FakeWorker.new }) do
      capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[--json item B0747R1M51 --fresh]) }
    end
    assert_equal 1, JSON.parse(out)['purchases_searched']
  end
end


# --- subscribe & save --------------------------------------------------

SAMPLE_SUBSCRIPTION = {
  'subscription_id' => 'SNSD0_FIXTURESUB0000000001',
  'title' => 'Example Dishwasher Detergent Gel, Lemon, 75oz',
  'variation' => nil,
  'next_delivery_label' => 'September 30',
  'next_delivery_date' => '2026-09-30',
  'image' => 'https://m.media-amazon.com/images/I/00FIXTUREIMG.jpg',
  'schedule_raw' => '1 unit every 1 month',
  'quantity' => 1,
  'interval_count' => 1,
  'interval_unit' => 'month',
  'price' => 14.22,
  'price_raw' => '$14.22',
  'discount' => 'Saving 5%'
}.freeze

SAMPLE_DETAIL = {
  'subscription_id' => 'SNSD0_FIXTURESUB0000000001',
  'title' => 'Example Dishwasher Detergent Gel, Lemon, 75oz',
  'variation' => nil,
  'asin' => 'B000FIXTUR',
  'image' => 'https://m.media-amazon.com/images/I/00FIXTUREIMG.jpg',
  'merchant' => 'Amazon.com and top rated sellers',
  'next_delivery_label' => 'Wednesday, September 30',
  'next_delivery_date' => '2026-09-30',
  'next_delivery_prefix' => 'Next delivery will arrive by',
  'discount_now' => 'Get it now with 5% off',
  'discount_percent' => 5,
  'backup_item' => nil,
  'lifetime_savings' => 12.34,
  'lifetime_savings_text' => 'You have saved $12.34 on this subscription!',
  'tier_level' => 'BASE',
  'actions' => %w[CANCEL CHANGE_QUANTITY_FREQUENCY],
  'schedule_raw' => '1 unit every 1 month',
  'quantity' => 1,
  'interval_count' => 1,
  'interval_unit' => 'month'
}.freeze

SAMPLE_DELIVERY = {
  'date' => '2026-09-02',
  'date_label' => 'Sep 2',
  'kind' => 'current',
  'editable_until' => 'Thursday, August 27',
  'editable_until_label' => 'Last day to edit delivery:',
  'savings' => '$1.95',
  'savings_label' => 'Estimated savings for this delivery:',
  'tiering' => 'Add 2 more subscriptions to this delivery and unlock extra savings up to 15%.',
  'items' => [
    { 'subscription_id' => 'SNSD0_FIXTURESUB0000000004', 'title' => 'Example Laundry Detergent',
      'variation' => nil, 'image' => 'https://m.media-amazon.com/images/I/00FIXTUREIMG._SS145_.jpg',
      'price' => 14.22, 'price_raw' => '$14.22',
      'discount' => 'Saving 5%', 'skippable' => true }
  ],
  'subtotal' => 14.22
}.freeze

FUTURE_DELIVERY = {
  'date' => '2026-09-30', 'date_label' => 'September 30', 'kind' => 'future',
  'editable_until' => nil, 'editable_until_label' => nil,
  'savings' => nil, 'savings_label' => nil, 'tiering' => nil,
  'items' => [
    { 'subscription_id' => 'SNSD0_FIXTURESUB0000000005', 'title' => 'Example Paper Towels',
      'variation' => nil, 'image' => 'https://m.media-amazon.com/images/I/00FIXTUREIMG2._SS145_.jpg',
      'price' => nil, 'price_raw' => nil,
      'discount' => nil, 'skippable' => false }
  ],
  'subtotal' => nil
}.freeze

# The subscribe commands cache to a shared XDG root, so one test's rows are the
# next test's cache hit unless this runs first.
def reset_subscribe_cache!
  Amazon::Commands::Subscribe::Cached.invalidate!
end

# Records what it was asked for, so the flags and the cache can be checked at
# the seam rather than by inspecting output that would look the same either way.
class FakeSubscribeWorker
  attr_reader :asked_all, :calls, :subscription_total, :not_found

  def initialize(rows: [SAMPLE_SUBSCRIPTION], cards: [SAMPLE_DELIVERY], detail: SAMPLE_DETAIL,
                 total: nil, not_found: nil)
    @rows = rows
    @cards = cards
    @detail = detail
    @subscription_total = total
    @not_found = not_found
    @calls = 0
  end

  def subscriptions(all: false)
    @calls += 1
    @asked_all = all
    @rows
  end

  def deliveries
    @calls += 1
    @cards
  end

  def subscription(target)
    @calls += 1
    @asked_for = target
    @detail
  end

  def skip(target, confirm:)
    @calls += 1
    @asked_for = target
    @asked_confirm = confirm
    return nil unless @skip_result

    @skip_result.merge('confirmed' => confirm)
  end

  def cancel(target, confirm:, reason: nil)
    @calls += 1
    @asked_for = target
    @asked_confirm = confirm
    @asked_reason = reason
    return nil unless @cancel_result

    @cancel_result.merge('cancelled' => confirm)
  end

  attr_reader :asked_for, :asked_confirm, :asked_reason

  def with_skip(result)
    @skip_result = result
    self
  end

  def with_cancel(result)
    @cancel_result = result
    self
  end
end

SAMPLE_CANCEL = {
  'subscription_id' => 'SNSD0_FIXTURESUB0000000001',
  'title' => 'Example Dishwasher Detergent Gel, Lemon, 75oz',
  'next_delivery_label' => 'September 30',
  'next_delivery_date' => '2026-09-30',
  'heading' => 'Cancel your subscription?',
  'consequences' => [
    'You will no longer receive your Subscribe & Save discount.',
    "We will cancel any orders of this item that haven't yet entered the delivery process."
  ],
  'lifetime_savings_text' => "You have saved\n$16.92\n$16.92 on this subscription!",
  'reasons' => %w[no_more_needed stopped_using accident other],
  'reason' => nil,
  'cancelled' => false,
  'verified' => nil
}.freeze

SAMPLE_SKIP = {
  'subscription_id' => 'SNSD0_FIXTURESUB0000000001',
  'title' => 'Example Dishwasher Detergent Gel, Lemon, 75oz',
  'delivery_date' => '2026-09-02',
  'delivery_label' => 'Sep 2',
  'heading' => 'Skip your September 2 delivery',
  'product' => 'Example Dishwasher Detergent Gel, Lemon, 75oz',
  'warning' => 'This will cancel your order. You may lose applied coupons.',
  'has_csrf' => true,
  'confirmed' => false,
  'verified' => nil
}.freeze

class SubscribeDispatchTest < Minitest::Test
  def setup = write_config!

  def test_help_mentions_the_namespace
    out, = capture_io_streams { Amazon::CLI.run(['help']) }
    assert_includes out, 'subscribe list'
    assert_includes out, 'subscribe upcoming'
    assert_includes out, 'subscribe show'
  end

  def test_bare_namespace_prints_usage_and_exits_2
    out, = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[subscribe]) }
    assert_includes out, 'Subcommands:'
  end

  def test_explicit_help_exits_0
    %w[help -h --help].each do |flag|
      out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(['subscribe', flag]) }
      assert_includes out, 'subscribe <subcommand>'
    end
  end

  def test_unknown_subcommand
    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[subscribe bogus]) }
    assert_includes err, 'unknown subscribe subcommand: bogus'
  end

  def test_subcommands_route_through_the_namespace
    { List: 7, Upcoming: 8, Show: 9 }.each do |klass, code|
      with_command(Amazon::Commands::Subscribe, klass, result: code) do
        capture_io_streams do
          assert_equal code, Amazon::CLI.run(['subscribe', klass.to_s.downcase])
        end
      end
    end
  end
end

class SubscribeListCommandTest < Minitest::Test
  def setup
    write_config!
    reset_subscribe_cache!
  end

  def test_it_lists_what_the_worker_returned
    out, = with_worker(->(*) { FakeSubscribeWorker.new }) do
      capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[subscribe list]) }
    end
    assert_includes out, 'SNSD0_FIXTURESUB0000000001'
    assert_includes out, 'September 30'
    assert_includes out, '1 month'
  end

  # The price column is the whole reason `list` reads the deliveries view too.
  def test_the_price_column_carries_the_committed_price
    out, = with_worker(->(*) { FakeSubscribeWorker.new }) do
      capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
    end
    assert_includes out, '$14.22'
  end

  # A future delivery has no price, only a rate. Printing $0.00 there would say
  # it is free.
  def test_an_unpriced_row_shows_its_discount_rate_instead
    row = SAMPLE_SUBSCRIPTION.merge('price' => nil, 'price_raw' => nil, 'discount' => 'Saving 15%')
    out, = with_worker(->(*) { FakeSubscribeWorker.new(rows: [row]) }) do
      capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
    end
    assert_includes out, '15%'
    refute_includes out, '$0.00'
  end

  def test_a_row_with_neither_price_nor_discount_leaves_the_column_blank
    row = SAMPLE_SUBSCRIPTION.merge('price' => nil, 'discount' => nil)
    out, = with_worker(->(*) { FakeSubscribeWorker.new(rows: [row]) }) do
      capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
    end
    refute_includes out, '$'
  end

  def test_all_is_passed_through_to_the_worker
    fake = FakeSubscribeWorker.new
    with_worker(->(*) { fake }) do
      capture_io_streams { Amazon::CLI.run(%w[subscribe list --all]) }
    end
    assert_equal true, fake.asked_all

    reset_subscribe_cache!
    fake = FakeSubscribeWorker.new
    with_worker(->(*) { fake }) do
      capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
    end
    assert_equal false, fake.asked_all
  end

  # --all and the first page are different answers to the same question, so
  # they cannot share a cache entry: otherwise `list` warms the cache with 30
  # rows and `list --all` serves those 30 back as though they were all 59.
  def test_all_and_the_first_page_are_cached_separately
    fake = FakeSubscribeWorker.new(rows: [SAMPLE_SUBSCRIPTION], total: 59)
    with_worker(->(*) { fake }) do
      capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
      capture_io_streams { Amazon::CLI.run(%w[subscribe list --all]) }
    end
    assert_equal 2, fake.calls
  end

  def test_json_output_is_the_worker_records_verbatim
    out, = with_worker(->(*) { FakeSubscribeWorker.new }) do
      capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[--json subscribe list]) }
    end
    assert_equal [SAMPLE_SUBSCRIPTION], JSON.parse(out)
  end

  def test_help_and_unknown_option
    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[subscribe list --help]) }
    assert_includes out, '--all'

    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[subscribe list --nope]) }
    assert_includes err, 'unknown list option: --nope'
  end
end

class SubscribeCacheTest < Minitest::Test
  def setup
    write_config!
    reset_subscribe_cache!
  end

  def test_a_second_run_inside_the_ttl_does_not_touch_amazon
    fake = FakeSubscribeWorker.new
    out = nil
    with_worker(->(*) { fake }) do
      capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
      out, = capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
    end
    assert_equal 1, fake.calls
    assert_includes out, 'SNSD0_FIXTURESUB0000000001'
  end

  # A cached read is indistinguishable from a live one, and a schedule that
  # changed twenty minutes ago looks current either way. The age is the only
  # thing that explains the surprise.
  def test_a_cached_read_says_so_on_stderr
    fake = FakeSubscribeWorker.new
    err = nil
    with_worker(->(*) { fake }) do
      capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
      _, err = capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
    end
    assert_match(/cached .* ago/, err)
    assert_includes err, '--fresh'
  end

  # JSON is a data interface; a chatty stderr line is fine, but it must not be
  # the thing that makes `--json | jq` print a warning into someone's pipeline
  # output. (It goes to stderr either way — this pins the intent.)
  def test_the_cache_note_is_suppressed_for_json
    fake = FakeSubscribeWorker.new
    err = nil
    with_worker(->(*) { fake }) do
      capture_io_streams { Amazon::CLI.run(%w[--json subscribe list]) }
      _, err = capture_io_streams { Amazon::CLI.run(%w[--json subscribe list]) }
    end
    refute_includes err, 'cached'
  end

  def test_fresh_re_reads_amazon
    fake = FakeSubscribeWorker.new
    with_worker(->(*) { fake }) do
      capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
      capture_io_streams { Amazon::CLI.run(%w[subscribe list --fresh]) }
    end
    assert_equal 2, fake.calls
  end

  # The three views describe one account. Refreshing the list while `upcoming`
  # still serves a 25-minute-old copy of the same subscriptions reproduces the
  # staleness --fresh was reached for.
  def test_fresh_on_one_subcommand_drops_the_others_too
    fake = FakeSubscribeWorker.new
    with_worker(->(*) { fake }) do
      capture_io_streams { Amazon::CLI.run(%w[subscribe upcoming]) }
      capture_io_streams { Amazon::CLI.run(%w[subscribe list --fresh]) }
      capture_io_streams { Amazon::CLI.run(%w[subscribe upcoming]) }
    end
    assert_equal 3, fake.calls, 'upcoming should have been re-read after list --fresh'
  end

  # The hook Phase 2 needs: anything that changes a subscription invalidates
  # every view, not just the one that issued the change.
  def test_invalidate_empties_the_namespace
    fake = FakeSubscribeWorker.new
    with_worker(->(*) { fake }) do
      capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
      Amazon::Commands::Subscribe::Cached.invalidate!
      capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
    end
    assert_equal 2, fake.calls
  end

  def test_clearing_a_namespace_that_was_never_written_is_not_an_error
    Amazon::Cache.new('never-used-namespace').clear
  end

  # Backdating the cache file is the only way to exercise the wording that a
  # real user sees most often — a read minutes old, not seconds.
  def backdate_cache!(seconds)
    dir = Amazon::Config.cache_dir.join('live', Amazon::Commands::Subscribe::Cached::NAMESPACE)
    Dir.glob(dir.join('*.json')).each do |f|
      t = Time.now - seconds
      File.utime(t, t, f)
    end
  end

  def test_a_read_minutes_old_says_minutes
    fake = FakeSubscribeWorker.new
    err = nil
    with_worker(->(*) { fake }) do
      capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
      backdate_cache!(300)
      _, err = capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
    end
    assert_includes err, 'cached 5 minutes ago'
    assert_equal 1, fake.calls
  end

  def test_the_minute_boundary_is_singular
    fake = FakeSubscribeWorker.new
    err = nil
    with_worker(->(*) { fake }) do
      capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
      backdate_cache!(75)
      _, err = capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
    end
    assert_includes err, 'cached 1 minute ago'
  end

  # Half an hour is the TTL, so a read older than that is a miss, not a very
  # old hit.
  def test_a_read_past_the_ttl_is_re_read
    fake = FakeSubscribeWorker.new
    with_worker(->(*) { fake }) do
      capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
      backdate_cache!(Amazon::Commands::Subscribe::Cached::TTL + 60)
      capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
    end
    assert_equal 2, fake.calls
  end

  def test_a_fresh_read_seconds_old_reports_seconds
    fake = FakeSubscribeWorker.new
    err = nil
    with_worker(->(*) { fake }) do
      capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
      _, err = capture_io_streams { Amazon::CLI.run(%w[subscribe list]) }
    end
    assert_match(/cached \d+s ago/, err)
  end
end

class SubscribeUpcomingCommandTest < Minitest::Test
  def setup
    write_config!
    reset_subscribe_cache!
  end

  def run_upcoming(argv, cards:)
    out, = with_worker(->(*) { FakeSubscribeWorker.new(cards: cards) }) do
      capture_io_streams { assert_equal 0, Amazon::CLI.run(argv) }
    end
    out
  end

  def many_deliveries(n)
    (1..n).map { |i| FUTURE_DELIVERY.merge('date_label' => "Delivery #{i}") }
  end

  def test_it_prints_each_delivery
    out = run_upcoming(%w[subscribe upcoming --all], cards: [SAMPLE_DELIVERY, FUTURE_DELIVERY])
    assert_includes out, 'Sep 2'
    assert_includes out, 'September 30'
  end

  # Seven deliveries and 84 item lines is not an answer to "what's coming".
  # Only the next one has prices and a deadline; the rest are a forecast.
  def test_only_the_next_delivery_prints_by_default
    out = run_upcoming(%w[subscribe upcoming], cards: many_deliveries(7))
    assert_includes out, 'Delivery 1'
    refute_includes out, 'Delivery 2'
    assert_includes out, '6 more deliveries scheduled'
  end

  def test_all_prints_every_delivery
    out = run_upcoming(%w[subscribe upcoming --all], cards: many_deliveries(7))
    assert_includes out, 'Delivery 7'
    refute_includes out, 'more deliveries scheduled'
  end

  def test_limit_takes_a_count
    out = run_upcoming(%w[subscribe upcoming --limit 5], cards: many_deliveries(7))
    assert_includes out, 'Delivery 5'
    refute_includes out, 'Delivery 6'
    assert_includes out, '2 more deliveries scheduled'
  end

  def test_the_note_is_singular_for_one_remaining
    out = run_upcoming(%w[subscribe upcoming], cards: many_deliveries(2))
    assert_includes out, '1 more delivery scheduled'
  end

  def test_a_limit_larger_than_the_list_adds_no_note
    out = run_upcoming(%w[subscribe upcoming --limit 50], cards: many_deliveries(1))
    refute_includes out, 'more deliveries'
  end

  # `--limit 0` and `--limit -1` are not smaller requests, they are nonsense,
  # and Integer()'s exceptions are not RuntimeErrors — unguarded they escape
  # the CLI's rescue as a backtrace.
  def test_a_junk_limit_is_a_usage_error_not_a_backtrace
    ['--limit 0', '--limit -1', '--limit abc', '--limit'].each do |flags|
      _, err = capture_io_streams do
        assert_equal 2, Amazon::CLI.run(['subscribe', 'upcoming', *flags.split])
      end
      assert_includes err, '--limit'
    end
  end

  # --limit is a display choice. A caller piping to jq asked for the data.
  def test_json_ignores_the_limit_and_returns_everything
    out, = with_worker(->(*) { FakeSubscribeWorker.new(cards: many_deliveries(7)) }) do
      capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[--json subscribe upcoming]) }
    end
    assert_equal 7, JSON.parse(out).size
  end

  def test_fresh_re_reads_amazon
    fake = FakeSubscribeWorker.new
    with_worker(->(*) { fake }) do
      capture_io_streams { Amazon::CLI.run(%w[subscribe upcoming]) }
      capture_io_streams { Amazon::CLI.run(%w[subscribe upcoming --fresh]) }
    end
    assert_equal 2, fake.calls
  end

  def test_help_and_unknown_option
    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[subscribe upcoming --help]) }
    assert_includes out, '--limit'

    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[subscribe upcoming --nope]) }
    assert_includes err, 'unknown upcoming option: --nope'
  end
end

class SubscribeShowCommandTest < Minitest::Test
  def setup
    write_config!
    reset_subscribe_cache!
  end

  def test_it_prints_the_whole_record
    out, = with_worker(->(*) { FakeSubscribeWorker.new }) do
      capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[subscribe show dishwasher]) }
    end
    assert_includes out, 'Example Dishwasher Detergent'
    assert_includes out, 'B000FIXTUR'
    assert_includes out, '$12.34'
    assert_includes out, 'Amazon.com and top rated sellers'
  end

  def test_a_search_term_of_several_words_reaches_the_worker_intact
    fake = FakeSubscribeWorker.new
    with_worker(->(*) { fake }) do
      capture_io_streams { Amazon::CLI.run(['subscribe', 'show', 'paper', 'towels']) }
    end
    assert_equal 'paper towels', fake.asked_for
  end

  def test_json_output
    out, = with_worker(->(*) { FakeSubscribeWorker.new }) do
      capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[--json subscribe show dishwasher]) }
    end
    assert_equal SAMPLE_DETAIL, JSON.parse(out)
  end

  def test_a_missing_target_is_a_usage_error
    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[subscribe show]) }
    assert_includes err, 'subscription id or search term is required'
  end

  # Nothing matched is a question with an answer, not a failure to reach
  # Amazon — and the worker's own wording names the candidates.
  def test_no_match_exits_2_with_the_workers_explanation
    fake = FakeSubscribeWorker.new(detail: nil, not_found: "no active subscription matching 'zzz'.")
    _, err = with_worker(->(*) { fake }) do
      capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[subscribe show zzz]) }
    end
    assert_includes err, "no active subscription matching 'zzz'"
  end

  # Caching a miss would mean fixing the typo, re-running, and being told no a
  # second time by a file rather than by Amazon.
  def test_a_miss_is_not_cached
    fake = FakeSubscribeWorker.new(detail: nil, not_found: 'no active subscription')
    with_worker(->(*) { fake }) do
      capture_io_streams { Amazon::CLI.run(%w[subscribe show zzz]) }
      capture_io_streams { Amazon::CLI.run(%w[subscribe show zzz]) }
    end
    assert_equal 2, fake.calls
  end

  def test_a_hit_is_cached
    fake = FakeSubscribeWorker.new
    with_worker(->(*) { fake }) do
      capture_io_streams { Amazon::CLI.run(%w[subscribe show dishwasher]) }
      capture_io_streams { Amazon::CLI.run(%w[subscribe show dishwasher]) }
    end
    assert_equal 1, fake.calls
  end

  def test_fresh_re_reads_amazon
    fake = FakeSubscribeWorker.new
    with_worker(->(*) { fake }) do
      capture_io_streams { Amazon::CLI.run(%w[subscribe show dishwasher]) }
      capture_io_streams { Amazon::CLI.run(%w[subscribe show dishwasher --fresh]) }
    end
    assert_equal 2, fake.calls
  end

  # A worker that returns nothing and explains nothing still has to say
  # something; exiting 2 in silence looks like the command crashed.
  def test_an_unexplained_miss_still_gets_a_message
    fake = FakeSubscribeWorker.new(detail: nil, not_found: nil)
    _, err = with_worker(->(*) { fake }) do
      capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[subscribe show zzz]) }
    end
    assert_includes err, 'nothing matched "zzz"'
  end

  def test_help_and_unknown_option
    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[subscribe show --help]) }
    assert_includes out, 'id-or-search'

    _, err = capture_io_streams { assert_equal 2, Amazon::CLI.run(%w[subscribe show --nope]) }
    assert_includes err, 'unknown option: --nope'
  end
end

class SubscriptionFormatterTest < Minitest::Test
  def fmt(json: false) = Amazon::Formatter.new(json: json, color: false)

  def test_an_empty_list_says_so_rather_than_printing_a_bare_header
    out, = capture_io_streams { fmt.subscriptions([], total: nil) }
    assert_includes out, 'no Subscribe & Save subscriptions'
  end

  def test_an_empty_list_in_json_is_still_json
    out, = capture_io_streams { fmt(json: true).subscriptions([], total: 0) }
    assert_equal [], JSON.parse(out)
  end

  def test_a_partial_page_offers_the_flag_that_completes_it
    out, = capture_io_streams { fmt.subscriptions([SAMPLE_SUBSCRIPTION], total: 59) }
    assert_includes out, 'showing 1 of 59 — pass --all for the rest'
  end

  # After --all a short list means pagination gave up, and the worker has
  # already said why on stderr. Repeating "pass --all" would be advice to retry
  # the thing that just failed.
  def test_a_partial_page_after_all_does_not_suggest_all_again
    out, = capture_io_streams { fmt.subscriptions([SAMPLE_SUBSCRIPTION], total: 59, loaded_all: true) }
    assert_includes out, 'showing 1 of the 59 subscriptions Amazon reports'
    refute_includes out, 'pass --all'
  end

  def test_a_complete_list_says_nothing_about_counts
    out, = capture_io_streams { fmt.subscriptions([SAMPLE_SUBSCRIPTION], total: 1) }
    refute_includes out, 'showing'
  end

  def test_no_total_at_all_says_nothing_about_counts
    out, = capture_io_streams { fmt.subscriptions([SAMPLE_SUBSCRIPTION], total: nil) }
    refute_includes out, 'showing'
  end

  def test_a_multi_unit_interval_is_pluralised
    row = SAMPLE_SUBSCRIPTION.merge('interval_count' => 6, 'interval_unit' => 'month')
    out, = capture_io_streams { fmt.subscriptions([row], total: 1) }
    assert_includes out, '6 months'
  end

  # An unparsed schedule still has to print the words Amazon showed the user,
  # because that is the only copy of the schedule left.
  def test_an_unparsed_schedule_falls_back_to_amazons_own_words
    row = SAMPLE_SUBSCRIPTION.merge('interval_count' => nil, 'interval_unit' => nil,
                                    'schedule_raw' => 'every so often')
    out, = capture_io_streams { fmt.subscriptions([row], total: 1) }
    assert_includes out, 'every so often'
  end

  def test_a_row_with_nothing_readable_prints_question_marks_not_blanks
    row = SAMPLE_SUBSCRIPTION.merge('interval_count' => nil, 'interval_unit' => nil,
                                    'schedule_raw' => nil, 'quantity' => nil,
                                    'next_delivery_label' => nil)
    out, = capture_io_streams { fmt.subscriptions([row], total: 1) }
    assert_includes out, '?'
  end
end

class DeliveriesFormatterTest < Minitest::Test
  def fmt(json: false) = Amazon::Formatter.new(json: json, color: false)

  def render(cards, **kw)
    out, = capture_io_streams { fmt.deliveries(cards, **kw) }
    out
  end

  def test_no_deliveries_says_so
    assert_includes render([]), 'no scheduled Subscribe & Save deliveries'
  end

  def test_empty_in_json_is_still_json
    out, = capture_io_streams { fmt(json: true).deliveries([]) }
    assert_equal [], JSON.parse(out)
  end

  def test_the_next_delivery_shows_its_deadline_price_and_savings
    out = render([SAMPLE_DELIVERY])
    assert_includes out, 'Last day to edit delivery: Thursday, August 27'
    assert_includes out, 'Estimated savings for this delivery: $1.95'
    assert_includes out, '$14.22'
    assert_includes out, 'Saving 5%'
    assert_includes out, '· next'
  end

  # Amazon's savings value is a bare "$1.95". Without a label it reads as a
  # price, so a missing label must still produce one.
  def test_a_missing_label_falls_back_to_one_of_ours
    out = render([SAMPLE_DELIVERY.merge('savings_label' => nil, 'editable_until_label' => '')])
    assert_includes out, 'Savings: $1.95'
    assert_includes out, 'Last day to edit: Thursday, August 27'
  end

  # A future delivery has no prices on Amazon's side. Printing $0.00 would say
  # it is free; printing a subtotal of 0 would say the same thing louder.
  def test_a_future_delivery_shows_no_prices_and_no_subtotal
    out = render([FUTURE_DELIVERY])
    refute_includes out, '$0.00'
    assert_includes out, 'Example Paper Towels'
    assert_includes out, '1 item'
  end

  def test_a_card_with_no_date_at_all_is_still_printed
    out = render([FUTURE_DELIVERY.merge('date' => nil, 'date_label' => nil)])
    assert_includes out, '(undated)'
  end

  def test_a_card_with_only_an_iso_date_uses_it
    out = render([FUTURE_DELIVERY.merge('date_label' => nil)])
    assert_includes out, '2026-09-30'
  end

  def test_items_are_optional
    out = render([FUTURE_DELIVERY.merge('items' => nil)])
    assert_includes out, '0 items'
  end

  def test_a_limit_of_nil_shows_everything
    out = render([SAMPLE_DELIVERY, FUTURE_DELIVERY], limit: nil)
    assert_includes out, 'September 30'
  end
end

class SubscriptionDetailFormatterTest < Minitest::Test
  def fmt(json: false) = Amazon::Formatter.new(json: json, color: false)

  def render(detail)
    out, = capture_io_streams { fmt.subscription(detail) }
    out
  end

  def test_it_labels_every_field_it_prints
    out = render(SAMPLE_DETAIL)
    assert_includes out, 'next delivery'
    assert_includes out, 'Wednesday, September 30'
    assert_includes out, 'schedule         1 unit every 1 month'
    assert_includes out, 'saved so far     $12.34'
    assert_includes out, 'asin             B000FIXTUR'
  end

  # "Next delivery will arrive by" is an arrival estimate, not a ship date, and
  # Amazon's wording is the only thing that says so.
  def test_an_arrival_estimate_is_marked_as_one
    assert_includes render(SAMPLE_DETAIL), '(arrives by)'
  end

  def test_a_bare_date_is_not_marked_as_an_arrival
    refute_includes render(SAMPLE_DETAIL.merge('next_delivery_prefix' => 'Next delivery')), 'arrives by'
  end

  # "none" is a setting, not a missing field: Amazon ships the backup when the
  # subscribed item is out of stock, so having none is worth stating.
  def test_no_backup_item_is_reported_rather_than_omitted
    assert_includes render(SAMPLE_DETAIL), 'backup item      none'
  end

  def test_a_backup_item_is_named
    assert_includes render(SAMPLE_DETAIL.merge('backup_item' => 'Example Alternative')), 'Example Alternative'
  end

  def test_json_is_the_record_verbatim
    out, = capture_io_streams { fmt(json: true).subscription(SAMPLE_DETAIL) }
    assert_equal SAMPLE_DETAIL, JSON.parse(out)
  end

  def test_a_variation_prints_under_the_title
    assert_includes render(SAMPLE_DETAIL.merge('variation' => 'Size: 75oz')), 'Size: 75oz'
  end

  # Every optional field absent at once: a rotted modal should print a short
  # record, not raise.
  def test_a_record_with_almost_nothing_in_it_still_renders
    out = render({ 'subscription_id' => 'SNSD0_X' })
    assert_includes out, '(untitled subscription)'
    assert_includes out, 'SNSD0_X'
  end

  def test_a_record_with_no_id_omits_the_id_line_rather_than_printing_a_blank
    out = render({ 'title' => 'Example' })
    refute_includes out, 'subscription id'
  end
end

class SubscribeWorkerProtocolTest < Minitest::Test
  def worker(**kw) = Amazon::Worker.new(**kw)

  def test_subscription_events_are_collected_with_the_total
    # Single-quoted heredoc: `#{req['all']}` has to reach the child as source,
    # not be interpolated here.
    body = <<~'SCRIPT'
      req = JSON.parse(STDIN.gets)
      puts({event: 'log', level: 'info', msg: "all=#{req['all']}"}.to_json)
      puts({event: 'subscription', data: { 'subscription_id' => 'SNSD0_1' }}.to_json)
      puts({event: 'subscription', data: { 'subscription_id' => 'SNSD0_2' }}.to_json)
      puts({event: 'done', count: 2, total: 59}.to_json)
    SCRIPT
    with_python_cmd(body) do
      w = worker(verbose: true)
      rows = nil
      _, err = capture_io_streams { rows = w.subscriptions(all: true) }
      assert_equal %w[SNSD0_1 SNSD0_2], rows.map { |r| r['subscription_id'] }
      # Two rows out of a claimed 59: the gap is the whole reason `done`
      # carries a total the rows can't supply.
      assert_equal 59, w.subscription_total
      assert_includes err, 'all=true'
    end
  end

  # The total is per-run state, and a second call that finds fewer must not
  # inherit the first call's number — that is how "30 of 59" gets printed under
  # a complete list of 12.
  def test_the_total_is_reset_between_runs
    with_python_cmd(<<~SCRIPT) do
      STDIN.gets
      puts({event: 'subscription', data: { 'subscription_id' => 'SNSD0_1' }}.to_json)
      puts({event: 'done', count: 1, total: 59}.to_json)
    SCRIPT
      w = worker
      capture_io_streams { w.subscriptions }
      assert_equal 59, w.subscription_total
    end

    with_python_cmd(<<~SCRIPT) do
      STDIN.gets
      puts({event: 'done', count: 0}.to_json)
    SCRIPT
      w = worker
      capture_io_streams { w.subscriptions }
      capture_io_streams { w.subscriptions }
      assert_nil w.subscription_total
    end
  end

  def test_a_subscription_warning_reaches_stderr_without_verbose
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'log', level: 'warn', msg: 'every subscription came back with no title'}.to_json)
      puts({event: 'done', count: 0}.to_json)
    SCRIPT
    with_python_cmd(body) do
      _, err = capture_io_streams { worker.subscriptions }
      assert_includes err, '[worker:warn] every subscription came back with no title'
    end
  end

  def test_an_expired_session_keeps_the_workers_own_wording
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'error', msg: 'the saved session has expired. Run: amazon login', kind: 'not_logged_in'}.to_json)
    SCRIPT
    with_python_cmd(body) do
      err = assert_raises(Amazon::Worker::Error) { capture_io_streams { worker.subscriptions } }
      assert_includes err.message, 'Run: amazon login'
      refute_includes err.message, 'live lookup failed'
    end
  end

  def test_delivery_events_are_collected
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'log', level: 'warn', msg: 'no future-deliveries URL'}.to_json)
      puts({event: 'delivery', data: { 'date' => '2026-09-02' }}.to_json)
      puts({event: 'done', count: 1}.to_json)
    SCRIPT
    with_python_cmd(body) do
      cards = nil
      _, err = capture_io_streams { cards = worker.deliveries }
      assert_equal ['2026-09-02'], cards.map { |c| c['date'] }
      assert_includes err, 'no future-deliveries URL'
    end
  end

  def test_a_delivery_failure_is_raised_with_the_prefix_that_names_it_as_ours
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'error', msg: "RuntimeError: Amazon's page state has changed shape"}.to_json)
    SCRIPT
    with_python_cmd(body) do
      err = assert_raises(Amazon::Worker::Error) { capture_io_streams { worker.deliveries } }
      assert_includes err.message, 'live lookup failed'
    end
  end

  # An id and a search term go to different request keys, because a title
  # search for "SNSD0_…" would match nothing and a lookup of "dishwasher" is
  # not an id.
  def test_an_id_and_a_search_term_reach_the_worker_differently
    body = <<~'SCRIPT'
      req = JSON.parse(STDIN.gets)
      puts({event: 'log', level: 'warn', msg: 'the modal rendered no seller'}.to_json)
      puts({event: 'detail', data: { 'keys' => req.keys.sort }}.to_json)
      puts({event: 'done', count: 1}.to_json)
    SCRIPT
    with_python_cmd(body) do
      detail = nil
      _, err = capture_io_streams { detail = worker.subscription('SNSD0_ABC') }
      assert_includes detail['keys'], 'subscription_id'
      assert_includes err, '[worker:warn] the modal rendered no seller'

      capture_io_streams { detail = worker.subscription('dishwasher') }
      assert_includes detail['keys'], 'query'
    end
  end

  # "Nothing matched" is a user error with an explanation attached; raising
  # Worker::Error would turn it into "live lookup failed", which is a different
  # and untrue statement.
  def test_a_not_found_is_reported_not_raised
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'error', msg: "no active subscription matching 'zzz'.", kind: 'not_found'}.to_json)
    SCRIPT
    with_python_cmd(body) do
      w = worker
      detail = nil
      capture_io_streams { detail = w.subscription('zzz') }
      assert_nil detail
      assert_includes w.not_found, "no active subscription matching 'zzz'"
    end
  end

  def test_a_real_failure_during_show_still_raises
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'error', msg: 'Timeout: navigating to the modal'}.to_json)
    SCRIPT
    with_python_cmd(body) do
      assert_raises(Amazon::Worker::Error) { capture_io_streams { worker.subscription('zzz') } }
    end
  end

  # The confirm flag has to survive the trip, because it is the entire
  # difference between reading a dialog and agreeing to it.
  def test_skip_sends_the_target_and_whether_to_confirm
    body = <<~'SCRIPT'
      req = JSON.parse(STDIN.gets)
      puts({event: 'log', level: 'warn', msg: 'the dialog rendered no warning'}.to_json)
      puts({event: 'skip', data: req}.to_json)
      puts({event: 'done', count: 1}.to_json)
    SCRIPT
    with_python_cmd(body) do
      result = nil
      _, err = capture_io_streams { result = worker.skip('SNSD0_ABC', confirm: true) }
      assert_equal 'SNSD0_ABC', result['subscription_id']
      assert result['confirm']
      assert_includes err, '[worker:warn] the dialog rendered no warning'

      capture_io_streams { result = worker.skip('dishwasher', confirm: false) }
      assert_equal 'dishwasher', result['query']
      refute result['confirm']
    end
  end

  # "Nothing in that delivery can be skipped" is a fact about the account, not
  # a scraper failure — it reads back to the user in Amazon's terms and exits
  # like a refusal rather than a crash.
  def test_a_delivery_with_nothing_skippable_is_reported_not_raised
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'error', msg: 'nothing in the next delivery can be skipped', kind: 'not_skippable'}.to_json)
    SCRIPT
    with_python_cmd(body) do
      w = worker
      result = nil
      capture_io_streams { result = w.skip('dishwasher', confirm: true) }
      assert_nil result
      assert_includes w.not_found, 'nothing in the next delivery can be skipped'
    end
  end

  # The reason is a separate field from the target, and a cancellation sent
  # with the wrong one attached cannot be taken back.
  def test_cancel_sends_the_target_the_confirm_flag_and_the_reason
    body = <<~'SCRIPT'
      req = JSON.parse(STDIN.gets)
      puts({event: 'cancel', data: req}.to_json)
      puts({event: 'done', count: 1}.to_json)
    SCRIPT
    with_python_cmd(body) do
      result = nil
      capture_io_streams { result = worker.cancel('SNSD0_ABC', confirm: true, reason: 'accident') }
      assert_equal 'SNSD0_ABC', result['subscription_id']
      assert_equal 'accident', result['reason']
      assert result['confirm']

      capture_io_streams { result = worker.cancel('dishwasher', confirm: false) }
      assert_equal 'dishwasher', result['query']
      assert_nil result['reason']
    end
  end

  # A reason Amazon doesn't offer, and a subscription that has no cancel form,
  # are both facts about the account rather than scraper failures.
  def test_a_refused_cancellation_is_reported_not_raised
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'error', msg: "unknown cancellation reason 'cats'", kind: 'not_cancellable'}.to_json)
    SCRIPT
    with_python_cmd(body) do
      w = worker
      result = nil
      capture_io_streams { result = w.cancel('dishwasher', confirm: true, reason: 'cats') }
      assert_nil result
      assert_includes w.not_found, 'unknown cancellation reason'
    end
  end

  def test_a_real_failure_during_cancel_still_raises
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'error', msg: 'Timeout: the cancel page never loaded'}.to_json)
    SCRIPT
    with_python_cmd(body) do
      err = assert_raises(Amazon::Worker::Error) do
        capture_io_streams { worker.cancel('dishwasher', confirm: true) }
      end
      assert_includes err.message, 'live lookup failed'
    end
  end

  def test_a_real_failure_during_skip_still_raises
    body = <<~SCRIPT
      STDIN.gets
      puts({event: 'error', msg: 'Timeout: the confirmation never appeared'}.to_json)
    SCRIPT
    with_python_cmd(body) do
      err = assert_raises(Amazon::Worker::Error) do
        capture_io_streams { worker.skip('dishwasher', confirm: true) }
      end
      assert_includes err.message, 'live lookup failed'
    end
  end
end

# --- thumbnails --------------------------------------------------------

# Stands in for a terminal without being one, so the tty-only paths are
# reachable from a test runner whose stdout is a pipe.
class FakeTTY < StringIO
  def initialize(tty: true)
    super()
    @tty = tty
  end

  def tty? = @tty
end

# Everything but the network and chafa. The two seams it replaces are the two
# that can't run in CI, and both are exercised separately below.
class FakeThumbnail < Amazon::Thumbnail
  attr_reader :fetched, :rendered

  def initialize(body: "JPEGBYTES", **kw)
    super(**kw)
    @body = body
    @fetched = []
    @rendered = []
  end

  private

  def get(url, redirects: 2)
    @fetched << url
    @body
  end

  def render(path)
    @rendered << path
    "<image #{File.basename(path)}>"
  end
end

class ThumbnailTest < Minitest::Test
  def setup
    write_config!
    Amazon::Thumbnail.command = true
    FileUtils.rm_rf(Amazon::Config.cache_dir.join("thumbs"))
  end

  def teardown = Amazon::Thumbnail.command = nil

  def url(size = 145) = "https://m.media-amazon.com/images/I/41ib._SS#{size}_.jpg"

  # Piping kitty graphics into a file writes megabytes of escape codes where
  # the user expected text, and there is no way to tell from the other end.
  def test_a_pipe_is_refused_with_a_reason
    t = Amazon::Thumbnail.new(rows: 6, stream: FakeTTY.new(tty: false))
    assert_match(/need a terminal/, t.unsupported_reason)
  end

  def test_a_missing_chafa_names_itself_and_how_to_get_it
    Amazon::Thumbnail.command = false
    t = Amazon::Thumbnail.new(rows: 6, stream: FakeTTY.new)
    assert_match(/chafa/, t.unsupported_reason)
    assert_match(/brew install/, t.unsupported_reason)
  end

  def test_a_terminal_with_chafa_is_supported
    assert_nil Amazon::Thumbnail.new(rows: 6, stream: FakeTTY.new).unsupported_reason
  end

  def test_the_probe_is_memoised_and_answers_from_the_real_system
    Amazon::Thumbnail.command = nil
    assert_includes [true, false], Amazon::Thumbnail.command?
    first = Amazon::Thumbnail.command?
    assert_equal first, Amazon::Thumbnail.command?
  end

  # Cells are about twice as tall as they are wide, so a thumbnail sized in
  # rows has to be twice as many columns or every product is a squashed bottle.
  def test_width_follows_from_height_unless_given
    assert_equal 12, Amazon::Thumbnail.new(rows: 6).cols
    assert_equal 5, Amazon::Thumbnail.new(rows: 6, cols: 5).cols
  end

  def test_it_downloads_renders_and_returns_the_blob
    t = FakeThumbnail.new(rows: 6, stream: FakeTTY.new)
    assert_match(/\A<image /, t.block(url))
    assert_equal 1, t.fetched.size
  end

  # Amazon serves any size from the same URL, so asking for one that matches
  # the cell block beats downloading a 500px JPEG to throw most of it away.
  def test_it_asks_amazon_for_a_size_that_fits_the_block
    t = FakeThumbnail.new(rows: 6, stream: FakeTTY.new)
    t.block(url)
    assert_includes t.fetched.first, "._SS240_."
  end

  # Only the size modifier is understood. `._CB1234_.` is a cache buster, not
  # a dimension, and rewriting it would ask for an image that doesn't exist.
  def test_a_url_with_no_size_modifier_is_fetched_as_served
    plain = "https://m.media-amazon.com/images/G/01/thing._CB1234_.png"
    t = FakeThumbnail.new(rows: 6, stream: FakeTTY.new)
    t.block(plain)
    assert_equal plain, t.fetched.first
  end

  def test_the_second_ask_for_one_url_does_not_download_it_twice
    t = FakeThumbnail.new(rows: 6, stream: FakeTTY.new)
    2.times { t.block(url) }
    assert_equal 1, t.fetched.size
  end

  # The disk cache is what makes the second `subscribe list --image` instant.
  def test_a_later_process_reads_the_image_off_disk
    FakeThumbnail.new(rows: 6, stream: FakeTTY.new).block(url)
    fresh = FakeThumbnail.new(rows: 6, stream: FakeTTY.new)
    assert fresh.block(url)
    assert_empty fresh.fetched
  end

  # Same product, two sizes, two files: `show` asks for a 12-row image and
  # `list` for a 6-row one, and serving one from the other's cache entry means
  # a blurry thumbnail or a wasted download.
  def test_two_sizes_are_two_cache_entries
    FakeThumbnail.new(rows: 6, stream: FakeTTY.new).block(url)
    big = FakeThumbnail.new(rows: 12, stream: FakeTTY.new)
    big.block(url)
    assert_includes big.fetched.first, "._SS480_."
  end

  # Amazon's "no image available" graphic. Six rows and a download to draw a
  # grey rectangle that says nothing.
  def test_amazons_no_image_graphic_is_not_drawn
    t = FakeThumbnail.new(rows: 6, stream: FakeTTY.new)
    assert_nil t.block("https://m.media-amazon.com/images/G/01/x-locale/subscriptions/no-img._CB44_.png")
    assert_empty t.fetched
  end

  def test_a_missing_url_is_not_an_error
    t = FakeThumbnail.new(rows: 6, stream: FakeTTY.new)
    assert_nil t.block(nil)
    assert_nil t.block("")
  end

  # A thumbnail is decoration. A CDN timeout must not take down the listing.
  def test_a_download_that_returns_nothing_yields_no_image
    t = FakeThumbnail.new(rows: 6, body: nil, stream: FakeTTY.new)
    assert_nil t.block(url)
    t = FakeThumbnail.new(rows: 6, body: "", stream: FakeTTY.new)
    assert_nil t.block(url)
  end

  def test_prefetch_warms_the_cache_for_every_url
    t = FakeThumbnail.new(rows: 6, stream: FakeTTY.new)
    urls = (1..5).map { |i| url(100 + i) }
    t.prefetch(urls + urls)
    assert_equal 5, t.fetched.size
    urls.each { |u| assert t.block(u) }
    assert_equal 5, t.fetched.size, "block() should not re-download what prefetch fetched"
  end

  def test_prefetch_skips_the_placeholders_and_the_blanks
    t = FakeThumbnail.new(rows: 6, stream: FakeTTY.new)
    t.prefetch([nil, "", "https://m.media-amazon.com/images/G/01/no-img._CB1_.png"])
    assert_empty t.fetched
  end

  def test_prefetch_of_nothing_starts_no_threads
    t = FakeThumbnail.new(rows: 6, stream: FakeTTY.new)
    t.prefetch([])
    assert_empty t.fetched
  end

  # Image URLs come out of scraped HTML, so the fetcher is reachable by anything
  # Amazon (or an injected page) puts in a src attribute. It speaks HTTP only.
  def test_a_non_http_url_is_refused
    t = Amazon::Thumbnail.new(rows: 6, stream: FakeTTY.new)
    assert_nil t.send(:get, "file:///etc/passwd")
    assert_nil t.send(:get, "not a url at all")
  end

  def test_the_render_command_asks_chafa_for_the_exact_block
    t = Amazon::Thumbnail.new(rows: 6, stream: FakeTTY.new)
    assert_equal ["chafa", "--size=12x6", "/tmp/x.img"], t.send(:render_command, "/tmp/x.img")
  end

  def renderer(argv)
    Class.new(Amazon::Thumbnail) do
      define_method(:render_command) { |_path| argv }
    end.new(rows: 6, stream: FakeTTY.new)
  end

  def test_a_renderer_that_succeeds_returns_its_output
    assert_equal "IMG", renderer(["printf", "IMG"]).send(:render, "/tmp/whatever")
  end

  # chafa exits non-zero on a file it can't decode. A truncated download is a
  # missing thumbnail, not a dead listing.
  def test_a_renderer_that_exits_non_zero_produces_no_image
    assert_nil renderer(["false"]).send(:render, "/tmp/whatever")
  end

  # And a renderer that isn't installed at all raises rather than exiting,
  # which is a different path to the same nil.
  def test_a_renderer_that_is_not_installed_produces_no_image
    assert_nil renderer(["/nonexistent/not-a-real-binary"]).send(:render, "/tmp/x")
  end

  # Every process shares one cache directory; an unwritable one is a slow
  # listing, not a failed one.
  def test_a_cache_it_cannot_write_produces_no_image
    t = Class.new(FakeThumbnail) do
      define_method(:cache_path) { |_url| Pathname.new("/dev/null/nope/x.img") }
    end.new(rows: 6, stream: FakeTTY.new)
    assert_nil t.block("https://m.media-amazon.com/images/I/41ib._SS145_.jpg")
  end
end

# Reports what it was asked to draw and returns a marker instead of an escape
# blob, so the layout around the image is readable in an assertion.
class StubThumbnails
  attr_reader :asked, :prefetched

  def initialize(rows: 6, cols: 12, blob: "<IMG>")
    @rows = rows
    @cols = cols
    @blob = blob
    @asked = []
    @prefetched = []
  end

  attr_reader :rows, :cols

  def prefetch(urls) = @prefetched.concat(urls)

  def block(url)
    @asked << url
    url.nil? ? nil : @blob
  end
end

class ThumbnailLayoutTest < Minitest::Test
  def fmt = Amazon::Formatter.new(json: false, color: false)

  def render(rows, thumbs)
    out, = capture_io_streams { fmt.subscriptions(rows, total: nil, thumbnails: thumbs) }
    out
  end

  def test_the_table_gives_way_to_one_block_per_subscription
    out = render([SAMPLE_SUBSCRIPTION], StubThumbnails.new)
    refute_includes out, "subscription_id  item"
    assert_includes out, SAMPLE_SUBSCRIPTION["title"]
    assert_includes out, "<IMG>"
  end

  def test_every_text_line_clears_the_image
    out = render([SAMPLE_SUBSCRIPTION], StubThumbnails.new(cols: 12))
    body = out.lines.map { |l| l.gsub(/\e\[[0-9?]*[a-zA-Z]/, "") }
                    .reject { |l| l.strip.empty? || l.include?("<IMG>") }
    refute_empty body
    body.each { |l| assert l.start_with?(" " * 14), "text ran into the image: #{l.inspect}" }
  end

  # The block has to be exactly as tall as the arithmetic that moves the cursor
  # back over it, or the next photograph lands in this one's caption.
  def test_the_cursor_goes_back_up_by_the_height_of_the_block
    out = render([SAMPLE_SUBSCRIPTION], StubThumbnails.new(rows: 6))
    up = out[/\e\[(\d+)A/, 1]
    printed = out.split("\e7").first.lines.size
    assert_equal printed, up.to_i
  end

  # Four lines of text against a six-row image still has to be a six-row block:
  # short entries that print four lines would walk the images up the screen.
  def test_a_short_entry_is_padded_to_the_image_height
    out = render([SAMPLE_SUBSCRIPTION], StubThumbnails.new(rows: 9))
    assert_equal 9, out[/\e\[(\d+)A/, 1].to_i
  end

  # And an entry with more to say than the image is tall must not be clipped.
  def test_a_tall_entry_keeps_all_its_lines
    row = SAMPLE_SUBSCRIPTION.merge("variation" => "Size: 75oz")
    out = render([row], StubThumbnails.new(rows: 2))
    assert_includes out, "Size: 75oz"
    assert_equal 4, out[/\e\[(\d+)A/, 1].to_i
  end

  # chafa fits the photo within the box rather than filling it, so a wide
  # product shot is three rows tall in a six-row block. Counting rows back down
  # would land three rows high; the saved position doesn't care.
  def test_the_cursor_is_restored_rather_than_counted_back_down
    out = render([SAMPLE_SUBSCRIPTION], StubThumbnails.new)
    assert_includes out, "\e7"
    assert_includes out, "\e8"
    refute_match(/\e\[\d+B/, out)
  end

  # "Clorox®" is six characters to Ruby and seven cells to the terminal, so a
  # line this side thinks fits can wrap — and a wrapped line makes the block
  # taller than the cursor arithmetic believes.
  def test_wrapping_is_disabled_across_the_block_and_restored_after
    out = render([SAMPLE_SUBSCRIPTION], StubThumbnails.new)
    assert_includes out, "\e[?7l"
    assert_includes out, "\e[?7h"
    assert_operator out.index("\e[?7l"), :<, out.index("\e[?7h")
  end

  # Ctrl-C halfway down a 59-entry listing must not leave the shell it returns
  # to without line wrapping.
  def test_wrapping_is_restored_when_the_block_is_interrupted
    boom = Object.new
    def boom.empty? = raise(Interrupt)
    out, = capture_io_streams do
      assert_raises(Interrupt) { fmt.send(:beside_image, "<IMG>", [boom], StubThumbnails.new) }
    end
    assert_includes out, "\e[?7h"
  end

  # A subscription with no usable photo still has to hold its column, or the
  # entries below it read as a different list.
  def test_a_missing_image_leaves_the_gap_and_keeps_the_text_aligned
    rows = [SAMPLE_SUBSCRIPTION.merge("image" => nil), SAMPLE_SUBSCRIPTION]
    out = render(rows, StubThumbnails.new)
    titled = out.lines.select { |l| l.include?("Example Dishwasher") }
    assert_equal 2, titled.size
    assert_equal 1, titled.map { |l| l.index("Example") }.uniq.size
  end

  def test_the_photos_are_all_fetched_before_the_first_one_is_drawn
    thumbs = StubThumbnails.new
    render([SAMPLE_SUBSCRIPTION, SAMPLE_SUBSCRIPTION.merge("image" => "b.jpg")], thumbs)
    assert_equal [SAMPLE_SUBSCRIPTION["image"], "b.jpg"], thumbs.prefetched
  end

  def test_the_count_note_still_prints_under_the_blocks
    out = render([SAMPLE_SUBSCRIPTION], StubThumbnails.new)
    out2, = capture_io_streams do
      fmt.subscriptions([SAMPLE_SUBSCRIPTION], total: 59, thumbnails: StubThumbnails.new)
    end
    refute_includes out, "showing"
    assert_includes out2, "showing 1 of 59"
  end

  # The columns become a sentence, and it has to carry what the columns did.
  def test_the_summary_line_carries_date_cadence_and_price
    out = render([SAMPLE_SUBSCRIPTION], StubThumbnails.new)
    assert_includes out, "September 30"
    assert_includes out, "every 1 month"
    assert_includes out, "$14.22"
  end

  def test_a_quantity_of_one_is_not_worth_a_word
    out = render([SAMPLE_SUBSCRIPTION], StubThumbnails.new)
    refute_includes out, "qty"
    out = render([SAMPLE_SUBSCRIPTION.merge("quantity" => 3)], StubThumbnails.new)
    assert_includes out, "qty 3"
  end

  def test_an_unpriced_row_shows_its_rate_and_no_dollar_sign
    row = SAMPLE_SUBSCRIPTION.merge("price" => nil, "discount" => "Saving 15%")
    out = render([row], StubThumbnails.new)
    assert_includes out, "15%"
    refute_includes out, "$"
  end

  def test_a_row_with_no_price_at_all_drops_the_separator_too
    row = SAMPLE_SUBSCRIPTION.merge("price" => nil, "discount" => nil)
    out = render([row], StubThumbnails.new)
    assert_includes out, "every 1 month"
    refute_includes out, "every 1 month ·"
  end

  def test_show_puts_the_detail_block_beside_the_photo
    thumbs = StubThumbnails.new(rows: 12, cols: 24)
    out, = capture_io_streams { fmt.subscription(SAMPLE_DETAIL, thumbnails: thumbs) }
    assert_includes out, "<IMG>"
    assert_equal [SAMPLE_DETAIL["image"]], thumbs.prefetched
    assert_includes out, "#{" " * 28}asin"
  end

  # The title is the heading of this view; only its fields are indented under
  # it. Adding a picture must not shift the layout of the version without one.
  def test_show_without_a_thumbnail_is_unchanged
    out, = capture_io_streams { fmt.subscription(SAMPLE_DETAIL) }
    refute_includes out, "\e7"
    assert out.lines.first.start_with?("Example Dishwasher"), out.lines.first.inspect
    assert_includes out, "  asin"
  end
end

class SubscribeImageFlagTest < Minitest::Test
  def setup
    write_config!
    reset_subscribe_cache!
    Amazon::Thumbnail.command = true
  end

  def teardown = Amazon::Thumbnail.command = nil

  def run_cli(argv)
    with_worker(->(*) { FakeSubscribeWorker.new }) { capture_io_streams { Amazon::CLI.run(argv) } }
  end

  # The test runner's stdout is a pipe, which is exactly the case that has to
  # degrade rather than fill the terminal with escape codes.
  def test_a_pipe_gets_a_warning_and_the_plain_table
    out, err = run_cli(%w[subscribe list --image])
    assert_includes err, "images need a terminal"
    assert_includes out, "subscription_id"
    refute_includes out, "\e[?7l"
  end

  # Photos are the default, so the pipe case is now the common case. Explaining
  # it every time would make every `| grep` apologise for a thing nobody asked
  # for — the warning belongs to the flag, not to the feature.
  def test_a_pipe_says_nothing_when_the_flag_was_not_typed
    out, err = run_cli(%w[subscribe list])
    refute_includes err, "images need a terminal"
    refute_includes err, "chafa"
    assert_includes out, "subscription_id"
  end

  def test_no_image_is_accepted_everywhere_in_both_spellings
    %w[--no-image --no-images].each do |flag|
      %w[list upcoming show].each do |sub|
        reset_subscribe_cache!
        argv = sub == "show" ? ["subscribe", sub, "dishwasher", flag] : ["subscribe", sub, flag]
        out, err = run_cli(argv)
        refute_includes err, "unknown"
        refute_empty out
      end
    end
  end

  # Declining is silent by definition: you already know why there are no
  # pictures, because you said so.
  def test_no_image_never_explains_itself
    cmd = Amazon::Commands::Subscribe::List.new(
      Amazon::GlobalOptions.new(json: false, quiet: false, verbose: false)
    )
    Amazon::Thumbnail.command = false
    _, err = capture_io_streams { assert_nil cmd.send(:thumbnails, false, 6) }
    assert_empty err
  end

  def test_show_degrades_to_plain_text_with_one_line_of_explanation
    Amazon::Thumbnail.command = false
    out, err = run_cli(%w[subscribe show dishwasher --image])
    assert_equal 1, err.lines.size
    assert_includes out, "asin"
    refute_includes out, "\e7"
  end

  # A picture is not data, and neither is the escape sequence that draws one.
  def test_json_is_never_decorated
    out, err = run_cli(%w[--json subscribe list --image])
    assert_equal [SAMPLE_SUBSCRIPTION], JSON.parse(out)
    refute_includes err, "terminal"
  end

  def test_both_spellings_are_accepted
    %w[--image --images].each do |flag|
      reset_subscribe_cache!
      _, err = run_cli(["subscribe", "list", flag])
      assert_includes err, "images need a terminal"
    end
  end

  def test_the_flag_is_documented_where_it_works
    %w[list show upcoming].each do |sub|
      out, = capture_io_streams { Amazon::CLI.run(["subscribe", sub, "--help"]) }
      assert_includes out, "--no-image"
    end
  end

  def test_upcoming_takes_it_too
    _, err = run_cli(%w[subscribe upcoming --image])
    assert_includes err, "images need a terminal"
  end

  # The renderer is handed to the formatter only when it can actually draw —
  # which needs a terminal, so this one hands the command a stdout that says
  # it is one. nil is the no-flag case, and it has to behave like --image.
  def test_a_working_terminal_gets_a_renderer_without_being_asked
    cmd = Amazon::Commands::Subscribe::List.new(
      Amazon::GlobalOptions.new(json: false, quiet: false, verbose: false)
    )
    real = $stdout
    $stdout = FakeTTY.new
    begin
      refute_nil cmd.send(:thumbnails, nil, 6)
      refute_nil cmd.send(:thumbnails, true, 6)
      assert_nil cmd.send(:thumbnails, false, 6)
    ensure
      $stdout = real
    end
  end
end

# The image fetcher is the only part of this CLI that talks to a server other
# than through the Python worker, so its redirect and failure handling is
# tested against a real socket rather than a stub of Net::HTTP.
class TinyHTTP
  attr_reader :port, :paths

  def initialize(&handler)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @paths = []
    @handler = handler
    @thread = Thread.new { serve }
  end

  def url(path) = "http://127.0.0.1:#{@port}#{path}"

  def stop
    @thread.kill
    @server.close
  rescue IOError
    nil
  end

  private

  def serve
    loop do
      sock = @server.accept
      path = sock.gets.to_s.split(" ")[1]
      nil while sock.gets&.strip&.!= ""
      @paths << path
      status, headers, body = @handler.call(path)
      sock.print "HTTP/1.1 #{status}\r\n"
      headers.each { |k, v| sock.print "#{k}: #{v}\r\n" }
      sock.print "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
      sock.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    nil
  end
end

class ThumbnailFetchTest < Minitest::Test
  def setup
    write_config!
    @fetcher = Amazon::Thumbnail.new(rows: 6, stream: FakeTTY.new)
  end

  def with_server
    server = TinyHTTP.new { |path| handler(path) }
    yield server
  ensure
    server&.stop
  end

  def test_it_returns_the_body
    body = with_server { |s| @fetcher.send(:get, s.url("/a.jpg")) }
    assert_equal "IMAGEBYTES", body
  end

  # Amazon's image hosts redirect, and a thumbnail that gives up at the first
  # 302 is a blank margin on every row. The Location header here is relative,
  # which is legal and is what breaks a fetcher that treats it as a whole URL.
  def test_it_follows_a_relative_redirect
    with_server do |s|
      assert_equal "IMAGEBYTES", @fetcher.send(:get, s.url("/start.jpg"))
      assert_equal ["/start.jpg", "/final.jpg"], s.paths
    end
  end

  def test_a_redirect_with_nowhere_to_go_is_not_followed
    with_server { |s| assert_nil @fetcher.send(:get, s.url("/nowhere.jpg")) }
  end

  # A redirect loop is a hang, and this runs 59 times in a row.
  def test_a_redirect_loop_gives_up
    with_server do |s|
      assert_nil @fetcher.send(:get, s.url("/loop.jpg"))
      assert_operator s.paths.size, :<=, 4, "followed too many redirects"
    end
  end

  def test_a_404_is_not_an_image
    with_server { |s| assert_nil @fetcher.send(:get, s.url("/missing.jpg")) }
  end

  # Nothing about an unreachable CDN should take down a subscription listing.
  def test_a_refused_connection_is_survivable
    server = TinyHTTP.new { ["200 OK", {}, "x"] }
    url = server.url("/a.jpg")
    server.stop
    assert_nil @fetcher.send(:get, url)
  end

  def handler(path)
    case path
    when "/start.jpg" then ["302 Found", { "Location" => "/final.jpg" }, ""]
    when "/loop.jpg" then ["302 Found", { "Location" => "/loop.jpg" }, ""]
    when "/nowhere.jpg" then ["302 Found", {}, ""]
    when "/missing.jpg" then ["404 Not Found", {}, "no"]
    else ["200 OK", { "Content-Type" => "image/jpeg" }, "IMAGEBYTES"]
    end
  end
end

class DeliveryThumbnailLayoutTest < Minitest::Test
  def fmt = Amazon::Formatter.new(json: false, color: false)

  def render(cards, thumbs, **kw)
    out, = capture_io_streams { fmt.deliveries(cards, thumbnails: thumbs, **kw) }
    out
  end

  def test_each_item_becomes_a_block_under_its_delivery_heading
    out = render([SAMPLE_DELIVERY], StubThumbnails.new(rows: 4, cols: 8))
    assert_includes out, "Sep 2"
    assert_includes out, "Last day to edit delivery:"
    assert_includes out, "Example Laundry Detergent"
    assert_includes out, "<IMG>"
  end

  # A price column indented past a photograph is a column of one, so the price
  # moves off the front of the line and onto its own.
  def test_the_price_moves_onto_its_own_line
    out = render([SAMPLE_DELIVERY], StubThumbnails.new(rows: 4, cols: 8))
    # The heading carries the delivery subtotal, which is the same number; the
    # item's copy is the indented one.
    priced = out.lines.select { |l| l.include?("$14.22") && l.start_with?(" " * 10) }
    assert_equal 1, priced.size, out.inspect
    refute_includes priced.first, "Example Laundry Detergent"
    assert_includes priced.first, "Saving 5%"
  end

  # Not everything in a box is discounted — a subscription can sit at 0% and
  # still ship in the delivery.
  def test_a_priced_item_with_no_discount_prints_just_the_price
    card = SAMPLE_DELIVERY.dup
    card["items"] = [SAMPLE_DELIVERY["items"].first.merge("discount" => nil, "price" => 11.99)]
    out = render([card], StubThumbnails.new(rows: 4, cols: 8))
    assert_includes out, "$11.99"
    refute_includes out, "Saving"
  end

  # A future delivery is unpriced. Its rate is the only number Amazon has
  # committed to, and $0.00 would say the box is free.
  def test_an_unpriced_item_shows_its_rate_alone
    card = FUTURE_DELIVERY.dup
    card["items"] = [FUTURE_DELIVERY["items"].first.merge("discount" => "Saving 15%")]
    out = render([card], StubThumbnails.new(rows: 4, cols: 8))
    assert_includes out, "Saving 15%"
    refute_includes out, "$"
  end

  # Neither a price nor a rate is a blank line in the middle of a block, so the
  # line is dropped instead.
  def test_an_item_with_no_money_at_all_drops_the_line
    out = render([FUTURE_DELIVERY], StubThumbnails.new(rows: 4, cols: 8))
    assert_includes out, "Example Paper Towels"
    refute_match(/^\s+$\n\s+$\n\s+$\n\s+$/, out)
  end

  def test_a_variation_prints_under_the_title
    card = SAMPLE_DELIVERY.dup
    card["items"] = [SAMPLE_DELIVERY["items"].first.merge("variation" => "Size: 132 Fl Oz")]
    out = render([card], StubThumbnails.new(rows: 4, cols: 8))
    assert_includes out, "Size: 132 Fl Oz"
  end

  # One warm-up for the whole screen: the downloads are the slow part and they
  # don't depend on each other. Two deliveries must not mean two round trips.
  def test_every_photo_on_screen_is_fetched_in_one_go
    thumbs = StubThumbnails.new(rows: 4, cols: 8)
    render([SAMPLE_DELIVERY, FUTURE_DELIVERY], thumbs)
    assert_equal 2, thumbs.prefetched.compact.size
  end

  # --limit is what makes this bearable with photos; it must also stop the
  # downloads, not just the drawing.
  def test_a_hidden_delivery_costs_no_downloads
    thumbs = StubThumbnails.new(rows: 4, cols: 8)
    render([SAMPLE_DELIVERY, FUTURE_DELIVERY], thumbs, limit: 1)
    assert_equal 1, thumbs.prefetched.compact.size
    assert_includes render([SAMPLE_DELIVERY, FUTURE_DELIVERY], thumbs, limit: 1), "1 more delivery"
  end

  def test_a_card_with_no_items_still_prints_its_heading
    out = render([SAMPLE_DELIVERY.merge("items" => nil)], StubThumbnails.new(rows: 4, cols: 8))
    assert_includes out, "Sep 2"
    assert_includes out, "0 items"
  end

  def test_without_thumbnails_the_item_lines_are_unchanged
    out, = capture_io_streams { fmt.deliveries([SAMPLE_DELIVERY]) }
    assert_match(/^\s+\$14\.22\s+Example Laundry Detergent/, out)
    refute_includes out, "\e7"
  end
end

# The password reaches the browser worker over a pipe and is never written
# anywhere. These tests run a fake worker that echoes its stdin back, which is
# the only way to prove what was sent without reading a real Chrome window.
class LoginCredentialsTest < Minitest::Test
  ECHO = <<~'SCRIPT'
    line = $stdin.gets
    puts({ event: 'log', msg: "stdin=#{line.to_s.strip}" }.to_json)
    puts({ event: 'done', count: 1, cookies_path: '/tmp/cookies.json' }.to_json)
  SCRIPT

  def login = Amazon::Commands::Login.new(Amazon::GlobalOptions.new(json: false, quiet: false, verbose: false))

  def run_login(argv = [], refs: {}, secrets: {})
    write_config!(refs)
    with_secrets(secrets) do
      with_login_python(ECHO) { capture_io_streams { login.run(argv) } }
    end
  end

  def sent(err)
    line = err.lines.find { |l| l.include?("stdin=") }
    JSON.parse(line.split("stdin=", 2).last.strip)
  end

  def test_the_password_and_otp_are_handed_to_the_worker
    _, err = run_login(
      refs: { 'password_op_ref' => 'op://Personal/Amazon/password', 'otp_op_ref' => 'op://Personal/Amazon/otp' },
      secrets: { 'op://Personal/Amazon/password' => 'hunter2',
                 'op://Personal/Amazon/otp' => 'otpauth://totp/Amazon?secret=JBSWY3DPEHPK3PXP' }
    )
    assert_equal({ 'password' => 'hunter2', 'otp_secret' => 'otpauth://totp/Amazon?secret=JBSWY3DPEHPK3PXP' },
                 sent(err))
  end

  # The OTP is optional; a config with only a password must not send a null and
  # must not read a ref that isn't there.
  def test_a_missing_otp_ref_is_simply_absent
    _, err = run_login(
      refs: { 'password_op_ref' => 'op://Personal/Amazon/password' },
      secrets: { 'op://Personal/Amazon/password' => 'hunter2' }
    )
    assert_equal({ 'password' => 'hunter2' }, sent(err))
  end

  # Every failure here is recoverable by a human with a keyboard, so none of
  # them may stop the login.
  def test_a_1password_failure_warns_and_carries_on
    _, err = run_login(
      refs: { 'password_op_ref' => 'op://Personal/Amazon/password' },
      secrets: {}
    )
    assert_includes err, 'no credentials from 1Password'
    assert_includes err, 'sign in by hand'
    assert_includes err, 'saved 1 cookies'
    assert_equal 'stdin=', err.lines.find { |l| l.include?('stdin=') }.strip
  end

  def test_no_ref_in_config_means_nothing_is_sent
    _, err = run_login
    assert_equal 'stdin=', err.lines.find { |l| l.include?('stdin=') }.strip
    refute_includes err, '1Password'
  end

  # --manual is for when you'd rather type it, and it must not touch `op` at
  # all — reading the ref is what triggers the fingerprint prompt.
  def test_manual_skips_1password_entirely
    write_config!('password_op_ref' => 'op://Personal/Amazon/password')
    asked = []
    with_secrets({}) do
      Amazon::Secrets.define_singleton_method(:read) { |ref| asked << ref; 'never' }
      _, err = with_login_python(ECHO) { capture_io_streams { login.run(%w[--manual]) } }
      assert_empty asked
      assert_equal 'stdin=', err.lines.find { |l| l.include?('stdin=') }.strip
    end
  end

  # No config file means autofill was never on offer, so there is nothing to
  # apologise for — the window opens and you type, exactly as before.
  def test_a_missing_config_is_neither_fatal_nor_worth_mentioning
    FileUtils.rm_f(Amazon::Config.config_path)
    with_secrets({}) do
      _, err = with_login_python(ECHO) { capture_io_streams { assert_equal 0, login.run([]) } }
      refute_includes err, '1Password'
      assert_equal 'stdin=', err.lines.find { |l| l.include?('stdin=') }.strip
    end
  end

  # A worker that exits before reading leaves us writing into a closed pipe.
  # That is its stderr's story to tell, not an EPIPE traceback's.
  def test_a_worker_that_never_reads_stdin_does_not_crash_the_cli
    write_config!('password_op_ref' => 'op://Personal/Amazon/password')
    body = <<~'SCRIPT'
      puts({ event: 'error', msg: 'playwright not installed' }.to_json)
      exit 2
    SCRIPT
    with_secrets({ 'op://Personal/Amazon/password' => 'hunter2' }) do
      _, err = with_login_python(body) { capture_io_streams { assert_equal 2, login.run([]) } }
      assert_includes err, 'playwright not installed'
    end
  end

  def test_an_unknown_option_is_a_usage_error
    _, err = capture_io_streams { assert_equal 2, login.run(%w[--headless]) }
    assert_includes err, 'unknown login option: --headless'
  end

  def test_the_help_explains_the_extension_less_window
    out, = capture_io_streams { assert_equal 0, login.run(%w[--help]) }
    assert_includes out, '--manual'
    assert_includes out, 'no extensions'
  end
end

# Nothing in here may run the real `op`. An earlier draft of this file called
# Secrets.read with a live reference to see it fail, and instead of failing it
# succeeded — printing a real password into the test output. A unit test is not
# a place to find out whether your 1Password session happens to be unlocked.
class SecretsTest < Minitest::Test
  def with_capture3(out:, err:, ok:)
    original = Open3.method(:capture3)
    status = Object.new
    status.define_singleton_method(:success?) { ok }
    calls = []
    Open3.define_singleton_method(:capture3) do |*args|
      calls << args
      [out, err, status]
    end
    yield calls
  ensure
    Open3.define_singleton_method(:capture3, original)
  end

  def test_it_shell_quotes_the_reference
    assert_includes Amazon::Secrets.command('op://Personal/Amazon/password').last,
                    "op read 'op://Personal/Amazon/password'"
  end

  # `\'` in a gsub *replacement* string is $POSTMATCH, not an escaped quote, so
  # the two-arg form pasted the rest of the string in after every apostrophe.
  def test_an_apostrophe_is_quoted_and_not_duplicated
    quoted = Amazon::Secrets.command("op://it's/x").last
    assert_includes quoted, %q(op read 'op://it'\''s/x')
    refute_includes quoted, "s/xs/x"
  end

  def test_it_signs_in_before_reading
    assert_includes Amazon::Secrets.command('op://a/b').last, 'op signin --account my'
  end

  def test_a_successful_read_is_chomped
    with_capture3(out: "hunter2\n", err: '', ok: true) do |calls|
      assert_equal 'hunter2', Amazon::Secrets.read('op://Personal/Amazon/password')
      assert_equal Amazon::Secrets.command('op://Personal/Amazon/password'), calls.first
    end
  end

  # The message names the reference, never the value — this is the string that
  # ends up in a warning on someone's terminal.
  def test_a_failed_read_names_the_ref
    with_capture3(out: '', err: "authorization prompt dismissed\n", ok: false) do
      e = assert_raises(Amazon::Secrets::Error) { Amazon::Secrets.read('op://Personal/Amazon/password') }
      assert_includes e.message, 'op://Personal/Amazon/password'
      assert_includes e.message, 'authorization prompt dismissed'
    end
  end
end

class LoginPipeTest < Minitest::Test
  def login = Amazon::Commands::Login.new(Amazon::GlobalOptions.new(json: false, quiet: false, verbose: false))

  # A worker that dies before reading leaves us writing into a closed pipe.
  # Its stderr already says why; an EPIPE traceback on top would bury that.
  def test_writing_to_a_closed_pipe_is_survivable
    read_end, write_end = IO.pipe
    read_end.close
    login.send(:send_request, write_end, { password: 'hunter2' })
  end

  def test_an_empty_request_writes_nothing_and_still_closes
    read_end, write_end = IO.pipe
    login.send(:send_request, write_end, {})
    assert write_end.closed?
    assert_equal '', read_end.read
  end

  # An error with no message at all still has to produce a sentence.
  def test_a_wordless_failure_still_warns
    write_config!('password_op_ref' => 'op://Personal/Amazon/password')
    original = Amazon::Secrets.method(:read)
    Amazon::Secrets.define_singleton_method(:read) { |_ref| raise Amazon::Secrets::Error, '' }
    _, err = capture_io_streams { assert_empty login.send(:credentials) }
    assert_includes err, 'no credentials from 1Password'
  ensure
    Amazon::Secrets.define_singleton_method(:read, original)
  end

  # Events this version doesn't know about are Amazon's problem to add and
  # ours to ignore, not to print raw.
  def test_an_unknown_event_is_ignored
    body = <<~'SCRIPT'
      puts({ event: 'heartbeat', beat: 3 }.to_json)
      puts({ event: 'done', count: 1, cookies_path: '/tmp/cookies.json' }.to_json)
    SCRIPT
    with_login_python(body) do
      _, err = capture_io_streams { assert_equal 0, login.run([]) }
      refute_includes err, 'heartbeat'
      assert_includes err, 'saved 1 cookies'
    end
  end

  # No venv means the system interpreter, which is how this runs on a machine
  # that installed the deps globally.
  def test_it_falls_back_to_system_python
    original = File.method(:executable?)
    File.define_singleton_method(:executable?) { |_path| false }
    assert_equal 'python3', login.send(:python_cmd).first
  ensure
    File.define_singleton_method(:executable?, original)
  end
end

# `subscribe skip` is the first subcommand in this namespace that changes
# anything, so most of what is graded here is what it refuses to do.
class SubscribeSkipCommandTest < Minitest::Test
  def setup
    write_config!
    reset_subscribe_cache!
  end

  def worker(result = SAMPLE_SKIP)
    FakeSubscribeWorker.new.with_skip(result)
  end

  def run_skip(argv, worker = worker())
    out = err = nil
    code = with_worker(->(*) { worker }) do
      out, err = capture_io_streams { @code = Amazon::CLI.run(argv) }
      @code
    end
    [out, err, code]
  end

  def test_without_yes_it_describes_the_skip_and_does_not_do_it
    out, _err, code = run_skip(%w[subscribe skip dishwasher])
    assert_equal 2, code, 'a dry run must not look like success to a script'
    assert_includes out, 'would skip'
    assert_includes out, 'Example Dishwasher Detergent'
    assert_includes out, 'pass --yes'
  end

  # Amazon's sentence, not a paraphrase of it. "Skip" sounds free; the dialog
  # is the only thing that mentions the coupon.
  def test_the_dry_run_repeats_amazons_own_warning
    out, = run_skip(%w[subscribe skip dishwasher])
    assert_includes out, 'You may lose applied coupons'
  end

  def test_the_worker_is_told_not_to_confirm
    w = worker
    run_skip(%w[subscribe skip dishwasher], w)
    refute w.asked_confirm
  end

  def test_yes_confirms_and_reports_the_verification
    w = worker(SAMPLE_SKIP.merge('verified' => true))
    out, _err, code = run_skip(%w[subscribe skip dishwasher --yes], w)
    assert_equal 0, code
    assert w.asked_confirm
    assert_includes out, 'skipped'
    assert_includes out, "no longer in that delivery"
  end

  def test_short_yes_works_too
    w = worker(SAMPLE_SKIP.merge('verified' => true))
    _out, _err, code = run_skip(%w[subscribe skip dishwasher -y], w)
    assert_equal 0, code
    assert w.asked_confirm
  end

  # The one that matters: Amazon accepted the click and the item is still
  # there. Reporting that as a skip would be the worst bug this command can
  # have, because the box ships anyway and nobody looks again.
  def test_an_unverified_skip_says_so_loudly
    out, = run_skip(%w[subscribe skip dishwasher --yes], worker(SAMPLE_SKIP.merge('verified' => false)))
    assert_includes out, 'still in that delivery'
    refute_includes out, 'confirmed —'
  end

  def test_a_check_that_could_not_be_made_is_not_reported_as_failure
    out, = run_skip(%w[subscribe skip dishwasher --yes], worker(SAMPLE_SKIP.merge('verified' => nil)))
    assert_includes out, "couldn't re-read"
    refute_includes out, 'still in that delivery'
  end

  # Counted at the worker rather than in the cache directory: what matters is
  # that the next read goes back to Amazon, not which files exist.
  def reads_after(skip_argv)
    w = worker(SAMPLE_SKIP.merge('verified' => true))
    with_worker(->(*) { w }) do
      capture_io_streams do
        Amazon::CLI.run(%w[subscribe list])
        before = w.calls
        Amazon::CLI.run(skip_argv)
        Amazon::CLI.run(%w[subscribe list])
        return w.calls - before - 1
      end
    end
  end

  def test_a_confirmed_skip_clears_the_cache
    assert_equal 1, reads_after(%w[subscribe skip dishwasher --yes]),
                 'the list would still show a delivery date that just moved'
  end

  # A dry run changed nothing, so a cache built before it is still true.
  def test_a_dry_run_leaves_the_cache_alone
    assert_equal 0, reads_after(%w[subscribe skip dishwasher])
  end

  def test_json_is_the_whole_record
    out, = run_skip(%w[--json subscribe skip dishwasher --yes], worker(SAMPLE_SKIP.merge('verified' => true)))
    parsed = JSON.parse(out)
    assert_equal 'SNSD0_FIXTURESUB0000000001', parsed['subscription_id']
    assert parsed['confirmed']
  end

  def test_a_miss_passes_amazons_wording_through
    w = FakeSubscribeWorker.new(not_found: 'nothing in the next delivery matches "zzz"')
    _out, err, code = run_skip(%w[subscribe skip zzz], w)
    assert_equal 2, code
    assert_includes err, 'nothing in the next delivery'
  end

  def test_it_needs_something_to_skip
    _out, err, code = run_skip(%w[subscribe skip])
    assert_equal 2, code
    assert_includes err, 'usage:'
  end

  # Bulk skipping is a different command with a different confirmation. Two
  # bare words here is far more likely to be a two-word search that forgot its
  # quotes, and skipping the first match would be a wrong guess with a cost.
  def test_it_takes_one_subscription_at_a_time
    _out, err, code = run_skip(['subscribe', 'skip', 'dish', 'mop'])
    assert_equal 2, code
    assert_includes err, 'one subscription at a time'
  end

  def test_unknown_options_are_refused
    _out, err, code = run_skip(%w[subscribe skip dishwasher --force])
    assert_equal 2, code
    assert_includes err, 'unknown skip option'
  end

  def test_the_help_says_what_yes_is_for
    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[subscribe skip --help]) }
    assert_includes out, '--yes'
    assert_includes out, 'nothing is changed'
  end

  def test_the_namespace_lists_it
    out, = capture_io_streams { Amazon::CLI.run(%w[subscribe]) }
    assert_includes out, 'skip'
  end
end

# Cancelling is the one thing in this namespace that can't be undone from the
# CLI, so nearly all of this grades what it refuses to do and what it insists
# on saying first.
class SubscribeCancelCommandTest < Minitest::Test
  def setup
    write_config!
    reset_subscribe_cache!
  end

  def worker(result = SAMPLE_CANCEL)
    FakeSubscribeWorker.new.with_cancel(result)
  end

  def run_cancel(argv, worker = worker())
    out = err = nil
    code = with_worker(->(*) { worker }) do
      out, err = capture_io_streams { @code = Amazon::CLI.run(argv) }
      @code
    end
    [out, err, code]
  end

  def test_without_yes_it_describes_the_cancellation_and_does_not_do_it
    out, _err, code = run_cancel(%w[subscribe cancel dishwasher])
    assert_equal 2, code
    assert_includes out, 'would cancel'
    assert_includes out, 'Example Dishwasher Detergent'
    assert_includes out, 'pass --yes'
  end

  # The line nobody expects from a word like "cancel": the box being packed
  # right now goes too. It is Amazon's sentence and it survives verbatim.
  def test_the_dry_run_says_the_pending_order_goes_too
    out, = run_cancel(%w[subscribe cancel dishwasher])
    assert_includes out, "haven't yet entered the delivery process"
    assert_includes out, 'no longer receive your Subscribe & Save discount'
  end

  def test_it_says_what_the_subscription_has_saved_so_far
    out, = run_cancel(%w[subscribe cancel dishwasher])
    assert_includes out, '$16.92'
    # Amazon's banner is three lines of markup; a multi-line field would break
    # the block layout of everything under it.
    refute_includes out.split("$16.92").first.split("\n").last, "\n"
  end

  def test_the_dry_run_lists_the_reasons_it_would_accept
    out, = run_cancel(%w[subscribe cancel dishwasher])
    assert_includes out, 'stopped_using'
  end

  def test_yes_cancels_and_reports_the_verification
    w = worker(SAMPLE_CANCEL.merge('verified' => true))
    out, _err, code = run_cancel(%w[subscribe cancel dishwasher --yes], w)
    assert_equal 0, code
    assert w.asked_confirm
    assert_includes out, 'cancelled'
    assert_includes out, 'gone from your subscriptions'
  end

  # The worst failure this command has: Amazon accepted it, the subscription
  # is still there, and the terminal says "cancelled".
  def test_a_subscription_still_listed_afterwards_is_reported_loudly
    out, = run_cancel(%w[subscribe cancel dishwasher --yes],
                      worker(SAMPLE_CANCEL.merge('verified' => false)))
    assert_includes out, 'still in your subscriptions'
  end

  def test_a_check_that_could_not_be_made_is_not_reported_as_failure
    out, = run_cancel(%w[subscribe cancel dishwasher --yes],
                      worker(SAMPLE_CANCEL.merge('verified' => nil)))
    assert_includes out, "couldn't re-read"
    refute_includes out, 'still in your subscriptions'
  end

  # Amazon marks the field optional, so the default says nothing rather than
  # inventing a motive and sending it to a company that reads them.
  def test_no_reason_is_sent_unless_one_is_given
    w = worker
    run_cancel(%w[subscribe cancel dishwasher --yes], w)
    assert_nil w.asked_reason
  end

  def test_a_reason_reaches_the_worker_in_both_spellings
    w = worker
    run_cancel(%w[subscribe cancel dishwasher --yes --reason accident], w)
    assert_equal 'accident', w.asked_reason
    run_cancel(%w[subscribe cancel dishwasher --yes --reason=stopped_using], w)
    assert_equal 'stopped_using', w.asked_reason
  end

  def test_a_reason_amazon_does_not_offer_comes_back_as_a_refusal
    w = FakeSubscribeWorker.new(not_found: "unknown cancellation reason 'cats'. Amazon offers: accident, other")
    _out, err, code = run_cancel(%w[subscribe cancel dishwasher --yes --reason cats], w)
    assert_equal 2, code
    assert_includes err, 'Amazon offers:'
  end

  def test_a_confirmed_cancellation_clears_the_cache
    w = worker(SAMPLE_CANCEL.merge('verified' => true))
    reads = nil
    with_worker(->(*) { w }) do
      capture_io_streams do
        Amazon::CLI.run(%w[subscribe list])
        before = w.calls
        Amazon::CLI.run(%w[subscribe cancel dishwasher --yes])
        Amazon::CLI.run(%w[subscribe list])
        reads = w.calls - before - 1
      end
    end
    assert_equal 1, reads, 'the list would still show a subscription that no longer exists'
  end

  def test_json_is_the_whole_record
    out, = run_cancel(%w[--json subscribe cancel dishwasher --yes],
                      worker(SAMPLE_CANCEL.merge('verified' => true)))
    parsed = JSON.parse(out)
    assert parsed['cancelled']
    assert_equal 2, parsed['consequences'].length
  end

  def test_it_needs_something_to_cancel
    _out, err, code = run_cancel(%w[subscribe cancel])
    assert_equal 2, code
    assert_includes err, 'usage:'
  end

  def test_it_takes_one_subscription_at_a_time
    _out, err, code = run_cancel(['subscribe', 'cancel', 'dish', 'mop'])
    assert_equal 2, code
    assert_includes err, 'one subscription at a time'
  end

  def test_unknown_options_are_refused
    _out, err, code = run_cancel(%w[subscribe cancel dishwasher --force])
    assert_equal 2, code
    assert_includes err, 'unknown cancel option'
  end

  def test_a_miss_passes_amazons_wording_through
    w = FakeSubscribeWorker.new(not_found: "no active subscription matching 'zzz'.")
    _out, err, code = run_cancel(%w[subscribe cancel zzz], w)
    assert_equal 2, code
    assert_includes err, 'no active subscription'
  end

  def test_the_help_distinguishes_it_from_skip
    out, = capture_io_streams { assert_equal 0, Amazon::CLI.run(%w[subscribe cancel --help]) }
    assert_includes out, 'not a skip'
    assert_includes out, '--reason'
  end

  def test_the_namespace_lists_it
    out, = capture_io_streams { Amazon::CLI.run(%w[subscribe]) }
    assert_includes out, 'cancel'
  end
end
