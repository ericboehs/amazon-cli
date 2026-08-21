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
- **Subscribe & Save** — `amazon subscribe list` shows every subscription
  sorted by what ships next, with its cadence, discount, and price;
  `amazon subscribe upcoming` shows the deliveries themselves and the last
  day you can still change each one; `amazon subscribe show` opens one
  subscription in full. Reads cache for 30 minutes. `amazon subscribe skip`
  drops one item from the next delivery, `amazon subscribe cancel` ends a
  subscription for good, and `amazon subscribe schedule` changes quantity or
  cadence — all three need `--yes`, and all three prove it worked before
  saying so.
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
    secrets.rb          1Password reads, for sync and login
    thumbnail.rb        product photos in the terminal, via chafa
    subscribe.rb        `amazon subscribe …` dispatcher
    subscribe/          list, upcoming, show, skip, cancel, schedule
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
  subscriptions.py      Subscribe & Save scraper (subscriptions + deliveries)
  otp.py                TOTP secrets, shared by sync and login
  browser.py            shared Playwright session + selector fallbacks
  login.py              Playwright headed login, persists cookies
  test_live.py          unittest for the parsing helpers (no browser needed)
  test_subscriptions.py unittest for the S&S parsers, against captured markup
  fixtures/             scrubbed HTML captured from real pages
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
~/.local/share/amazon/cache/live/subscribe/     # 30-min Subscribe & Save cache
~/.local/share/amazon/cache/thumbs/             # product photos for --image
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

# 4) Optional: terminal product photos for `subscribe --image`
brew install chafa
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

`amazon login` uses both refs too: it types the password into the browser
window and answers the authenticator prompt with a code derived from
`otp_op_ref`, leaving the window open only for the things a human has to do —
a captcha, a "was this you?". It also clicks "Not now" on Amazon's
post-sign-in upsells, which is otherwise where the flow parks itself while
you're looking somewhere else. `--manual` turns all of that off. Note the
window is a throwaway Chrome profile with no extensions, so your password
manager's toolbar button isn't in it; that's what makes the autofill worth
having.

