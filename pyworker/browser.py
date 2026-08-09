"""
Shared Playwright session helpers.

`amazon login` writes a full Playwright storage state to
$XDG_DATA_HOME/amazon/cache/storage_state.json. Live product lookups reuse
that state headlessly, so pricing and delivery estimates come back
personalized (delivery dates depend on the signed-in default address).
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from typing import Any

# Amazon inlines <style> blocks inside content containers — #availability_feature_div
# ships one — and Playwright's inner_text hands back their source as text.
#
# Both anchors here exist to stop a rule reaching backwards into the copy above
# it. "Ships from Amazon.com" contains `.com`, which is indistinguishable from a
# class selector, so requiring only "selector token ... braced body" let a match
# start at `.com` and run forward to the next real rule, deleting every word in
# between: the seller line came back as "Ships from Amazon". Hence `^[ \t]*` —
# a rule begins its own line — and `[^{}\n]*`, which keeps the selector on the
# same line as its opening brace.
#
# The cost is a selector list split across lines (`.a,\n.b { }`) leaves `.a,`
# behind. That is the right way to be wrong: the residue is visibly junk, while
# the alternative silently eats real text.
CSS_RULE_RE = re.compile(r"(?m)^[ \t]*[.#][\w-]+[^{}\n]*\{[^{}]*\}")

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)


class NotLoggedIn(RuntimeError):
    """Raised when there is no saved session, or Amazon rejected the one we have."""


class Blocked(RuntimeError):
    """Raised when Amazon serves a captcha / robot check instead of the page."""


def emit(event: str, **fields: Any) -> None:
    sys.stdout.write(json.dumps({"event": event, **fields}) + "\n")
    sys.stdout.flush()


def xdg_data_home() -> Path:
    base = os.environ.get("XDG_DATA_HOME")
    return Path(base) if base else Path.home() / ".local/share"


def storage_state_path() -> Path:
    return xdg_data_home() / "amazon" / "cache" / "storage_state.json"


def launch(p: Any, headless: bool = True) -> Any:
    """Prefer real Chrome; fall back to bundled Chromium."""
    try:
        return p.chromium.launch(channel="chrome", headless=headless)
    except Exception:  # noqa: BLE001
        return p.chromium.launch(headless=headless)


def new_context(browser: Any) -> Any:
    state = storage_state_path()
    if not state.exists():
        raise NotLoggedIn(f"no saved session at {state} — run: amazon login")
    return browser.new_context(
        storage_state=str(state),
        viewport={"width": 1280, "height": 900},
        user_agent=UA,
        locale="en-US",
    )


# Amazon serves these instead of the real page when it thinks we're a bot.
CAPTCHA_MARKERS = (
    "form[action*='validateCaptcha']",
    "#captchacharacters",
    "img[src*='captcha']",
)

# Amazon redirects here when the saved cookies have expired. The storage-state
# file still exists on disk, so its presence alone proves nothing — without this
# check an expired session surfaces as "no product found for <ASIN>".
SIGNIN_URLS = ("/ap/signin", "/ap/cvf", "/ap/mfa")
SIGNIN_MARKERS = ("#ap_email", "#ap_password", "form[name='signIn']")


def guard(page: Any) -> None:
    """Raise if the page is a robot check or a sign-in redirect, not content.

    Fails closed. If every probe throws — navigating page, destroyed context,
    locator timeout — we cannot distinguish a block from real content, so raise
    rather than scrape a robot-check page as though it were a product.
    """
    probed = 0
    for sel in CAPTCHA_MARKERS:
        try:
            found = page.locator(sel).count() > 0
        except Exception:  # noqa: BLE001
            continue
        probed += 1
        if found:
            raise Blocked(
                "Amazon served a captcha instead of the page. "
                "Run `amazon login` to refresh the session, then retry."
            )
    if probed == 0:
        raise Blocked(
            "could not determine whether Amazon served a captcha — no probe "
            "completed. Retry, and run `amazon login` if it persists."
        )

    if is_signin_page(page):
        raise NotLoggedIn(
            "Amazon redirected to the sign-in page — the saved session has "
            "expired. Run: amazon login"
        )


# amazon-orders reads the cookie jar off disk, so its `session.login()` can
# succeed without a network call and the first real request is what discovers
# Amazon invalidated the session. Its own exception says to call
# AmazonSession.login() — advice a CLI user can't act on.
SESSION_REJECTED_MARKERS = ("redirected to login", "reauthenticate")


def session_rejected(e: BaseException) -> bool:
    """True when Amazon bounced us to the login page mid-request."""
    return any(m in str(e).lower() for m in SESSION_REJECTED_MARKERS)


def is_signin_page(page: Any) -> bool:
    try:
        url = page.url or ""
    except Exception:  # noqa: BLE001
        url = ""
    if any(marker in url for marker in SIGNIN_URLS):
        return True
    for sel in SIGNIN_MARKERS:
        try:
            if page.locator(sel).count() > 0:
                return True
        except Exception:  # noqa: BLE001
            continue
    return False


def text(scope: Any, *selectors: str) -> str | None:
    """First non-empty inner_text across a list of fallback selectors.

    Product-page markup is heavily A/B tested, so every field is looked up
    through several candidate selectors rather than one brittle path.
    """
    for sel in selectors:
        try:
            loc = scope.locator(sel).first
            if loc.count() == 0:
                continue
            val = clean_text(loc.inner_text())
            if val:
                return val
        except Exception:  # noqa: BLE001
            continue
    return None


def clean_text(raw: str | None) -> str:
    """Collapse whitespace and drop any inlined CSS the container carried.

    Without this, "Only 4 left in stock - order soon." comes back with a style
    rule stapled to it, and it reads as scraper output nobody checked.
    """
    if not raw:
        return ""
    return " ".join(CSS_RULE_RE.sub(" ", raw).split())


def attr(scope: Any, selector: str, name: str) -> str | None:
    try:
        loc = scope.locator(selector).first
        if loc.count() == 0:
            return None
        return loc.get_attribute(name)
    except Exception:  # noqa: BLE001
        return None


def parse_money(raw: str | None) -> float | None:
    """"$1,234.56" -> 1234.56. Returns None for empty or junk.

    A range ("$10.00 - $20.00") yields its low end, not None — callers show it
    as the "from" price.
    """
    if not raw:
        return None
    cleaned = raw.replace(",", "").replace("$", "").strip()
    # Price ranges ("$10.00 - $20.00") have no single value; take the low end.
    if "-" in cleaned:
        cleaned = cleaned.split("-")[0].strip()
    try:
        return round(float(cleaned), 2)
    except ValueError:
        return None
