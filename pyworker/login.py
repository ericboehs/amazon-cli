"""
Interactive Amazon login via Playwright.

Opens a real (headed) Chromium window pointed at amazon.com sign-in. The user
logs in themselves — including any captcha, 2FA, or "verify it's you" prompts
that the headless `amazon-orders` flow can't handle.

Success means one specific thing: the order-history page renders. Amazon will
happily hand a "recognized" session the homepage and product pages while
bouncing it from orders, so anything weaker than loading that page saves
cookies `amazon order sync` will be rejected with. Once it loads, the session
cookies are dumped into amazon-orders' `cookie_jar_path` format.

Output format on stdout (NDJSON):
    {"event":"log","msg":"..."}
    {"event":"navigate","url":"..."}
    {"event":"done","cookies_path":"...","count":N}
    {"event":"error","msg":"..."}
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any


def emit(event: str, **fields: Any) -> None:
    sys.stdout.write(json.dumps({"event": event, **fields}) + "\n")
    sys.stdout.flush()


def xdg_data_home() -> Path:
    base = os.environ.get("XDG_DATA_HOME")
    return Path(base) if base else Path.home() / ".local/share"


def xdg_config_home() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME")
    return Path(base) if base else Path.home() / ".config"


def load_email() -> str | None:
    cfg = xdg_config_home() / "amazon" / "config.json"
    if not cfg.exists():
        return None
    try:
        data = json.loads(cfg.read_text())
        email = data.get("email")
        return email if email and email != "you@example.com" else None
    except Exception:  # noqa: BLE001
        return None


# Start at order history rather than a bare sign-in URL. Amazon tiers its
# sessions: a "recognized" one renders product pages fine but is bounced from
# order history with `openid.pape.max_auth_age=0`, meaning it wants the password
# again no matter what cookies you hold. Landing here makes Amazon serve
# whichever challenge is actually required, and makes the success condition the
# same thing `amazon order sync` needs — so a session that can't read orders can
# no longer be saved as if it could.
ORDERS_URL = "https://www.amazon.com/your-orders/orders"

# Amazon's sign-in lives under /ap/ (signin, mfa, challenge, forgotpassword).
SIGNIN_PATHS = ("/ap/signin", "/ap/mfa", "/ap/challenge", "/ap/cvf")

# Markers that the order list itself rendered. Several, because this layout is
# A/B tested like the rest of the site and a single miss here costs the user ten
# minutes of silence followed by a timeout.
ORDER_MARKERS = (
    ".order-card, .js-order-card",
    "[data-component=orderCard]",
    "#ordersContainer",
    "#your-orders-content",
)


def describe_state(url: str | None) -> str:
    """Short human-readable "where are we" for the waiting heartbeat."""
    if not url:
        return "no page loaded yet"
    if is_signin_url(url):
        return "on Amazon's sign-in / verification page"
    if "/your-orders" in url:
        return "on the orders page, but the order list hasn't rendered"
    return f"on {url[:60]}"


def is_signin_url(url: str | None) -> bool:
    return bool(url) and any(p in url for p in SIGNIN_PATHS)


def order_access_ok(url: str | None, signout_links: int, order_cards: int) -> bool:
    """True only when order history actually rendered for this session.

    The sign-in page carries nodes that match the order-card selector, so a
    marker count on its own says nothing — the URL check has to come first.
    That false positive is exactly how a recognized-but-unauthenticated session
    used to pass for a real one.
    """
    if not url or is_signin_url(url):
        return False
    return signout_links > 0 or order_cards > 0


def should_renavigate(url: str | None) -> bool:
    """Nudge an idle tab back to order history.

    Amazon sometimes returns you to the homepage after sign-in instead of the
    page you asked for. Without this the poll would watch a signed-in homepage
    until it timed out, having never tested the thing it cares about. A tab
    still inside /ap/ is mid-challenge and must be left alone.
    """
    if not url or is_signin_url(url):
        return False
    return "/your-orders" not in url


def main() -> int:
    try:
        from playwright.sync_api import sync_playwright
    except ImportError as e:
        emit("error", msg=f"playwright not installed: {e}")
        return 2

    cache_dir = xdg_data_home() / "amazon" / "cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(cache_dir, 0o700)
    except OSError:
        pass
    cookies_path = cache_dir / "cookies.json"
    storage_state_path = cache_dir / "storage_state.json"

    emit("log", msg=f"opening browser; cookies will be saved to {cookies_path}")

    with sync_playwright() as p:
        # Prefer real Chrome (proper macOS focus + menu bar). Fall back to
        # bundled Chromium if Chrome isn't installed.
        browser = None
        last_err: Exception | None = None
        try:
            browser = p.chromium.launch(channel="chrome", headless=False)
            emit("log", msg="launched browser (channel=chrome)")
        except Exception as e:  # noqa: BLE001
            last_err = e
            try:
                browser = p.chromium.launch(headless=False)
                emit("log", msg="launched browser (channel=chromium)")
            except Exception as e2:  # noqa: BLE001
                last_err = e2
        if browser is None:
            emit(
                "error",
                msg=(
                    f"failed to launch browser: {last_err}. "
                    "Run: cd pyworker && .venv/bin/python -m playwright install chromium"
                ),
            )
            return 1

        context_args: dict[str, Any] = {
            "viewport": {"width": 1280, "height": 900},
            "user_agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
            ),
        }
        if storage_state_path.exists():
            context_args["storage_state"] = str(storage_state_path)
            emit("log", msg="reusing prior storage_state (may already be logged in)")

        context = browser.new_context(**context_args)
        page = context.new_page()
        emit("navigate", url=ORDERS_URL)
        page.goto(ORDERS_URL, wait_until="domcontentloaded")

        email = load_email()
        if email:
            try:
                email_input = page.locator("#ap_email_login, #ap_email").first
                email_input.wait_for(state="visible", timeout=5000)
                email_input.fill(email)
                emit("log", msg=f"pre-filled email: {email}")
                cont = page.locator("#continue, input[type=submit][aria-labelledby*=continue]").first
                if cont.count() > 0:
                    cont.click()
                    emit("log", msg="clicked Continue — finish password + any 2FA in the window")
            except Exception as e:  # noqa: BLE001
                emit("log", msg=f"could not pre-fill email ({e}); continue manually")

        emit(
            "log",
            msg=(
                "Sign in to Amazon in the browser window. Solve any captcha or 2FA. "
                "Amazon may ask for your password again even if it greets you by "
                "name — it guards order history separately. This waits for your "
                "orders to load, then saves cookies automatically."
            ),
        )

        # Poll until order history renders. The old check — an `x-main` cookie
        # plus "not on /ap/signin" — is satisfied by a merely recognized
        # session, so it reported success for sessions that `amazon order sync`
        # was then rejected with. Nothing short of loading the page proves it.
        deadline = time.time() + 600  # 10 minutes
        authenticated = False
        last_nudge = 0.0
        last_report = time.time()
        while time.time() < deadline:
            try:
                url = page.url
                cards = sum(page.locator(sel).count() for sel in ORDER_MARKERS)
                if order_access_ok(url, page.locator("#nav-item-signout").count(), cards):
                    authenticated = True
                    break

                # Ten minutes of silence gives the user nothing to act on and
                # leaves a timeout undiagnosable afterwards. Say where we are.
                if time.time() - last_report > 30:
                    last_report = time.time()
                    left = int(deadline - time.time())
                    emit("log", msg=f"waiting ({left}s left) — {describe_state(url)}")
                # Give the tab a few seconds to settle before steering it, so a
                # redirect in flight isn't mistaken for an idle page.
                if should_renavigate(url) and time.time() - last_nudge > 10:
                    last_nudge = time.time()
                    page.goto(ORDERS_URL, wait_until="domcontentloaded")
            except Exception:  # noqa: BLE001
                # A navigation mid-poll detaches the frame; try again next tick.
                pass
            time.sleep(2)

        if not authenticated:
            emit(
                "error",
                msg=(
                    "timed out waiting for sign-in (10 min) — order history never "
                    "loaded, so nothing was saved. Amazon asks for the password "
                    "again before it will show orders, even when the browser "
                    "already looks signed in."
                ),
            )
            context.close()
            browser.close()
            return 1

        # Persist cookies in two places:
        #   1) amazon-orders cookie_jar_path: simple {name: value} dict
        #   2) Playwright storageState: full storage for future Playwright runs (e.g., `amazon buy`)
        cookies = context.cookies()
        ao_cookies = {
            c.get("name", ""): c.get("value", "")
            for c in cookies
            if c.get("domain", "").endswith("amazon.com") and c.get("name")
        }
        cookies_path.write_text(json.dumps(ao_cookies))
        os.chmod(cookies_path, 0o600)

        context.storage_state(path=str(storage_state_path))
        os.chmod(storage_state_path, 0o600)

        emit("done", cookies_path=str(cookies_path), count=len(ao_cookies))

        context.close()
        browser.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
