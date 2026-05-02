# amazon-cli

Personal `amazon` CLI for fetching your own Amazon order history into a local
JSON store, then querying it offline.

Two-process design:
- **Ruby** (`bin/amazon`, `lib/amazon/**`) — subcommand dispatch, formatting, JSON store.
- **Python worker** (`pyworker/fetch.py`) — drives [`amazon-orders`](https://pypi.org/project/amazon-orders/) for login, 2FA, and HTML parsing.

## Setup

```bash
# 1) Install Python deps
cd pyworker
uv venv && uv pip install -e .   # or: python3 -m venv .venv && .venv/bin/pip install -e .

# 2) Symlink the entrypoint
chmod +x ../bin/amazon
ln -sf "$PWD/../bin/amazon" ~/bin/amazon

# 3) Configure
amazon config edit
# set:
#   email:           your@amazon.email
#   password_op_ref: op://Personal/Amazon/password
#   otp_op_ref:      (optional — op://… reference to a TOTP secret)
```

## Use

```bash
amazon sync --year 2025      # first run will prompt for OTP via TTY
amazon sync                  # subsequent runs reuse cached cookies
amazon list --year 2025
amazon show <order-id>
amazon search filament
amazon list --json | jq '.[] | .total'
```

## Storage

```
~/.config/amazon/config.json                    # email + 1Password ref
~/.local/share/amazon/index.json                # order_id → file map
~/.local/share/amazon/orders/2025/<id>.json     # one file per order
~/.local/share/amazon/cache/cookies.json        # session reuse (700)
~/.local/state/amazon/sync.log                  # sync history
```

## Future: `amazon buy`

Stubbed today. Plan: Playwright with a persistent storageState, separate from
the `amazon-orders` cookie jar; reuses the same Ruby CLI/store layer.
