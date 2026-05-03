# amazon-cli

A personal Amazon order-history archiver. Logs you in via a real browser
(handles captcha + 2FA), pulls every order down into a local JSON store,
and ships a CLI plus a small web app for browsing and search — fully
offline once synced.

There is no public Amazon API for this; the heavy lifting is done by
[`amazon-orders`](https://pypi.org/project/amazon-orders/) (HTML scraping
behind the authenticated session). This repo is the glue: a Ruby CLI, a
Python worker, a Playwright login flow, and a single-file Sinatra web UI.

```
$ amazon list --year 2025 --limit 5
date        order_id             total    status
2025-12-28  113-...-...          $42.18
2025-12-26  111-...-...          $19.99
2025-12-22  002-...-...          $137.50
2025-12-19  113-...-...          $8.49
2025-12-18  111-...-...          $63.20

$ amazon search filament
2024-08-12  113-...-...  $24.99   PolyTerra PLA Filament 1.75mm Charcoal Black
2023-11-03  111-...-...  $89.97   3-pack Hatchbox PLA 1.75mm
...
```

## Features

- **Real-browser login** — Playwright opens Chrome, pre-fills your email,
  you finish password + 2FA + captcha. Cookies persist; subsequent
  syncs are silent.
- **Incremental sync** — only fetches orders not already on disk. A `--full`
  flag re-fetches everything.
- **Parallel detail fetches** — `ThreadPoolExecutor` with a tunable worker
  pool, plus per-request jitter and 503 backoff to stay under Amazon's
  rate limits.
- **JSON-first storage** under XDG paths — easy to grep, jq, back up, or
  feed into other tools.
- **CLI**: `sync`, `list`, `show`, `search`, `login`, `config`, plus a
  stubbed `buy` for v2.
- **Web UI** (`web.rb`) — single-file Sinatra app with light/dark mode,
  density modes, gallery view, refunds, search, and a 95% test
  coverage gate.

## Architecture

```
bin/amazon              Ruby entrypoint (subcommand dispatch)
lib/amazon/
  cli.rb                arg parsing, dispatch
  commands/             one class per subcommand
  config.rb             XDG paths, config load
  store.rb              JSON read/write, index management
  worker.rb             spawns Python worker, parses NDJSON over stdout
  formatter.rb          tables, --json, color
pyworker/
  fetch.py              one-shot worker: drives amazon-orders, emits NDJSON
  login.py              Playwright headed login, persists cookies
  pyproject.toml        deps: amazon-orders, playwright
web.rb                  single-file Sinatra browser
test/web_test.rb        Minitest with 95% line + branch coverage gate
```

Two-process design: Ruby owns the CLI/UX/storage; Python owns the scraping.
The worker is a one-shot subprocess — no daemon. Communication is NDJSON
over stdout; prompts (OTP, etc.) round-trip through the worker's stdin.

## Storage layout (XDG)

```
~/.config/amazon/config.json                    # email + 1Password ref
~/.local/share/amazon/index.json                # order_id → file map
~/.local/share/amazon/orders/<year>/<id>.json   # one file per order
~/.local/share/amazon/cache/cookies.json        # session reuse (mode 600)
~/.local/share/amazon/cache/storage_state.json  # full Playwright state
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
amazon login                  # one-time browser-based login (handles captcha + 2FA)
amazon sync                   # default window (last 2 years)
amazon sync --year 2018       # one specific year
amazon sync --years 2010,2011 # several years
amazon sync --full            # re-fetch everything (default skips known orders)

amazon list --year 2025 --limit 25
amazon show 111-2222222-3333333
amazon search "raspberry pi"
amazon list --json | jq '[.[] | .total | tonumber] | add'

ruby web.rb                   # http://localhost:4567
```

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
ruby test/web_test.rb         # 95% line + branch coverage gate
```

The CLI itself doesn't ship a test suite — the value is end-to-end against
live Amazon, which is hard to mock usefully. The web app is well-tested
because its inputs (the JSON store) are stable.

## License

MIT. See [LICENSE](./LICENSE).

## Acknowledgements

- [`amazon-orders`](https://pypi.org/project/amazon-orders/) by Alex Laird —
  does the actual HTML parsing.
- [Playwright](https://playwright.dev/python/) for the headed login flow.
