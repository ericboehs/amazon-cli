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
  5★ ███████████████████████   96%
  4★                            2%
  3★                            1%
  2★                            0%
  1★                            1%

Authenticity
  high risk (89/100, low confidence)
    !  Rating distribution: 96% five-star with only 3% two-to-four-star and a 1% one-star tail; organic ratings keep a fatter middle [+20/20]
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
`otp_op_ref` can point directly at a 1Password one-time-password field: `op
read` returns its `otpauth://` URI, and the worker extracts the TOTP secret
without persisting or logging it. The Python worker never logs credentials.

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
product page `amazon item` already fetches. `--pages N` (0–10) is what opens
`/product-reviews/`, which serves ten reviews and paginates by appending ten
more each time its "Show 10 more reviews" button is clicked. So `--pages 10`
samples up to ~100 reviews, one page load and nine clicks. There is no numbered
pager on that listing and `?pageNumber=` is ignored, so a URL walk re-reads the
first ten however many times you ask for.

**What the score means.** Seven deterministic checks run over the sample:

| Check | Weight | Fires on |
|---|---|---|
| Rating distribution | 20 | a five-star wall with no organic middle |
| Verified purchases | 20 | a high unverified share (how many of those are glowing is reported, not scored) |
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

Thresholds are calibrated against real listings, not intuition. Four
unrelated and apparently legitimate products — including a 30k-rating Anker
charger — all sat at 79-83% five-star with a 13-18% middle and a 3-4%
one-star tail. That is simply the Amazon baseline for consumer goods, so
the histogram check only scores a shape well past it. A signal that fires
on everything teaches you to ignore the report.

`--pages N` needs a currently valid session; `/product-reviews/` redirects
to sign-in even when `/dp/` still renders for a stale one. When that leg
fails the report is still produced from the product-page sample, with a
warning, rather than thrown away.

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

### Guards that can't fail

Delete the fix, run the suite, watch the named test fail. Then put the fix
back and commit. A test written for a specific hazard is worth exactly the
failure it can produce, and four in this repo produced none:

- **A test that mirrored the code instead of calling it.** The cookie-jar
  restore assertions ran against a hand-copied duplicate of the closure in
  `main()`, so the real one could change underneath them and they'd stay
  green. Fixed by extracting `restore_jar` and calling it.
- **A test that skipped in the one place it was for.** `PackageAssumptionsTest`
  checks our fixtures against the installed amazon-orders — and CI runs a bare
  interpreter with no install step, so it skipped there every time. Fixed by
  adding a second CI job that installs the deps (`python-deps-test`).
- **A test whose hazard the fake couldn't express.** `test_the_style_leak_still_reproduces`
  asserted that CSS gets stripped from scraped text, but bs4 sorts `<style>`
  contents into a `NavigableString` subclass that `get_text()` skips — so there
  was never any CSS to strip. Deleting `without_style_nodes` outright left the
  entire suite green.
- **The same trap, one branch over.** After that was fixed in the fake's
  rendered branch, its unrendered branch still used `get_text()` — and the
  unrendered branch is the one the real leak travelled through, since
  `#availability_feature_div` had no layout box on the live page. Found by
  simulating a reviewer's concern rather than arguing about it: modelling the
  accordion collapse pessimistically moved exactly one assertion, and it moved
  because the fake was wrong.

A guard can also fail to fail because it never ran. The uv project is
`pyworker/`, not the repo root, so `uv run` from the root builds an empty
environment — 27 tests skip and the run still reports `OK`, which looks
identical to a pass. Two commands are honest about which suite you got:

```sh
pyworker/.venv/bin/python -m unittest discover -s pyworker -p 'test_*.py'  # 0 skips
/usr/bin/python3           -m unittest discover -s pyworker -p 'test_*.py'  # 27 skips
```

The first is what `python-deps-test` runs; the second stands in for
`python-test`. A skip count from anywhere else is not evidence about either.

The last two bullets share a cause worth stating on its own: a fake that
stands in for a browser is itself untested code, and it will agree with
whatever you believed when you wrote it. `DomFakeFidelityTest` exists to hold it against measurements
taken from real Chrome rather than from the spec — `innerText` has three
branches that a reasonable reading gets wrong, and each has a test naming the
measured behaviour:

| markup | layout box | `innerText` |
|---|---|---|
| `display: none` | no | full descendant text — the `textContent` fallback |
| rendered, with a `display: none` child | yes | own text; the child contributes nothing |
| `visibility: hidden` | yes | `""` — and a `visibility: visible` child still comes through |

The list is expected to grow. Add to it when you find the next one; the entry
that helps is the one that says what the guard *looked* like it covered.

### Zeros that don't say what they looked at

Selector rot is this repo's loudest failure, and its quietest one is the same
bug seen from the other side: a healthy zero and a broken zero print the same
characters. `amazon order sync` reported `year 2026: 0 orders` for an account
holding 222 of them, because the `total` event sent one number where three
were needed — Amazon listed nothing, and everything Amazon listed was already
on disk, arrived as the same `0`.

The rule the CLI now follows is that no empty result is printed alone; it is
printed next to what was searched to produce it. `(no orders)` became
`(no orders — nothing from 1995 among your 4,257 stored orders; stored years:
2008–2026)`, and silence about purchase history became either `not in your
4,257 stored orders` or `no local orders to check`. The old line had a second
tell worth noting: it advised running `amazon sync`, which is not a subcommand.
Advice printed on a path nobody exercises rots the same way a selector does.

Tests for this shape assert the *distinction*, not the wording — two runs that
used to produce byte-identical output are asserted to differ
(`refute_equal unsynced, filtered`). A wording assertion passes as soon as the
substring appears anywhere; only the inequality fails when the two cases
collapse back together, which is the actual bug.

The `--json` path needs the denominator more than the terminal does, not less:
a human might smell something off about `"purchases": []`, and a script acting
on it unattended won't. `Formatter#item` dumps `data` wholesale, so
`purchases_searched` reached JSON as a side effect of a `merge` in `item.rb` —
true, but true by accident. That's the inverse of a guard that can't fail:
not an assertion incapable of failing, but a contract with no assertion at
all, and it is just as quiet. Stripping the key left every human-facing test
green. `test_the_json_payload_carries_the_denominator_too` is what a future
refactor now has to argue with.

Where the ambiguity can be removed instead of documented, remove it.
`Formatter#list` and `#search` take `scope:` as a required keyword, not a
nilable one — the fallback it would otherwise need was reachable only from the
tests proving it worked.

## License

MIT. See [LICENSE](./LICENSE).

## Acknowledgements

- [`amazon-orders`](https://pypi.org/project/amazon-orders/) by Alex Laird —
  does the actual HTML parsing.
- [Playwright](https://playwright.dev/python/) for the headed login flow.
