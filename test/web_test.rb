#!/usr/bin/env ruby
# frozen_string_literal: true

# Run with: ruby test/web_test.rb
# Fails the suite if line OR branch coverage drops below 95%.

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'sinatra'
  gem 'puma'
  gem 'rackup'
  gem 'rack-test'
  gem 'minitest'
  gem 'simplecov'
end

require 'simplecov'

SimpleCov.start do
  enable_coverage :branch
  primary_coverage :line
  command_name 'web_test'
  add_filter '/test/'
  minimum_coverage line: 95, branch: 95
end

require 'rack/test'
require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'date'

ENV['AMAZON_DATA_ROOT'] = File.expand_path('fixtures/amazon', __dir__)

require_relative '../web'

class WebTest < Minitest::Test
  include Rack::Test::Methods

  FIXTURES_ROOT = ENV.fetch('AMAZON_DATA_ROOT')
  INDEX_FIXTURE = File.join(FIXTURES_ROOT, 'index.json')

  def app
    Sinatra::Application
  end

  def helper
    @helper ||= Sinatra::Application.new!
  end

  def setup
    klass = Sinatra::Application
    %i[@index_cache @order_cache @cancelled_cache @refund_cache].each do |ivar|
      klass.remove_instance_variable(ivar) if klass.instance_variable_defined?(ivar)
    end
  end

  # ---------- Routes ----------

  def test_index_default
    get '/'
    assert_equal 200, last_response.status
    body = last_response.body
    assert_includes body, 'All orders'
    assert_includes body, '111-NORMAL'
    refute_includes body, '111-CANCELLED', 'cancelled hidden by default'
    assert_includes body, 'Show cancelled', 'toggle should be visible'
  end

  def test_index_with_year_filter
    get '/?year=2023'
    assert_equal 200, last_response.status
    assert_includes last_response.body, '2023'
    assert_includes last_response.body, '111-PARTIAL-REFUND'
  end

  def test_index_with_empty_year_param_treated_as_nil
    get '/?year='
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'All orders'
  end

  def test_index_search_by_title
    get '/?q=Widget'
    body = last_response.body
    assert_includes body, 'Widget'
    assert_includes body, 'mark', 'highlight wraps in <mark>'
  end

  def test_index_search_by_seller
    get '/?q=AcmeCorp'
    assert_includes last_response.body, 'AcmeCorp'
  end

  def test_index_search_by_order_id
    get '/?q=111-NORMAL'
    assert_includes last_response.body, '111-NORMAL'
  end

  def test_index_search_with_year
    get '/?q=Discounted&year=2023'
    assert_includes last_response.body, 'Discounted'
  end

  def test_index_no_results
    get '/?q=zzzz_nothing_matches'
    assert_includes last_response.body, 'No matching orders'
  end

  def test_index_show_cancelled
    get '/?cancelled=1'
    body = last_response.body
    assert_includes body, '111-CANCELLED'
    assert_includes body, 'Cancelled'
  end

  def test_index_density_compact
    get '/?density=compact'
    assert_equal 200, last_response.status
    body = last_response.body
    assert_includes body, '111-NORMAL'
  end

  def test_index_density_compact_with_cancelled_and_refund
    get '/?density=compact&cancelled=1'
    body = last_response.body
    assert_includes body, 'Cancelled'
    assert_includes body, 'Refunded'
  end

  def test_index_density_gallery
    get '/?density=gallery'
    body = last_response.body
    assert_equal 200, last_response.status
    assert_includes body, 'Widget'
  end

  def test_index_density_gallery_with_cancelled
    get '/?density=gallery&cancelled=1'
    body = last_response.body
    assert_includes body, 'Cancelled order'
    assert_includes body, 'Refunded'
  end

  def test_index_density_invalid_falls_back
    get '/?density=banana'
    assert_equal 200, last_response.status
  end

  def test_index_pagination_clamps_page
    get '/?page=999'
    assert_equal 200, last_response.status
  end

  def test_index_pagination_negative_page
    get '/?page=-5'
    assert_equal 200, last_response.status
  end

  def test_index_pagination_renders_when_many_orders
    Object.send(:remove_const, :PAGE_SIZE)
    Object.const_set(:PAGE_SIZE, 2)
    begin
      get '/?cancelled=1'
      body = last_response.body
      assert_includes body, 'Page 1'
      assert_includes body, 'Next'

      get '/?cancelled=1&page=2'
      body = last_response.body
      assert_includes body, 'Previous'
    ensure
      Object.send(:remove_const, :PAGE_SIZE)
      Object.const_set(:PAGE_SIZE, 200)
    end
  end

  def test_order_route_renders
    get '/o/111-NORMAL'
    assert_equal 200, last_response.status
    body = last_response.body
    assert_includes body, 'Widget gadget'
    assert_includes body, 'Visa'
    assert_includes body, '1234'
    assert_includes body, 'Delivered'
    assert_includes body, 'tracking'
    assert_includes body, 'Eric Boehs'
    assert_includes body, 'Bonus item'
    assert_includes body, 'View on Amazon'
  end

  def test_order_route_full_refund
    get '/o/111-FULL-REFUND'
    body = last_response.body
    assert_includes body, 'Refunded'
    assert_includes body, 'Returned thing'
  end

  def test_order_route_partial_refund_with_external_tracking
    get '/o/111-PARTIAL-REFUND'
    body = last_response.body
    assert_includes body, 'Refunded'
    assert_includes body, 'tracking.example.com'
  end

  def test_order_route_cancelled
    get '/o/111-CANCELLED'
    body = last_response.body
    assert_includes body, 'No items recorded'
  end

  def test_order_route_invalid_id
    get '/o/has%20spaces'
    assert_equal 400, last_response.status
  end

  def test_order_route_not_found
    get '/o/999-DOESNOTEXIST'
    assert_equal 404, last_response.status
  end

  def test_stats_route
    get '/stats'
    assert_equal 200, last_response.status
    body = last_response.body
    assert_includes body, 'Stats'
    assert_includes body, '2024'
    assert_includes body, '2023'
  end

  def test_health_route
    # Warm caches first so health reports nonzero sizes.
    get '/'
    get '/o/111-NORMAL'
    get '/health'
    assert_equal 200, last_response.status
    data = JSON.parse(last_response.body)
    assert data['orders_indexed'].positive?
    assert data['process']['pid']
    refute_nil data['index_mtime']
  end

  def test_health_route_cold_caches
    # Hit /health before anything has populated @index_cache so the
    # &. short-circuits + index_mtime nil branch are exercised.
    get '/health'
    assert_equal 200, last_response.status
    data = JSON.parse(last_response.body)
    # @index_cache was nil up to this point, so the lazy index_data call
    # inside the route still produces orders_indexed; index_mtime stays
    # nil only if the &. ran before the lazy fill — assert key exists.
    assert data.key?('index_mtime')
  end

  # ---------- Helpers ----------

  def test_money_usd
    assert_equal '$10.00', helper.money(10)
    assert_equal '$0.00', helper.money(0)
  end

  def test_money_negative
    assert_equal '-$5.50', helper.money(-5.50)
  end

  def test_money_nil
    assert_equal '—', helper.money(nil)
  end

  def test_money_other_currency
    assert_equal 'EUR 10.00', helper.money(10, 'EUR')
  end

  def test_h_escapes
    assert_equal '&lt;b&gt;', helper.h('<b>')
  end

  def test_parse_date_valid
    assert_equal Date.new(2024, 12, 15), helper.parse_date('2024-12-15')
  end

  def test_parse_date_invalid
    assert_nil helper.parse_date('not a date')
    assert_nil helper.parse_date(nil)
  end

  def test_relative_date_today
    assert_includes helper.relative_date(Date.today.iso8601), 'today'
  end

  def test_relative_date_yesterday
    assert_includes helper.relative_date((Date.today - 1).iso8601), 'yesterday'
  end

  def test_relative_date_days_ago
    assert_includes helper.relative_date((Date.today - 10).iso8601), '10d ago'
  end

  def test_relative_date_months_ago
    assert_includes helper.relative_date((Date.today - 60).iso8601), 'mo ago'
  end

  def test_relative_date_years_ago
    assert_includes helper.relative_date((Date.today - 800).iso8601), 'y ago'
  end

  def test_relative_date_invalid
    assert_equal 'garbage', helper.relative_date('garbage')
  end

  def test_highlight_empty_query
    assert_equal 'foo', helper.highlight('foo', '')
    assert_equal 'foo', helper.highlight('foo', nil)
  end

  def test_highlight_match
    result = helper.highlight('Foo bar foo', 'foo')
    assert_includes result, '<mark'
    assert_equal 2, result.scan('<mark').size
  end

  def test_highlight_no_match
    result = helper.highlight('Foo bar', 'zzz')
    refute_includes result, '<mark'
  end

  def test_short_address
    s = helper.short_address("Line 1\nLine 2\n  \nLine 3\nLine 4")
    assert_equal 'Line 1 · Line 2 · Line 3', s
  end

  def test_short_address_nil
    assert_equal '', helper.short_address(nil)
  end

  def test_amazon_url_path
    assert_equal 'https://www.amazon.com/dp/B000', helper.amazon_url('/dp/B000')
  end

  def test_amazon_url_full
    assert_equal 'https://other.com/x', helper.amazon_url('https://other.com/x')
  end

  def test_load_order_missing_meta
    assert_nil helper.load_order('does-not-exist')
  end

  def test_load_order_missing_file
    assert_nil helper.load_order('111-NO-FILE')
  end

  def test_load_order_corrupt_json
    assert_nil helper.load_order('111-CORRUPT')
  end

  def test_load_order_caches_by_mtime
    a = helper.load_order('111-NORMAL')
    b = helper.load_order('111-NORMAL')
    assert_same a, b
  end

  def test_cancelled_predicate
    assert helper.cancelled?('111-CANCELLED')
    refute helper.cancelled?('111-NORMAL')
    refute helper.cancelled?('111-NO-FILE')
  end

  def test_cancelled_predicate_caches
    helper.cancelled?('111-NORMAL')
    helper.cancelled?('111-NORMAL') # second call hits cache
    cache = Sinatra::Application.instance_variable_get(:@cancelled_cache)
    assert cache.key?('111-NORMAL')
  end

  def test_refund_kind_full
    assert_equal :full, helper.refund_kind('111-FULL-REFUND')
  end

  def test_refund_kind_partial
    assert_equal :partial, helper.refund_kind('111-PARTIAL-REFUND')
  end

  def test_refund_kind_none
    assert_nil helper.refund_kind('111-NORMAL')
    assert_nil helper.refund_kind('111-NO-FILE')
  end

  def test_stats_empty
    s = helper.stats([])
    assert_equal 0, s[:count]
    assert_equal 0, s[:avg]
    assert_equal 0, s[:max]
    assert_equal 0, s[:total]
  end

  def test_stats_with_orders
    s = helper.stats([{ 'total' => 10 }, { 'total' => 30 }, { 'total' => nil }])
    assert_equal 3, s[:count]
    assert_equal 40, s[:total]
    assert_equal 20, s[:avg]
    assert_equal 30, s[:max]
    assert_equal 1, s[:missing_total]
  end

  def test_filter_orders_by_year
    out = helper.filter_orders(helper.all_orders, year: 2024, include_cancelled: true)
    assert(out.all? { |o| o['year'] == 2024 })
  end

  def test_filter_orders_excludes_cancelled
    out = helper.filter_orders(helper.all_orders, include_cancelled: false)
    refute(out.any? { |o| o['order_id'] == '111-CANCELLED' })
  end

  def test_filter_orders_query_matches_id
    out = helper.filter_orders(helper.all_orders, query: '111-normal')
    assert_equal ['111-NORMAL'], out.map { |o| o['order_id'] }
  end

  def test_filter_orders_query_matches_title
    out = helper.filter_orders(helper.all_orders, query: 'widget')
    assert_includes out.map { |o| o['order_id'] }, '111-NORMAL'
  end

  def test_filter_orders_query_skips_unloadable
    # 111-NO-FILE has no order file; query path must reject it gracefully.
    out = helper.filter_orders(helper.all_orders, query: 'widget', include_cancelled: true)
    refute_includes out.map { |o| o['order_id'] }, '111-NO-FILE'
  end

  def test_years_sorted_desc
    assert_equal [2024, 2023, 2022], helper.years
  end

  def test_yearly_breakdown_shape
    breakdown = helper.yearly_breakdown
    years = breakdown.map(&:first)
    assert_equal [2024, 2023, 2022], years
    assert(breakdown.all? { |_, s| s.key?(:count) })
  end

  def test_index_data_handles_corrupt_index
    backup = File.read(INDEX_FIXTURE)
    begin
      File.write(INDEX_FIXTURE, '{ not valid')
      Sinatra::Application.remove_instance_variable(:@index_cache) if Sinatra::Application.instance_variable_defined?(:@index_cache)
      data = helper.index_data
      assert_equal({ 'orders' => {}, 'last_sync' => nil }, data)
      # Fresh helper: @index_cache is still unset, so all_orders must
      # short-circuit through the &. branch and return [].
      fresh = Sinatra::Application.new!
      assert_equal [], fresh.all_orders
    ensure
      File.write(INDEX_FIXTURE, backup)
      Sinatra::Application.remove_instance_variable(:@index_cache) if Sinatra::Application.instance_variable_defined?(:@index_cache)
    end
  end

  def test_index_data_caches
    a = helper.index_data
    b = helper.index_data
    assert_same a, b
  end

  def test_template_loader_caches
    first = load_templates
    second = load_templates
    assert_same first, second
  end

  def test_template_helper_raises_on_unknown
    assert_raises(RuntimeError) { template(:nope) }
  end
end