The `op://` references use the [1Password CLI](https://developer.1password.com/docs/cli/);
swap in your own password manager or just hardcode a value if you must.
`otp_op_ref` can point directly at a 1Password one-time-password field: `op
read` returns its `otpauth://` URI, and the worker extracts the TOTP secret
without persisting or logging it. The Python worker never logs credentials.

## Use

```bash
amazon login                  # browser login; fills password + 2FA from 1Password
amazon login --manual         # …or type them yourself
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

### Subscribe & Save

```bash
amazon subscribe list                 # every subscription, soonest delivery first
amazon subscribe list --all           # click past the first 30
amazon subscribe upcoming             # the next delivery, with prices
amazon subscribe upcoming --all       # every scheduled delivery
amazon subscribe show dishwasher      # one subscription in full, by id or by title
amazon subscribe skip bodymed         # what skipping it would do — changes nothing
amazon subscribe skip bodymed --yes   # actually drop it from the next delivery
amazon subscribe cancel syringes      # what cancelling would cost — changes nothing
amazon subscribe cancel syringes --yes --reason stopped_using
amazon subscribe schedule cascade                     # current schedule + what it accepts
amazon subscribe schedule cascade --qty 2 --every "2 months" --yes
amazon subscribe list --no-image      # plain table, no product photos
amazon subscribe list --fresh         # ignore the 30-minute cache
amazon subscribe upcoming --json | jq '.[0].subtotal'
```

```
$ amazon subscribe list --no-image
next              every     qty  price   subscription_id             item
September 2       2 months  1    $14.22  SNSD0_CPWMW84DZS0X826Y8P77  Gain Liquid Laundry Deterge…
September 30      6 months  1    15%     SNST0_3DDC5AB24AB74C1087BE  Amazon Basic Care All Day A…
October 28        3 months  1    15%     SNST0_FA2F200C1C3C40AE9F9B  Clorox Clean-Up Multi-Surfa…
showing 30 of 59 — pass --all for the rest
```

```
$ amazon subscribe upcoming --no-image
Sep 2  3 items  $48.95  · next
  Last day to edit delivery: Thursday, August 27
  Estimated savings for this delivery: $1.95
  Add 2 more subscriptions to this delivery and unlock extra savings up to 15%.
     $14.22  Gain Liquid Laundry Detergent, Freshness, Odor De…  Saving 5%
     $11.99  BodyMed Adjustable Heel Lift for Men and Woman, S…
     $22.74  Viva Multi-Surface Cloth Paper Towels, 12 Super R…  Saving 5%
6 more deliveries scheduled — pass --all
```

With `--all`, the later boxes print too — with a rate instead of a price,
because Amazon hasn't set one:

```
September 30  16 items
             Cascade Free & Clear Dishwasher Detergent Liquid …  Saving 15%
             …
```

Two views of the same account, because Amazon keeps them on separate pages
and each knows something the other doesn't. `list` is per-subscription:
everything you're subscribed to and how often it ships. `upcoming` is
per-shipment: those subscriptions regrouped into the boxes Amazon will
actually send and charge for. `show` is the third page — one subscription's
edit modal, which is the only place the ASIN, the seller, the backup item,
and the running savings total live.

```
$ amazon subscribe show dishwasher
Cascade Free & Clear Dishwasher Detergent Liquid Gel, Lemon, 75oz

  next delivery    Wednesday, September 30 (arrives by)
  schedule         1 unit every 1 month
  discount         Get it now with 5% off
  saved so far     $16.92
  sold by          Amazon.com and top rated sellers
  asin             B08R7FB5JS
  backup item      none
  subscription id  SNSD0_JW5SC777SESY1WWWNZPK
```

A subscription id is 26 characters nobody types twice, so `show` also takes
words from the product title. A search matching more than one prints the
matches and stops rather than picking for you — `show` is what you run before
deciding what to cancel.

**Prices come from the deliveries view.** A subscription card renders none:
the price isn't settled until the delivery is assembled and its tier discount
(5% → 15%, by item count in that one box) is known. So `list` reads both
pages and joins them on subscription id. Only the delivery shipping next is
priced; the rest show the rate they'll get without an amount, which is why
the price column holds `15%` rather than a number. A `$0.00` there would be a
lie. If the deliveries view fails, the schedules still print and stderr says
what's missing.

`list` is sorted by next delivery date, soonest first. Amazon's own order
interleaves September, March, and December — there is nothing in it to
preserve.

The list page loads 30 subscriptions and hides the rest behind a "show more"
button, so plain `list` says `showing 30 of 59 — pass --all for the rest`
rather than pretending 30 is all of them. `--all` clicks through (a few
seconds for 59). If pagination stalls, you get the partial list plus a
warning on stderr — never a short list that looks complete.

Amazon schedules deliveries months ahead — seven of them, 84 item lines, on
the account this was built against — so `upcoming` prints the next one and
says how many more there are. That's not just brevity: the next delivery is
the only one with prices, an edit deadline, and anything you can still do
about it. The rest are a forecast of what March might hold, at a discount
rate that changes with whatever else lands in the box. `--limit N` and
`--all` override it. `--json` ignores both: a caller piping to `jq` asked for
the data, not for the next box.

#### Skipping a delivery

`skip` is the only subcommand here that changes anything, and it won't
without `--yes`:

```
$ amazon subscribe skip bodymed
would skip BodyMed Adjustable Heel Lift for Men and Woman, Small (1-Pack)
  from the Sep 2 delivery
  This will cancel your order. You may lose applied coupons.
  nothing changed — pass --yes to skip it
```

That warning is Amazon's sentence, not ours. The dry run is not a simulation:
it drives the real flow up to the last click and reads back the confirmation
dialog Amazon rendered, which is the only description of what skipping means
that can't go stale. It exits 2, because a script that forgot `--yes` should
be able to tell that nothing happened.

With `--yes` the skip is confirmed and then **verified by re-reading the
delivery**. A click that returns without error is not evidence — Amazon's
dialog closes the same way whether the skip took or not — so the three
outcomes stay three: it left the box, it's still there (say so loudly), or
the re-read failed and we can't say. "We couldn't confirm" and "it didn't
work" are different things to tell someone about their account.

Only the next delivery can be skipped, and only until its last-edit date;
`upcoming` shows both. Later deliveries have no Skip button in Amazon's
markup at all, because there's nothing to skip until a box is being
assembled. A search that matches something in a *later* delivery gets told
what's in this one instead of "no such thing". Ambiguous searches refuse to
pick: skipping the wrong item means something you needed doesn't arrive.

One subscription per invocation. Two bare words is far more likely to be a
two-word search that lost its quotes than a request to skip two things.

A confirmed skip drops all three cached views, since the delivery it just
changed is in every one of them.

#### Cancelling a subscription

`cancel` ends the subscription outright. Same contract as `skip` — nothing
without `--yes`, and the dry run is Amazon's own page read back:

```
$ amazon subscribe cancel syringes
would cancel Care Touch Disposable Syringes Without Needle Luer Lock
  next delivery September 30
  You have saved $3.90 on this subscription!
  You will no longer receive your Subscribe & Save discount.
  We will cancel any orders of this item that haven't yet entered the delivery process.
  reasons: no_more_needed, stopped_using, different_flavor_brand_scent, …
  nothing changed — pass --yes to cancel it
```

That second consequence is the reason this prints before it acts: cancelling
doesn't just stop future deliveries, it pulls the item out of the box already
being assembled. "Cancel" doesn't sound like that, and Amazon's sentence says
it better than a paraphrase would.

Verification pages through your **entire** active list, not the first thirty.
A subscription that lived on page two is missing from page one whether or not
the cancel worked, and a check that can only return "yes" isn't a check.

The reason is optional — Amazon says so on the page — so none is sent unless
you pass `--reason`. The keys come off Amazon's own dropdown at runtime
(`stopped_using`, `accident`, `product_too_expensive`, …), which is why the
dry run can list them and why a reason Amazon adds later needs no code change
here. An unrecognised one is refused *before* the confirm click: a
cancellation that went through with the wrong reason attached can't be taken
back.

Cancelling is not reversible from this CLI. Amazon's page notes you can
reactivate an item later on the website.

#### Changing quantity and cadence

```
$ amazon subscribe schedule cascade --qty 2 --every "2 months"
would change Cascade Free & Clear Dishwasher Detergent Liquid Gel, Lemon, 75oz
  quantity       1 → 2
  frequency      1 month → 2 months
  next delivery  September 30 → October (Amazon's form sets this too)
  Note: This will change how often you receive deliveries for this item, which
  may also change discounts on some upcoming orders.
  choices: quantity 1, 2, 3 · frequency 2 weeks…12 months (14) · next September…April (8)
  nothing changed — pass --yes to apply
```

With no flags it just prints that — the current schedule and everything Amazon
will accept for this item. Worth running first: quantity caps are per product,
and they are not what you'd guess. Cascade allows 1–3; a box of syringes
allows 1–30.

**Read the `next delivery` line.** Amazon puts quantity, frequency and the
next delivery date in one form behind one Apply button, and its date dropdown
does not always hold the date your subscription currently shows — on this
account it offered October 3 for a subscription arriving September 30. So
applying a quantity change also moves the delivery. That row prints the move
whether or not you asked for it, and stays quiet when the form already agrees.

`--every` takes what you'd say out loud: `"2 months"`, `2mo`, `3 weeks`, `3w`.
Amazon's own `2-m` works too. `--next` takes a month name. Anything Amazon
doesn't offer for that item is refused *before* the form is touched, with the
list of what it does — a form submitted with a bad value has already changed
the schedule by the time you read the error.

Unlike `skip` and `cancel`, this one is reversible: run it again. Verification
re-reads your subscription list and compares the cadence the card now states
against what you asked for.

All three read-only views cache for 30 minutes, and a cached read says its age on stderr
(`[cached 12 minutes ago — --fresh to re-read]`) — a schedule you changed on
the website twenty minutes ago and one that never changed look identical
otherwise. `--fresh` on any of them drops all three, since they describe one
account; when write commands land they will invalidate through the same door.

`list`, `upcoming`, and `show` draw the product photo beside each entry when
they're printing to a terminal; `--no-image` gives you the plain table.
Rendering is chafa's job, not this CLI's: it negotiates with the terminal and
emits kitty graphics, sixel, or unicode half-blocks depending on what
answered, which is a thing to shell out to rather than reimplement worse. The
table gives way to one block per subscription, because six columns and a
photograph is a wall.

```
$ amazon subscribe list
┌────────┐  Gain Liquid Laundry Detergent, Freshness, Odor Defense, 154 fl oz
│ (photo)│  September 2 · every 2 months · $14.22
└────────┘  SNSD0_CPWMW84DZS0X826Y8P77

$ amazon subscribe upcoming
Sep 2  3 items  $48.95  · next
  Last day to edit delivery: Thursday, August 27
┌────┐  Gain Liquid Laundry Detergent, Freshness, Odor Defense
│    │  Scent Original, Size 132 Fl Oz (Pack of 1)
└────┘  $14.22  Saving 5%
```

The photos in `upcoming` are smaller, because those items are already nested
under a delivery heading and one delivery can hold eighteen of them. The price
moves off the front of the line and onto its own: a price column indented past
a photograph is a column of one.

Images are skipped when stdout isn't a terminal or chafa isn't installed — a
pipe gets the table, not megabytes of escape codes. That happens silently
unless you typed `--image` explicitly, because a default that can't run
shouldn't make every `| grep` apologise for a feature nobody asked for.
Photos are cached on disk by URL and size, so the second run draws instantly.

Two things about that layout were measured rather than assumed, and both were
wrong on the first try. chafa fits a photo *within* the box instead of filling
it, so a wide product shot comes back three rows tall in a six-row block; and
Ruby counts `Clorox®` as six characters where the terminal draws seven cells,
so a line that fits by `String#length` can wrap. Either one makes a block a
different height than the arithmetic believes, which puts the next photograph
through the middle of its own caption. The fix is to stop counting: wrapping
is disabled across the block, and the cursor is saved after the text and
restored after the image.

Finding the photos had its own trap. Amazon lazy-loads everything below the
fold, so `src` on those cards is a 35-byte grey pixel and the real URL waits
in `data-a-hires`. Both are strings ending in a plausible filename, so reading
`src` produces JSON that looks complete and a list where the first screenful
has pictures and the rest have grey smudges. The fixtures carry that markup,
and a test asserts they still do.

Read-only for now: nothing here skips, reschedules, or cancels anything.

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

`pyworker/test_subscriptions.py` runs the Subscribe & Save parsers against
scrubbed HTML captured from the real pages (`pyworker/fixtures/`), so the
selectors are checked against markup Amazon actually served rather than
markup I remembered. The fixtures carry fake subscription ids, ship ids,
CSRF tokens, product titles, and addresses; nothing in them identifies an
account, and the edit-modal test asserts that no address or payment method
reaches the output at all. That claim is now enforced rather than promised:
`FixtureHygieneTest` scans every fixture for anything shaped like a captured
credential. It exists because the hand-written scrub missed three of the four
ways Amazon spells a CSRF token — an `anti-csrftoken-a2z` input with `type=`
between the name and the value, a `csrfT=` query parameter, and a `"csrfT":`
JSON key — and two live tokens rode along in `review_listing.html` for a
whole release. A scrub only covers the spellings someone thought of.
Pagination is exercised against a fake page that
reproduces one measured Amazon quirk: clicking "show more" grows the DOM but
leaves the server-rendered `loadedItemCount` frozen at its original value.
Believing that counter is an infinite loop, and the fake is built to fail
that way.

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
/usr/bin/python3           -m unittest discover -s pyworker -p 'test_*.py'  # 84 skips
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
