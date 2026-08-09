# amazon-cli

Amazon from the terminal: a personal order-history archiver *and* live
product lookup. Logs you in via a real browser (handles captcha + 2FA),
pulls every order down into a local JSON store, and — because the same
session works for product pages — answers "what does this cost right now,
and when would it get here?" without opening a tab.

There is no public Amazon API for either half. Order history is handled by
[`amazon-orders`](https://pypi.org/project/amazon-orders/); live lookups are
Playwright driving your signed-in session. This repo is the glue: a Ruby
CLI, a Python worker, and a single-file Sinatra web UI.

Live search knows what you've bought before:

```
$ amazon search "pla filament 1.75mm" --no-sponsored

   $12.99  B0747R1M51  16-Color 320ft PLA 3D Pen Filament Refills - 1.75mm…
           4.6★ · (4,640) · FREE delivery Tue, Jul 28
           ↳ bought 2023-12-10 for $17.99  (-$5.00)

   $41.24  B0DWK3YSVV  250g PLA Filament 1.75mm Bundle, SUNLU, 8 Rolls…
           4.4★ · (1,275) · FREE delivery tomorrow
```

```
$ amazon item B0747R1M51
16-Color 320ft PLA 3D Pen Filament Refills - 1.75mm, Kids Safe, 250 Stencils eBook
B0747R1M51  ·  https://www.amazon.com/dp/B0747R1M51

  Price:     $12.99
  Stock:     In Stock
  Delivery:  FREE delivery Tue, Jul 28
  Seller:    Dikale US
  Rating:    4.6★ (4,640 ratings)

You've bought this 1x
  2023-12-10     $17.99  (-$5.00)  111-5881012-0199422
```

Reviews get read *as evidence*, not as a star average:

```
$ amazon reviews B0DEMO1234
65W USB-C GaN Fast Charger, 3-Port Compact Wall Adapter
B0DEMO1234  ·  https://www.amazon.com/dp/B0DEMO1234

  Overall:   4.5★  1,842 ratings
  Adjusted:  2.25★  verified, uncompensated reviews in this sample only
  Verified:  50% of 10 sampled
  Vine:      1 review(s) from Amazon's Vine programme

Rating distribution
  5★ ████████████████████      82%
  4★ █                          6%
  3★                            2%
  2★                            2%
  1★ ██                         8%

Authenticity
  high risk (76/100, low confidence)
    !  Rating distribution: 82% five-star and only 10% two-to-four-star; organic ratings keep a fatter middle [+11/20]
    !  Verified purchases: 5/10 sampled reviews are unverified (5 of them 4★ or better) [+20/20]
    ?  Review timing: needs 15+ dated reviews (have 10) — re-run with --pages 3
    !  Distinct wording: 2/6 reviews share heavily overlapping wording with another [+12/15]
    !  Undisclosed compensation: 2/10 reviews mention a free or discounted unit outside the Vine programme [+7/10]
    ?  Reviews match the product: needs a descriptive title and 25+ reviews with text (have 10) — re-run with --pages 3
    !  Distinct reviewers: 1 reviewer name(s) appear more than once [+3/5]
    Heuristics on a 10-review sample, not a verdict. Use --pages 3 for a deeper sample.

What critical reviews mention
  · stopped charging (3x)
  · port stopped (2x)
  · three weeks (2x)
  · hot (2x)
```

```
$ amazon order list --year 2025 --limit 3
date        order_id             total    status
2025-12-28  113-...-...          $42.18
2025-12-26  111-...-...          $19.99
2025-12-22  002-...-...          $137.50
```

## Features

- **Real-browser login** — Playwright opens Chrome, pre-fills your email,
  you finish password + 2FA + captcha. Cookies persist; subsequent
  syncs and lookups are silent.
- **Live product lookup** — `amazon item` and `amazon search` hit Amazon
  now, returning current price, stock, seller, rating, and a delivery-by
  date personalized to your default address.
- **Review research** — `amazon reviews` pulls the sample Amazon renders on
  the product page (`--pages N` walks deeper), summarizes what critical
  reviewers actually complain about, and screens the sample for
  manipulation: histogram shape, unverified share, date bursts, duplicated
  phrasing, incentivized language, review hijacking, repeat reviewers. Every
  signal is itemized with its weight, and checks that couldn't run say so
  instead of quietly passing.
- **Price memory** — live results are cross-referenced against your order
  archive, so anything you've bought before shows the date and price you
  paid, plus the delta.
- **Incremental sync** — only fetches orders not already on disk. A `--full`
  flag re-fetches everything.
- **Parallel detail fetches** — `ThreadPoolExecutor` with a tunable worker
  pool, plus per-request jitter and 503 backoff to stay under Amazon's
  rate limits.
- **JSON-first storage** under XDG paths — easy to grep, jq, back up, or
  feed into other tools.
- **Web UI** (`web.rb`) — single-file Sinatra app with light/dark mode,
  density modes, gallery view, refunds, search, and a 95% test
  coverage gate.

## Architecture

```
bin/amazon              Ruby entrypoint (subcommand dispatch)
lib/amazon/
  cli.rb                arg parsing, dispatch
  commands/
    item.rb             live product detail
    reviews.rb          review report + authenticity screen
    search.rb           live product search
    order.rb            `amazon order …` dispatcher
    order/              sync, list, show, search over the local archive
    login.rb, config.rb, buy.rb
  config.rb             XDG paths, config load
  store.rb              JSON read/write, index, ASIN purchase history
  cache.rb              short-TTL disk cache for live lookups
  reviews.rb            review-manipulation heuristics (pure, no I/O)
  worker.rb             spawns Python workers, parses NDJSON over stdout
  formatter.rb          tables, live output, --json, color
pyworker/
  fetch.py              order history: drives amazon-orders, emits NDJSON
  live.py               live product/search scraper
  browser.py            shared Playwright session + selector fallbacks
  login.py              Playwright headed login, persists cookies
  test_live.py          unittest for the parsing helpers (no browser needed)
  pyproject.toml        deps: amazon-orders, playwright
web.rb                  single-file Sinatra browser
test/web_test.rb        Minitest, 95% line + branch coverage gate
test/cli_test.rb        Minitest, 99% line / 95% branch coverage gate
```

Two-process design: Ruby owns the CLI/UX/storage; Python owns the scraping.
Workers are one-shot subprocesses — no daemon. Communication is NDJSON over
stdout; prompts (OTP, etc.) round-trip through the worker's stdin.

`fetch.py` and `live.py` are separate entrypoints because they solve
different problems: order history goes through `amazon-orders`, while live
pages need a real browser to render the buybox and delivery block. Both
reuse the session that `amazon login` persisted.

## Storage layout (XDG)

```
~/.config/amazon/config.json                    # email + 1Password ref
~/.local/share/amazon/index.json                # order_id → file map
~/.local/share/amazon/orders/<year>/<id>.json   # one file per order
~/.local/share/amazon/cache/cookies.json        # session reuse (mode 600)
~/.local/share/amazon/cache/storage_state.json  # full Playwright state
~/.local/share/amazon/cache/live/{item,item-reviews,search,reviews}/
                                                # 15-min live-lookup cache
~/.local/state/amazon/sync.log                  # sync history
```

Per-order files include items (with ASIN links + image URLs), shipments,
recipient, payment method last-4, subtotal, shipping total, tax, refunds,
and a `_synced_at` timestamp.

## Setup

```bash
git clone https://github.com/ericboehs/amazon-cli ~/Code/ericboehs/amazon-cli
cd ~/Code/ericboehs/amazon-cli

# 1) Install Python deps
cd pyworker
uv venv && uv pip install -e .
uv run playwright install chromium   # only needed if Chrome.app isn't installed

# 2) Symlink the entrypoint
chmod +x ../bin/amazon
ln -sf "$PWD/../bin/amazon" ~/bin/amazon

# 3) Create config
amazon config edit
```

`~/.config/amazon/config.json`:

```json
{
  "email":           "you@example.com",
  "password_op_ref": "op://Personal/Amazon/password",
  "otp_op_ref":       null,
  "default_year_window": 2,
  "output": { "color": true }
}
```

The `op://` references use the [1Password CLI](https://developer.1password.com/docs/cli/);
swap in your own password manager or just hardcode a value if you must.
The Python worker never logs the password.

## Use

```bash
amazon login                  # one-time browser login (handles captcha + 2FA)
```

### Live (queries Amazon now)

```bash
amazon search "raspberry pi"              # live listings
amazon search "usb c cable" --limit 20 --no-sponsored
amazon item B0747R1M51                    # live price / stock / delivery
amazon item https://www.amazon.com/dp/B0747R1M51   # URLs work too
amazon item B0747R1M51 --fresh            # bypass the 15-minute cache
amazon item B0747R1M51 --json | jq .delivery_date
amazon item B0747R1M51 --reviews          # detail plus a one-block review verdict
```

Live results are cached on disk for 15 minutes under
`~/.local/share/amazon/cache/live/`, so re-running a search or piping the
same lookup into `jq` twice doesn't re-hit Amazon. `--fresh` skips the read
but still writes, so the next plain run gets the refreshed answer. Empty
results are never cached — a lookup that found nothing is usually a blocked
or half-loaded page, and caching it would pin the failure for 15 minutes.

`--no-sponsored` drops listings Amazon tagged "Sponsored". When the tag
can't be read at all, those listings are kept and a note is written to
stderr — dropping unknowns would silently hide organic results.

Delivery dates come from your signed-in session and reflect your default
shipping address. If Amazon serves a captcha instead of the page, the CLI
says so — re-run `amazon login` to refresh the session.

### Reviews (research + fake-review screening)

```bash
amazon reviews B0747R1M51                 # the ~8 reviews on the product page
amazon reviews B0747R1M51 --pages 3       # walk /product-reviews/ for a deeper sample
amazon reviews B0747R1M51 --sort recent   # default is "helpful"
amazon reviews B0747R1M51 --verbatim      # print the review text, not just the summary
amazon reviews B0747R1M51 --critical      # only the 1-3★ reviews (implies --verbatim)
amazon reviews B0747R1M51 --limit 5       # cap how many verbatim reviews print
amazon reviews B0747R1M51 --json | jq .analysis.signals
amazon item B0747R1M51 --reviews          # condensed: product detail + verdict
```

The default costs no extra page load — the sample rides along on the same
product page `amazon item` already fetches. `--pages N` (0–10) is what
actually walks `/product-reviews/`, one request per page.

**What the score means.** Seven deterministic checks run over the sample:

| Check | Weight | Fires on |
|---|---|---|
| Rating distribution | 20 | a five-star wall with no organic middle |
| Verified purchases | 20 | a high unverified share, worse if those are the positive ones |
| Review timing | 20 | bursts of reviews inside a 7-day window |
| Distinct wording | 15 | near-duplicate phrasing across reviews (Jaccard on content words) |
| Undisclosed compensation | 10 | free/discounted-unit language outside Vine |
| Reviews match the product | 8 | reviews describing a different item than the title (review hijacking) |
| Distinct reviewers | 5 | the same reviewer name appearing repeatedly |

A check that can't run on the sample you fetched leaves the **denominator**
rather than scoring zero — so a thin sample reports "low confidence" and
lists what it couldn't test, instead of reading as a clean bill of health.
Vine reviews are tracked separately from undisclosed compensation: Vine is
disclosed and legitimate, it just isn't a purchase.

`Adjusted` re-averages only the verified, non-Vine, uncompensated reviews
*in the sample* — it is not a corrected sitewide rating, and it's omitted
when fewer than three reviews qualify.

This is a screen, not a verdict. It reports evidence and its own limits;
deciding what to do with a 60/100 is yours. (The tools that used to do this
as a service are gone — Mozilla shut Fakespot down in July 2025, ReviewMeta
followed — and the replacements have no public API, hence local heuristics.)

### Your orders (local archive)

```bash
amazon order sync                   # default window (last 2 years)
amazon order sync --year 2018       # one specific year
amazon order sync --years 2010,2011 # several years
amazon order sync --full            # re-fetch everything (default skips known)

amazon order list --year 2025 --limit 25   # a "~" total is estimated, not charged
amazon order show 111-2222222-3333333
amazon order search "raspberry pi"  # searches history, not the live catalog
amazon order list --json | jq '[.[] | .total | tonumber] | add'

ruby web.rb                         # http://localhost:4567
```

Some older orders don't expose a grand total in Amazon's HTML. For those,
the archive falls back to `total_before_tax` and then `subtotal`, records
which field it used, and `order list` prefixes the number with `~` — an
estimate that excludes tax (and, from a subtotal, shipping too).

> **Note:** `search` is live. To search what you've already bought, use
> `amazon order search`. The order commands used to live at the top level
> (`amazon list`, `amazon sync`, …); they now require the `order` prefix,
> and the old spellings print a pointer to the new one.

## Tuning sync speed

The worker honors `rate_limit` keys in `config.json` plus the worker pool
size (`workers`, default 7):

```json
{
  "rate_limit": {
    "detail_delay":  0.05,
    "detail_jitter": 0.05,
    "retry_backoff": [30, 60, 120]
  }
}
```

Bump `workers` up cautiously — Amazon starts handing back HTTP 503s above
~7 concurrent detail fetches in my testing.

## Testing

```bash
ruby test/web_test.rb                              # 95% line + branch gate
ruby test/cli_test.rb                              # 99% line / 95% branch gate
python -m unittest discover -s pyworker -v         # parsing helpers
```

`cli_test.rb` never touches the network: the NDJSON protocol in
`worker.rb` is driven against a stub subprocess, and everything above it is
exercised directly. Only the browser login and `order sync` — which drive a
real Chrome window and shell out to `op` — are filtered out of the coverage
gate and verified by running them for real.

`pyworker/test_live.py` covers the fiddly pure functions — ASIN extraction
from URL shapes, money parsing, the delivery-date parser (Amazon omits the
year, so December→January has to roll forward), and the review-card parsers
(day-first international dates, "One person found this helpful", histogram
labels in either percent-first order).

`lib/amazon/reviews.rb` is pure and does no I/O, so it's tested directly
against synthetic listings — a farmed one it should flag and a genuine one
it must not. False positives there would discredit every other signal, so
the mismatch and burst checks are deliberately conservative and abstain on
small samples rather than guess.

What isn't unit-tested is selector drift: Amazon A/B tests product-page
markup constantly. Every field is looked up through a list of fallback
selectors; optional fields that go missing degrade to `null`, and a page
with no title at all is treated as "not a product page" and raises. When
three or more of the six expected fields come back empty, the worker emits
a `warn` log saying the markup may have changed — but a single blanked
field can still slip through, and only a real run will show it.

## License

MIT. See [LICENSE](./LICENSE).

## Acknowledgements

- [`amazon-orders`](https://pypi.org/project/amazon-orders/) by Alex Laird —
  does the actual HTML parsing.
- [Playwright](https://playwright.dev/python/) for the headed login flow.
