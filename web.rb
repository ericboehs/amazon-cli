#!/usr/bin/env ruby
# frozen_string_literal: true

# Amazon Order History — single-file Ruby Sinatra app to browse, search,
# and view orders synced by `amazon-cli` into ~/.local/share/amazon/.

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'sinatra'
  gem 'puma'
  gem 'rackup'
end

require 'sinatra'
require 'json'
require 'erb'

DATA_ROOT  = ENV['AMAZON_DATA_ROOT'] || File.expand_path('~/.local/share/amazon')
INDEX_PATH = File.join(DATA_ROOT, 'index.json')
WEB_RB_PATH = File.expand_path(__FILE__)

def load_templates
  return @templates if @templates

  raw = File.read(WEB_RB_PATH).force_encoding('UTF-8').split(/^__END__$/, 2).last.to_s
  parts = raw.split(/^@@(\w+)\s*\n/)
  parts.shift
  @templates = parts.each_slice(2).to_h
end

def template(name)
  load_templates.fetch(name.to_s) { raise "Unknown template: #{name}" }
end

helpers do
  def h(text)
    Rack::Utils.escape_html(text.to_s)
  end

  def render_page(name, locals = {})
    locals.each { |k, v| instance_variable_set("@#{k}", v) }
    @_title = locals[:title] || 'Amazon Orders'
    @_content = ERB.new(template(name)).result(binding)
    ERB.new(template('layout')).result(binding)
  end

  def money(amount, currency = 'USD')
    return '—' if amount.nil?

    sign = amount.negative? ? '-' : ''
    abs = amount.abs
    symbol = currency == 'USD' ? '$' : "#{currency} "
    "#{sign}#{symbol}#{format('%.2f', abs)}"
  end

  def parse_date(str)
    Date.parse(str.to_s)
  rescue StandardError
    nil
  end

  def relative_date(str)
    d = parse_date(str)
    return h(str.to_s) unless d

    days = (Date.today - d).to_i
    label =
      case days
      when 0 then 'today'
      when 1 then 'yesterday'
      when 2..30 then "#{days}d ago"
      when 31..365 then "#{(days / 30.0).round}mo ago"
      else "#{(days / 365.0).round}y ago"
      end
    %(<span title="#{h(d.strftime('%A, %B %-d, %Y'))}">#{h(d.strftime('%b %-d, %Y'))} <span class="text-zinc-500 dark:text-zinc-400">· #{label}</span></span>)
  end

  def index_data
    mtime = File.mtime(INDEX_PATH).to_f
    cache = self.class.instance_variable_get(:@index_cache)
    return cache[:data] if cache && cache[:mtime] == mtime && cache[:all_orders]

    data = JSON.parse(File.read(INDEX_PATH))
    all_orders = data.fetch('orders', {}).map { |id, meta|
      meta.merge('order_id' => id, '_date' => parse_date(meta['date']))
    }.sort_by { |o| [o['_date'] ? -o['_date'].to_time.to_i : 0, o['order_id']] }
    self.class.instance_variable_set(:@index_cache,
      { mtime: mtime, data: data, all_orders: all_orders })
    @all_orders = all_orders
    data
  rescue StandardError
    { 'orders' => {}, 'last_sync' => nil }
  end

  def all_orders
    index_data
    @all_orders ||= self.class.instance_variable_get(:@index_cache)&.dig(:all_orders) || []
  end

  def years
    all_orders.map { |o| o['year'] }.compact.uniq.sort.reverse
  end

  def filter_orders(orders, year: nil, query: nil, include_cancelled: false)
    out = orders
    out = out.select { |o| o['year'].to_i == year.to_i } if year
    out = out.reject { |o| cancelled?(o['order_id']) } unless include_cancelled
    if query && !query.empty?
      q = query.downcase
      out = out.select do |o|
        next true if o['order_id'].downcase.include?(q)

        full = load_order(o['order_id'])
        next false unless full

        items = full['items'] || []
        items.any? { |i| i['title'].to_s.downcase.include?(q) || i['seller'].to_s.downcase.include?(q) }
      end
    end
    out
  end

  def cancelled?(order_id)
    cache_for(:cancelled, order_id) do |full|
      !!(full && (full['items'] || []).empty? &&
        (full['shipments'] || []).any? { |s| s['delivery_status'].to_s.match?(/cancel/i) })
    end
  end

  def refund_kind(order_id)
    cache_for(:refund, order_id) do |full|
      refund = full && full['refund_total']
      total = full && full['grand_total']
      if refund.nil? || refund.zero?
        nil
      elsif total && (refund - total).abs < 0.01
        :full
      else
        :partial
      end
    end
  end

  def cache_for(name, order_id)
    cache = self.class.instance_variable_get(:"@#{name}_cache") || {}
    meta = index_data.dig('orders', order_id) || {}
    path = File.join(DATA_ROOT, meta['file'].to_s)
    mtime = File.exist?(path) ? File.mtime(path).to_f : 0.0
    cached = cache[order_id]
    return cached[:value] if cached && cached[:mtime] == mtime

    value = yield(load_order(order_id))
    cache[order_id] = { mtime: mtime, value: value }
    self.class.instance_variable_set(:"@#{name}_cache", cache)
    value
  end

  def load_order(order_id)
    meta = index_data.dig('orders', order_id)
    return nil unless meta

    path = File.join(DATA_ROOT, meta['file'])
    return nil unless File.exist?(path)

    cache = self.class.instance_variable_get(:@order_cache) || {}
    mtime = File.mtime(path).to_f
    cached = cache[order_id]
    return cached[:data] if cached && cached[:mtime] == mtime

    data = JSON.parse(File.read(path))
    cache[order_id] = { mtime: mtime, data: data }
    self.class.instance_variable_set(:@order_cache, cache)
    data
  rescue StandardError
    nil
  end

  def stats(orders)
    totals = orders.map { |o| o['total'] }.compact
    {
      count: orders.size,
      total: totals.sum,
      avg: totals.empty? ? 0 : totals.sum / totals.size,
      max: totals.max || 0,
      missing_total: orders.count { |o| o['total'].nil? }
    }
  end

  def yearly_breakdown
    years.map do |y|
      ys = all_orders.select { |o| o['year'] == y }
      [y, stats(ys)]
    end
  end

  def highlight(text, query)
    return h(text) if query.to_s.empty?

    escaped = h(text)
    pattern = Regexp.new(Regexp.escape(h(query)), Regexp::IGNORECASE)
    escaped.gsub(pattern) { |m| %(<mark class="bg-amber-200 dark:bg-amber-400/30 text-amber-900 dark:text-amber-100 rounded px-0.5">#{m}</mark>) }
  end

  def short_address(addr)
    addr.to_s.split("\n").map(&:strip).reject(&:empty?).first(3).join(' · ')
  end

  def amazon_url(path)
    path.to_s.start_with?('http') ? path : "https://www.amazon.com#{path}"
  end
end

set :environment, ENV['RACK_ENV'] || :production
set :bind, ENV['BIND'] || '0.0.0.0'
set :port, ENV['PORT'] || 4824
set :protection, host_authorization: { permitted_hosts: [] }

PAGE_SIZE = 200
DENSITIES = %w[compact comfortable gallery].freeze

get '/' do
  year = params[:year] && !params[:year].empty? ? params[:year].to_i : nil
  query = params[:q].to_s.strip
  show_cancelled = params[:cancelled] == '1'
  density = DENSITIES.include?(params[:density]) ? params[:density] : 'comfortable'
  page = [params[:page].to_i, 1].max
  orders = filter_orders(all_orders, year: year, query: query, include_cancelled: show_cancelled)
  cancelled_count = filter_orders(all_orders, year: year, query: query, include_cancelled: true)
                    .count { |o| cancelled?(o['order_id']) }
  total_pages = [((orders.size - 1) / PAGE_SIZE) + 1, 1].max
  page = [page, total_pages].min
  paged = orders.slice((page - 1) * PAGE_SIZE, PAGE_SIZE) || []
  render_page :index,
              orders: paged,
              page: page,
              total_pages: total_pages,
              total_count: orders.size,
              year: year,
              query: query,
              show_cancelled: show_cancelled,
              cancelled_count: cancelled_count,
              density: density,
              years: years,
              stats: stats(orders),
              yearly: yearly_breakdown,
              last_sync: index_data['last_sync'],
              title: 'Amazon Orders'
end

get '/o/:order_id' do
  order_id = params[:order_id]
  halt 400, 'bad id' unless order_id =~ /\A[\w-]+\z/

  order = load_order(order_id)
  halt 404, 'order not found' unless order

  meta = index_data.dig('orders', order_id) || {}
  render_page :order,
              order: order,
              meta: meta,
              order_id: order_id,
              title: "Order #{order_id}"
end

get '/stats' do
  render_page :stats,
              yearly: yearly_breakdown,
              overall: stats(all_orders),
              last_sync: index_data['last_sync'],
              title: 'Stats'
end

get '/health' do
  content_type :json
  klass = Sinatra::Application
  index_size = klass.instance_variable_get(:@index_cache)&.dig(:all_orders)&.size
  index_mtime = klass.instance_variable_get(:@index_cache)&.dig(:mtime)
  JSON.pretty_generate(
    last_sync: index_data['last_sync'],
    orders_indexed: index_size || all_orders.size,
    index_mtime: index_mtime ? Time.at(index_mtime).utc.iso8601 : nil,
    cache: {
      orders_loaded: (klass.instance_variable_get(:@order_cache) || {}).size,
      cancelled_resolved: (klass.instance_variable_get(:@cancelled_cache) || {}).size,
      refund_resolved: (klass.instance_variable_get(:@refund_cache) || {}).size
    },
    process: { pid: Process.pid, uptime_s: (Time.now - $started_at).to_i }
  )
end

$started_at = Time.now
Sinatra::Application.run! if $PROGRAM_NAME == __FILE__

__END__

@@layout
<!DOCTYPE html>
<html lang="en" class="h-full">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title><%= h(@_title) %></title>
  <link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='%23f59e0b'%3E%3Cpath d='M3 3h2l3 12h11l3-9H7'/%3E%3Ccircle cx='9' cy='20' r='1.5'/%3E%3Ccircle cx='17' cy='20' r='1.5'/%3E%3C/svg%3E" type="image/svg+xml">
  <script src="https://cdn.tailwindcss.com"></script>
  <style>
    :where(a, button, input, [tabindex]):focus-visible {
      outline: 2px solid #f59e0b; /* amber-500 */
      outline-offset: 2px;
      border-radius: 0.375rem;
    }
    @media (prefers-reduced-motion: reduce) {
      *, *::before, *::after {
        animation-duration: 0.01ms !important;
        transition-duration: 0.01ms !important;
        scroll-behavior: auto !important;
      }
      .group-hover\:scale-105 { transform: none !important; }
    }
  </style>
</head>
<body class="h-full bg-white dark:bg-zinc-950 text-zinc-900 dark:text-zinc-100 antialiased">
  <header class="sticky top-0 z-10 border-b border-zinc-200 dark:border-zinc-800 bg-white/80 dark:bg-zinc-950/80 backdrop-blur">
    <div class="max-w-6xl mx-auto px-4 py-3 flex items-center gap-4">
      <a href="/" aria-label="Amazon Orders home" class="flex items-center gap-2 font-semibold text-amber-700 dark:text-amber-400 hover:text-amber-800 dark:hover:text-amber-300 shrink-0">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="w-5 h-5" aria-hidden="true"><path d="M3 3h2l3 12h11l3-9H7"/><circle cx="9" cy="20" r="1.5"/><circle cx="17" cy="20" r="1.5"/></svg>
        <span class="hidden sm:inline">Amazon Orders</span>
      </a>
      <form action="/" method="get" class="flex-1 max-w-xl ml-auto flex gap-2">
        <div class="relative flex-1">
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4 absolute left-3 top-2.5 text-zinc-500 dark:text-zinc-400"><path fill-rule="evenodd" d="M9 3.5a5.5 5.5 0 100 11 5.5 5.5 0 000-11zM2 9a7 7 0 1112.452 4.391l3.328 3.329a.75.75 0 11-1.06 1.06l-3.329-3.328A7 7 0 012 9z" clip-rule="evenodd"/></svg>
          <input type="search" name="q" value="<%= h(@query) %>" placeholder="Search items, sellers, order IDs…" aria-label="Search orders" autocomplete="off"
                 class="w-full bg-zinc-100 dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-800 rounded-lg pl-9 pr-3 py-2 text-sm text-zinc-900 dark:text-zinc-100 placeholder-zinc-600 dark:placeholder-zinc-400 focus:outline-none focus:ring-2 focus:ring-amber-500 focus:border-amber-500">
        </div>
        <% if @year %>
          <input type="hidden" name="year" value="<%= h(@year) %>">
        <% end %>
        <% if @show_cancelled %>
          <input type="hidden" name="cancelled" value="1">
        <% end %>
        <% if @density && @density != 'comfortable' %>
          <input type="hidden" name="density" value="<%= h(@density) %>">
        <% end %>
      </form>
      <a href="/stats" aria-label="Stats" class="text-sm text-zinc-700 dark:text-zinc-300 hover:text-amber-800 dark:hover:text-amber-300 shrink-0 inline-flex items-center gap-1 rounded-md px-1">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4 sm:hidden" aria-hidden="true"><path d="M2 11a1 1 0 011-1h2a1 1 0 011 1v6a1 1 0 01-1 1H3a1 1 0 01-1-1v-6zM8 5a1 1 0 011-1h2a1 1 0 011 1v12a1 1 0 01-1 1H9a1 1 0 01-1-1V5zM14 8a1 1 0 011-1h2a1 1 0 011 1v9a1 1 0 01-1 1h-2a1 1 0 01-1-1V8z"/></svg>
        <span class="hidden sm:inline">Stats</span>
      </a>
    </div>
  </header>
  <main class="max-w-6xl mx-auto px-4 py-6">
    <%= @_content %>
  </main>
  <footer class="max-w-6xl mx-auto px-4 py-8 text-xs text-zinc-500 dark:text-zinc-400 flex flex-wrap items-center gap-3">
    <code class="text-zinc-500 dark:text-zinc-400"><%= h(DATA_ROOT.sub(Dir.home, '~')) %></code>
    <% if @last_sync %>
      <span>· last sync <%= h(@last_sync) %></span>
    <% end %>
  </footer>
</body>
</html>

@@index
<div class="mb-6 flex items-end justify-between gap-4 flex-wrap">
  <div>
    <h1 class="text-2xl font-semibold text-zinc-900 dark:text-zinc-100">
      <% if @query.empty? && !@year %>
        All orders
      <% elsif @query.empty? %>
        <%= h(@year) %>
      <% else %>
        Search: <span class="text-amber-700 dark:text-amber-300">"<%= h(@query) %>"</span><% if @year %> in <%= h(@year) %><% end %>
      <% end %>
    </h1>
    <p class="text-sm text-zinc-600 dark:text-zinc-400 mt-1">
      <%= @stats[:count] %> order<%= 's' if @stats[:count] != 1 %>
      · <span class="text-zinc-800 dark:text-zinc-200 tabular-nums"><%= money(@stats[:total]) %></span> total
      <% if @stats[:count].positive? %>
        · avg <span class="tabular-nums"><%= money(@stats[:avg]) %></span>
      <% end %>
      <% if @stats[:missing_total].positive? %>
        · <span class="text-zinc-500 dark:text-zinc-400"><%= @stats[:missing_total] %> w/o total</span>
      <% end %>
      <% if @total_pages > 1 %>
        · <span class="text-zinc-500 dark:text-zinc-400">page <%= @page %>/<%= @total_pages %></span>
      <% end %>
    </p>
  </div>

  <div class="flex items-center gap-1 flex-wrap">
    <%
      qs = ->(year: @year, cancelled: @show_cancelled, density: @density) {
        parts = []
        parts << "year=#{year}" if year
        parts << "q=#{h(@query)}" unless @query.empty?
        parts << 'cancelled=1' if cancelled
        parts << "density=#{density}" unless density == 'comfortable'
        parts.empty? ? '/' : "/?#{parts.join('&')}"
      }
    %>
    <a href="<%= qs.call(year: nil) %>"<%= ' aria-current="page"' if @year.nil? %> class="px-3 py-1.5 rounded-md text-xs font-medium <%= @year.nil? ? 'bg-amber-100 dark:bg-amber-500/20 text-amber-800 dark:text-amber-300 ring-1 ring-amber-400 dark:ring-amber-500/30' : 'text-zinc-700 dark:text-zinc-300 hover:text-zinc-900 dark:hover:text-zinc-100' %>">All years</a>
    <% @years.each do |y| %>
      <a href="<%= qs.call(year: y) %>"<%= ' aria-current="page"' if @year == y %> class="px-3 py-1.5 rounded-md text-xs font-medium tabular-nums <%= @year == y ? 'bg-amber-100 dark:bg-amber-500/20 text-amber-800 dark:text-amber-300 ring-1 ring-amber-400 dark:ring-amber-500/30' : 'text-zinc-700 dark:text-zinc-300 hover:text-zinc-900 dark:hover:text-zinc-100' %>"><%= y %></a>
    <% end %>
  </div>
</div>

<div class="mb-4 flex items-center justify-between gap-3 flex-wrap">
  <% if @cancelled_count.positive? || @show_cancelled %>
    <a href="<%= qs.call(cancelled: !@show_cancelled) %>" role="checkbox" aria-checked="<%= @show_cancelled %>" class="inline-flex items-center gap-2 text-xs text-zinc-700 dark:text-zinc-300 hover:text-zinc-900 dark:hover:text-zinc-100 select-none group">
      <span aria-hidden="true" class="w-4 h-4 rounded border <%= @show_cancelled ? 'bg-amber-600 dark:bg-amber-500/80 border-amber-700 dark:border-amber-400' : 'border-zinc-500 dark:border-zinc-500 group-hover:border-zinc-700 dark:group-hover:border-zinc-300' %> flex items-center justify-center">
        <% if @show_cancelled %>
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-3 h-3 text-white dark:text-zinc-950"><path fill-rule="evenodd" d="M16.704 4.153a.75.75 0 01.143 1.052l-8 10.5a.75.75 0 01-1.127.075l-4.5-4.5a.75.75 0 011.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 011.05-.143z" clip-rule="evenodd"/></svg>
        <% end %>
      </span>
      Show cancelled orders
      <span class="text-zinc-500 dark:text-zinc-400">(<%= @cancelled_count %>)</span>
    </a>
  <% else %>
    <span></span>
  <% end %>

  <div class="inline-flex items-center rounded-md border border-zinc-200 dark:border-zinc-800 overflow-hidden text-xs" role="group" aria-label="Display density">
    <% [
      ['compact',     'M2 5h16M2 10h16M2 15h16'],
      ['comfortable', 'M2 4h16v4H2zM2 12h16v4H2z'],
      ['gallery',    'M3 3h6v6H3zM11 3h6v6h-6zM3 11h6v6H3zM11 11h6v6h-6z']
    ].each do |val, path| %>
      <a href="<%= qs.call(density: val) %>" title="<%= val.capitalize %> density" aria-label="<%= val.capitalize %> density"<%= ' aria-current="true"' if @density == val %> class="px-2.5 py-1.5 transition <%= @density == val ? 'bg-amber-100 dark:bg-amber-500/20 text-amber-800 dark:text-amber-300' : 'text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100 hover:bg-zinc-50 dark:hover:bg-zinc-900' %>">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" class="w-4 h-4"><path d="<%= path %>"/></svg>
      </a>
    <% end %>
  </div>
</div>

<% if @orders.empty? %>
  <div class="text-zinc-600 dark:text-zinc-400 text-sm border border-zinc-200 dark:border-zinc-800 rounded-lg p-6">No matching orders.</div>
<% else %>
  <% if @density == 'gallery' %>
    <ul class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-3">
      <% @orders.each do |o|
           full = load_order(o['order_id'])
           items = full ? (full['items'] || []) : []
           first_item = items.first
           extra = items.size - 1
           shipment_statuses = (full && full['shipments'] || []).map { |s| s['delivery_status'].to_s }.reject(&:empty?)
           cancelled = items.empty? && shipment_statuses.any? { |s| s.match?(/cancel/i) }
           refund = refund_kind(o['order_id'])
      %>
        <li>
          <a href="/o/<%= h(o['order_id']) %>" class="group block rounded-lg overflow-hidden border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900/40 hover:border-zinc-300 dark:hover:border-zinc-700 transition <%= '' %>">
            <div class="relative aspect-square bg-zinc-100 dark:bg-zinc-800">
              <% if first_item && first_item['image_link'] %>
                <img src="<%= h(first_item['image_link']) %>" alt="" loading="lazy" class="absolute inset-0 w-full h-full object-contain p-2 group-hover:scale-105 transition-transform duration-200">
              <% else %>
                <div class="absolute inset-0 flex items-center justify-center text-zinc-400 dark:text-zinc-600">
                  <% if cancelled %>
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-10 h-10"><path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.28 7.22a.75.75 0 00-1.06 1.06L8.94 10l-1.72 1.72a.75.75 0 101.06 1.06L10 11.06l1.72 1.72a.75.75 0 101.06-1.06L11.06 10l1.72-1.72a.75.75 0 00-1.06-1.06L10 8.94 8.28 7.22z" clip-rule="evenodd"/></svg>
                  <% else %>
                    <span class="text-xs">no image</span>
                  <% end %>
                </div>
              <% end %>

              <% if extra.positive? %>
                <span class="absolute top-1.5 left-1.5 inline-flex items-center rounded bg-zinc-900/70 text-white px-1.5 py-0.5 text-[10px] font-medium tabular-nums backdrop-blur">+<%= extra %></span>
              <% end %>
              <% if cancelled %>
                <span class="absolute top-1.5 right-1.5 inline-flex items-center rounded bg-rose-700 text-white px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide shadow">Cancelled</span>
              <% elsif refund %>
                <span class="absolute top-1.5 right-1.5 inline-flex items-center rounded bg-emerald-700 text-white px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide shadow">
                  <%= refund == :full ? 'Refunded' : 'Partial' %>
                </span>
              <% end %>

              <div class="absolute bottom-0 left-0 right-0 px-2 py-1.5 bg-gradient-to-t from-black/80 via-black/40 to-transparent text-white flex items-end justify-between gap-2">
                <span class="text-[11px] tabular-nums opacity-90"><%= h(parse_date(o['date'])&.strftime('%b %-d, %Y') || o['date']) %></span>
                <span class="text-sm font-semibold tabular-nums"><%= money(o['total']) %></span>
              </div>
            </div>

            <div class="px-3 py-2 text-xs text-zinc-700 dark:text-zinc-300 leading-snug line-clamp-3 min-h-[4.5rem]">
              <% if first_item %>
                <%= highlight(first_item['title'].to_s, @query) %>
              <% elsif cancelled %>
                <span class="italic text-zinc-500 dark:text-zinc-400">Cancelled order</span>
              <% else %>
                <span class="italic text-zinc-500 dark:text-zinc-400">No items recorded</span>
              <% end %>
            </div>
          </a>
        </li>
      <% end %>
    </ul>
  <% else %>
    <%
      img_size = { 'compact' => 'w-9 h-9', 'comfortable' => 'w-16 h-16' }[@density]
      card_pad = { 'compact' => 'px-3 py-2',  'comfortable' => 'p-4' }[@density]
      list_gap = { 'compact' => 'space-y-1',  'comfortable' => 'space-y-2' }[@density]
      title_clamp = { 'compact' => 'line-clamp-1', 'comfortable' => 'line-clamp-2' }[@density]
      total_size = { 'compact' => 'text-sm', 'comfortable' => 'text-lg' }[@density]
    %>
    <ul class="<%= list_gap %>">
      <% @orders.each do |o|
           full = load_order(o['order_id'])
           items = full ? (full['items'] || []) : []
           first_item = items.first
           extra = items.size - 1
           shipment_statuses = (full && full['shipments'] || []).map { |s| s['delivery_status'].to_s }.reject(&:empty?)
           cancelled = items.empty? && shipment_statuses.any? { |s| s.match?(/cancel/i) }
           refund = refund_kind(o['order_id'])
           refund_amount = full && full['refund_total']
      %>
        <li>
          <a href="/o/<%= h(o['order_id']) %>" class="block rounded-lg border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900/40 hover:bg-zinc-50 dark:hover:bg-zinc-900 hover:border-zinc-300 dark:hover:border-zinc-700 <%= card_pad %> transition <%= '' %>">
            <div class="flex items-<%= @density == 'compact' ? 'center' : 'start' %> gap-<%= @density == 'compact' ? '3' : '4' %>">
              <% if first_item && first_item['image_link'] %>
                <img src="<%= h(first_item['image_link']) %>" alt="" loading="lazy" class="<%= img_size %> rounded bg-zinc-100 dark:bg-zinc-800 object-contain shrink-0 ring-1 ring-zinc-200 dark:ring-zinc-800">
              <% elsif cancelled %>
                <div class="<%= img_size %> rounded bg-zinc-100 dark:bg-zinc-900 ring-1 ring-zinc-200 dark:ring-zinc-800 shrink-0 flex items-center justify-center text-zinc-500 dark:text-zinc-400">
                  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="<%= @density == 'compact' ? 'w-4 h-4' : 'w-6 h-6' %>"><path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.28 7.22a.75.75 0 00-1.06 1.06L8.94 10l-1.72 1.72a.75.75 0 101.06 1.06L10 11.06l1.72 1.72a.75.75 0 101.06-1.06L11.06 10l1.72-1.72a.75.75 0 00-1.06-1.06L10 8.94 8.28 7.22z" clip-rule="evenodd"/></svg>
                </div>
              <% else %>
                <div class="<%= img_size %> rounded bg-zinc-100 dark:bg-zinc-800 ring-1 ring-zinc-300 dark:ring-zinc-700 shrink-0"></div>
              <% end %>

              <div class="min-w-0 flex-1">
                <% if @density == 'compact' %>
                  <div class="flex items-center gap-3 min-w-0">
                    <span class="text-zinc-900 dark:text-zinc-100 font-medium truncate flex-1">
                      <% if first_item %>
                        <%= highlight(first_item['title'].to_s, @query) %>
                      <% elsif cancelled %>
                        <span class="italic text-zinc-500 dark:text-zinc-400">Cancelled order</span>
                      <% else %>
                        <span class="italic text-zinc-500 dark:text-zinc-400">No items recorded</span>
                      <% end %>
                    </span>
                    <span class="text-xs text-zinc-500 dark:text-zinc-400 tabular-nums shrink-0 hidden sm:inline"><%= h(parse_date(o['date'])&.strftime('%b %-d, %Y') || o['date']) %></span>
                    <% if cancelled %>
                      <span class="inline-flex items-center rounded bg-rose-100 dark:bg-rose-500/15 text-rose-700 dark:text-rose-300 ring-1 ring-rose-300 dark:ring-rose-500/30 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide shrink-0">Cancelled</span>
                    <% end %>
                    <% if refund %>
                      <span title="Refunded <%= h(money(refund_amount)) %>" class="inline-flex items-center rounded bg-emerald-100 dark:bg-emerald-500/15 text-emerald-700 dark:text-emerald-300 ring-1 ring-emerald-300 dark:ring-emerald-500/30 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide shrink-0">
                        <%= refund == :full ? 'Refunded' : 'Partial' %>
                      </span>
                    <% end %>
                  </div>
                <% else %>
                  <div class="flex items-center gap-2 text-xs text-zinc-500 dark:text-zinc-400 mb-1 flex-wrap">
                    <span class="font-mono text-zinc-600 dark:text-zinc-400"><%= h(o['order_id']) %></span>
                    <span>·</span>
                    <span><%= relative_date(o['date']) %></span>
                    <% if cancelled %>
                      <span class="inline-flex items-center rounded-full bg-rose-100 dark:bg-rose-500/15 text-rose-700 dark:text-rose-300 ring-1 ring-rose-300 dark:ring-rose-500/30 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide">Cancelled</span>
                    <% end %>
                    <% if refund %>
                      <span title="Refunded <%= h(money(refund_amount)) %>" class="inline-flex items-center rounded-full bg-emerald-100 dark:bg-emerald-500/15 text-emerald-700 dark:text-emerald-300 ring-1 ring-emerald-300 dark:ring-emerald-500/30 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide">
                        <%= refund == :full ? 'Refunded' : 'Partial refund' %>
                      </span>
                    <% end %>
                  </div>
                  <% if first_item %>
                    <div class="text-zinc-900 dark:text-zinc-100 font-medium leading-snug <%= title_clamp %>"><%= highlight(first_item['title'].to_s, @query) %></div>
                    <div class="text-xs text-zinc-500 dark:text-zinc-400 mt-1">
                      <% if first_item['seller'] %>sold by <span class="text-zinc-600 dark:text-zinc-400"><%= highlight(first_item['seller'].to_s, @query) %></span><% end %>
                      <% if extra.positive? %>
                        <span class="ml-1 inline-flex items-center rounded-full bg-zinc-100 dark:bg-zinc-800 px-2 py-0.5 text-zinc-700 dark:text-zinc-300">+<%= extra %> more item<%= 's' if extra != 1 %></span>
                      <% end %>
                    </div>
                  <% elsif cancelled %>
                    <div class="text-zinc-500 dark:text-zinc-400 text-sm italic">Cancelled — no items shipped</div>
                  <% else %>
                    <div class="text-zinc-500 dark:text-zinc-400 italic text-sm">No items recorded</div>
                  <% end %>
                <% end %>
              </div>

              <div class="text-right shrink-0">
                <div class="<%= total_size %> font-semibold tabular-nums text-zinc-900 dark:text-zinc-100"><%= money(o['total']) %></div>
              </div>
            </div>
          </a>
        </li>
      <% end %>
    </ul>
  <% end %>

  <% if @total_pages > 1 %>
    <%
      page_url = ->(p) {
        parts = []
        parts << "year=#{@year}" if @year
        parts << "q=#{h(@query)}" unless @query.empty?
        parts << 'cancelled=1' if @show_cancelled
        parts << "density=#{@density}" if @density && @density != 'comfortable'
        parts << "page=#{p}" if p > 1
        parts.empty? ? '/' : "/?#{parts.join('&')}"
      }
    %>
    <nav class="mt-6 flex items-center justify-between gap-3 text-sm">
      <% if @page > 1 %>
        <a href="<%= page_url.call(@page - 1) %>" class="px-3 py-1.5 rounded-md border border-zinc-200 dark:border-zinc-800 text-zinc-700 dark:text-zinc-300 hover:bg-zinc-50 dark:hover:bg-zinc-900">← Previous</a>
      <% else %>
        <span></span>
      <% end %>
      <span class="text-zinc-500 dark:text-zinc-400 tabular-nums">Page <%= @page %> of <%= @total_pages %> · <%= @total_count %> orders</span>
      <% if @page < @total_pages %>
        <a href="<%= page_url.call(@page + 1) %>" class="px-3 py-1.5 rounded-md border border-zinc-200 dark:border-zinc-800 text-zinc-700 dark:text-zinc-300 hover:bg-zinc-50 dark:hover:bg-zinc-900">Next →</a>
      <% else %>
        <span></span>
      <% end %>
    </nav>
  <% end %>
<% end %>

@@order
<% items = @order['items'] || [] %>
<% shipments = @order['shipments'] || [] %>
<% hero_item = items.find { |i| i['image_link'] } %>
<nav class="text-xs text-zinc-500 dark:text-zinc-400 mb-4 flex items-center gap-2">
  <a href="/" class="hover:text-zinc-700 dark:text-zinc-300">← All orders</a>
  <% if @meta['year'] %>
    <span class="text-zinc-300 dark:text-zinc-700">·</span>
    <a href="/?year=<%= @meta['year'] %>" class="hover:text-zinc-700 dark:text-zinc-300"><%= @meta['year'] %></a>
  <% end %>
</nav>

<% if hero_item %>
  <div class="mb-6 rounded-lg bg-zinc-100 dark:bg-zinc-900 ring-1 ring-zinc-200 dark:ring-zinc-800 overflow-hidden flex items-center justify-center">
    <% if hero_item['link'] %>
      <a href="<%= h(amazon_url(hero_item['link'])) %>" target="_blank" rel="noopener" class="block">
        <img src="<%= h(hero_item['image_link']) %>" alt="<%= h(hero_item['title']) %>" class="max-h-80 sm:max-h-96 w-auto object-contain p-6">
      </a>
    <% else %>
      <img src="<%= h(hero_item['image_link']) %>" alt="<%= h(hero_item['title']) %>" class="max-h-80 sm:max-h-96 w-auto object-contain p-6">
    <% end %>
  </div>
<% end %>

<div class="mb-6 flex items-start justify-between gap-4 flex-wrap">
  <div class="min-w-0">
    <div class="text-xs text-zinc-500 dark:text-zinc-400 font-mono"><%= h(@order_id) %></div>
    <h1 class="text-2xl font-semibold text-zinc-900 dark:text-zinc-100 mt-1">Order placed <%= relative_date(@order['order_placed']) %></h1>
    <% if @order['ship_to'] %>
      <p class="text-sm text-zinc-600 dark:text-zinc-400 mt-1">Shipped to <span class="text-zinc-800 dark:text-zinc-200"><%= h(@order['ship_to']) %></span><% if @order['ship_to_address'] %> · <span class="text-zinc-500 dark:text-zinc-400"><%= h(short_address(@order['ship_to_address'])) %></span><% end %></p>
    <% end %>
  </div>
  <% if @order['order_details_link'] %>
    <a href="<%= h(amazon_url(@order['order_details_link'])) %>" target="_blank" rel="noopener" class="text-xs text-amber-700 dark:text-amber-400 hover:text-amber-800 dark:hover:text-amber-300 shrink-0">View on Amazon →</a>
  <% end %>
</div>

<div class="grid md:grid-cols-3 gap-4 mb-6">
  <div class="md:col-span-2 rounded-lg border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900/40 p-5">
    <h2 class="text-sm font-semibold text-zinc-700 dark:text-zinc-300 uppercase tracking-wide mb-3">Items (<%= items.size %>)</h2>
    <% if items.empty? %>
      <div class="text-zinc-500 dark:text-zinc-400 text-sm italic">No items recorded for this order.</div>
    <% else %>
      <ul class="divide-y divide-zinc-200 dark:divide-zinc-800">
        <% items.each do |item| %>
          <li class="py-3 first:pt-0 last:pb-0 flex gap-4">
            <% if item['image_link'] %>
              <img src="<%= h(item['image_link']) %>" alt="" loading="lazy" class="w-20 h-20 rounded bg-zinc-100 dark:bg-zinc-800 object-contain shrink-0 ring-1 ring-zinc-200 dark:ring-zinc-800">
            <% else %>
              <div class="w-20 h-20 rounded bg-zinc-100 dark:bg-zinc-800 ring-1 ring-zinc-300 dark:ring-zinc-700 shrink-0"></div>
            <% end %>
            <div class="min-w-0 flex-1">
              <% if item['link'] %>
                <a href="<%= h(amazon_url(item['link'])) %>" target="_blank" rel="noopener" class="text-zinc-900 dark:text-zinc-100 hover:text-amber-700 dark:hover:text-amber-300 font-medium leading-snug"><%= h(item['title']) %></a>
              <% else %>
                <div class="text-zinc-900 dark:text-zinc-100 font-medium leading-snug"><%= h(item['title']) %></div>
              <% end %>
              <div class="text-xs text-zinc-500 dark:text-zinc-400 mt-1 flex flex-wrap items-center gap-x-3 gap-y-1">
                <% if item['seller'] %><span>sold by <span class="text-zinc-600 dark:text-zinc-400"><%= h(item['seller']) %></span></span><% end %>
                <% if item['quantity'] %><span>qty <%= h(item['quantity']) %></span><% end %>
              </div>
            </div>
            <div class="text-right shrink-0">
              <div class="font-medium tabular-nums text-zinc-900 dark:text-zinc-100"><%= money(item['price'], @order['currency'] || 'USD') %></div>
            </div>
          </li>
        <% end %>
      </ul>
    <% end %>
  </div>

  <aside class="rounded-lg border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900/40 p-5 self-start">
    <h2 class="text-sm font-semibold text-zinc-700 dark:text-zinc-300 uppercase tracking-wide mb-3">Summary</h2>
    <dl class="text-sm space-y-1.5">
      <% [['Subtotal', @order['subtotal']], ['Shipping', @order['shipping_total']], ['Tax', @order['estimated_tax']]].each do |label, val| %>
        <div class="flex justify-between gap-4"><dt class="text-zinc-600 dark:text-zinc-400"><%= label %></dt><dd class="tabular-nums text-zinc-800 dark:text-zinc-200"><%= money(val, @order['currency'] || 'USD') %></dd></div>
      <% end %>
      <div class="border-t border-zinc-200 dark:border-zinc-800 pt-2 mt-2 flex justify-between gap-4">
        <dt class="text-zinc-700 dark:text-zinc-300 font-semibold">Grand total</dt>
        <dd class="tabular-nums text-zinc-900 dark:text-zinc-100 font-semibold"><%= money(@order['grand_total'], @order['currency'] || 'USD') %></dd>
      </div>
      <% if @order['refund_total'] && @order['refund_total'] != 0 %>
        <div class="flex justify-between gap-4">
          <dt class="text-emerald-700 dark:text-emerald-400">Refunded</dt>
          <dd class="tabular-nums text-emerald-700 dark:text-emerald-400"><%= money(@order['refund_total'], @order['currency'] || 'USD') %></dd>
        </div>
      <% end %>
    </dl>
    <% if @order['payment_method'] %>
      <div class="mt-4 pt-4 border-t border-zinc-200 dark:border-zinc-800 text-xs text-zinc-500 dark:text-zinc-400">
        Paid with <span class="text-zinc-700 dark:text-zinc-300"><%= h(@order['payment_method']) %></span><% if @order['payment_method_last_4'] %> ending in <span class="font-mono text-zinc-700 dark:text-zinc-300"><%= h(@order['payment_method_last_4']) %></span><% end %>
      </div>
    <% end %>
  </aside>
</div>

<% trackable = shipments.reject { |s| s['delivery_status'].nil? && s['tracking_link'].nil? } %>
<% if trackable.any? %>
  <section class="rounded-lg border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900/40 p-5 mb-6">
    <h2 class="text-sm font-semibold text-zinc-700 dark:text-zinc-300 uppercase tracking-wide mb-3">Shipments</h2>
    <ul class="space-y-2">
      <% trackable.each do |s| %>
        <li class="flex items-center gap-3 text-sm">
          <% if s['delivery_status'] %><span class="text-zinc-800 dark:text-zinc-200"><%= h(s['delivery_status']) %></span><% end %>
          <% if s['tracking_link'] %><a href="<%= h(amazon_url(s['tracking_link'])) %>" target="_blank" rel="noopener" class="text-amber-700 dark:text-amber-400 hover:text-amber-800 dark:hover:text-amber-300 text-xs">tracking →</a><% end %>
        </li>
      <% end %>
    </ul>
  </section>
<% end %>

<details class="mt-4">
  <summary class="text-xs text-zinc-500 dark:text-zinc-400 cursor-pointer hover:text-zinc-700 dark:text-zinc-300">raw JSON</summary>
  <pre class="mt-2 bg-zinc-100 dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-800 rounded-lg p-4 overflow-x-auto text-xs text-zinc-700 dark:text-zinc-300"><%= h(JSON.pretty_generate(@order)) %></pre>
</details>

@@stats
<nav class="text-xs text-zinc-500 dark:text-zinc-400 mb-4"><a href="/" class="hover:text-zinc-700 dark:text-zinc-300">← All orders</a></nav>
<div class="mb-6">
  <h1 class="text-2xl font-semibold text-zinc-900 dark:text-zinc-100">Stats</h1>
  <p class="text-sm text-zinc-600 dark:text-zinc-400 mt-1">
    <%= @overall[:count] %> total orders ·
    <span class="text-zinc-800 dark:text-zinc-200 tabular-nums"><%= money(@overall[:total]) %></span> all-time
  </p>
</div>

<div class="rounded-lg border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900/40 overflow-x-auto">
  <table class="w-full text-sm min-w-[32rem]">
    <thead class="bg-zinc-100 dark:bg-zinc-900 text-zinc-600 dark:text-zinc-400 text-xs uppercase tracking-wide">
      <tr>
        <th class="text-left px-4 py-2">Year</th>
        <th class="text-right px-4 py-2">Orders</th>
        <th class="text-right px-4 py-2">Total</th>
        <th class="text-right px-4 py-2">Avg</th>
        <th class="text-right px-4 py-2">Largest</th>
      </tr>
    </thead>
    <tbody class="divide-y divide-zinc-200 dark:divide-zinc-800">
      <% max_total = @yearly.map { |_, s| s[:total] }.max || 1 %>
      <% @yearly.each do |year, s| %>
        <tr class="hover:bg-zinc-100 dark:bg-zinc-900/60">
          <td class="px-4 py-3"><a href="/?year=<%= year %>" class="text-amber-700 dark:text-amber-400 hover:text-amber-800 dark:hover:text-amber-300 font-medium tabular-nums"><%= year %></a></td>
          <td class="px-4 py-3 text-right tabular-nums text-zinc-700 dark:text-zinc-300"><%= s[:count] %></td>
          <td class="px-4 py-3 text-right tabular-nums text-zinc-900 dark:text-zinc-100">
            <div class="flex items-center justify-end gap-2">
              <div class="w-24 h-1.5 bg-zinc-100 dark:bg-zinc-800 rounded overflow-hidden hidden sm:block">
                <div class="h-full bg-amber-500 dark:bg-amber-500/60" style="width: <%= ((s[:total].to_f / max_total) * 100).round %>%"></div>
              </div>
              <span><%= money(s[:total]) %></span>
            </div>
          </td>
          <td class="px-4 py-3 text-right tabular-nums text-zinc-700 dark:text-zinc-300"><%= money(s[:avg]) %></td>
          <td class="px-4 py-3 text-right tabular-nums text-zinc-700 dark:text-zinc-300"><%= money(s[:max]) %></td>
        </tr>
      <% end %>
    </tbody>
  </table>
</div>
