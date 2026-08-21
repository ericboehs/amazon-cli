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

import contextlib
import json
import os
import re
import sys
import time
import traceback
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from browser import SIGNIN_URLS
from otp import current_code, normalize_otp_secret

# The authenticator-app field, and only that one. Amazon reuses a similar box
# for codes it emails or texts you (`#cvf-input-code`), and a TOTP typed into
# that one is simply wrong — six digits that will never match, submitted over
# and over by a loop that thinks it is helping.
OTP_SELECTOR = "#auth-mfa-otpcode"
OTP_SUBMIT_SELECTOR = "#auth-signin-button"
PASSWORD_SELECTOR = "#ap_password"
PASSWORD_SUBMIT_SELECTOR = "#signInSubmit"
# Amazon renders the password step after Continue, so the field we want does
# not exist at the moment we click. This is how long we'll wait for it before
# deciding this is a page we don't understand and leaving it to the human.
PASSWORD_WAIT_MS = 8000


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

# Where order history can legitimately live. Amazon still redirects some
# accounts to the legacy paths, and treating those as "somewhere else" would
# make the poll steer away from the page it was waiting for.
ORDER_HISTORY_PATHS = (
    "/your-orders",
    "/gp/your-account/order-history",
    "/gp/css/order-history",
)

# Pages it is safe to steer away from: an idle tab sitting on the storefront.
# Deliberately an allowlist — see `should_renavigate`.
# Post-authentication upsells. Amazon signs you in and then, instead of your
# orders, offers to add a passkey or a phone number — a page that is not a
# sign-in step, not order history, and not going anywhere until someone
# declines it. Left alone the poll waits the full ten minutes on a screen the
# user has to notice and dismiss themselves, which is the opposite of what
# reading the password out of 1Password was for.
#
# Text, not CSS, because these screens are A/B tested and their class names are
# generated; the copy on the decline control is the stable part. Exact matches
# only — "skip" as a substring also matches "Skip to main content", the first
# link on every Amazon page.
DECLINE_LABELS = (
    "not now",
    "maybe later",
    "remind me later",
    "no thanks",
    "skip for now",
)
# The one Amazon gives an id to, kept because an id beats a text match when
# it's on offer.
DECLINE_SELECTOR = "#ap-account-fixup-phone-skip-link"

IDLE_PATHS = ("", "/", "/gp/css/homepage.html", "/gp/css/homepage")

# Markers that the order list itself rendered. Several, because this layout is
# A/B tested like the rest of the site and a single miss here costs the user ten
# minutes of silence followed by a timeout.
#
# Measured against a live signed-in account on 2026-08-10, on /your-orders/orders
# with ten orders present:
#
#     10   .order-card, .js-order-card
#      0   [data-component=orderCard]
#      0   #ordersContainer
#      0   #your-orders-content
#
# So this reads as defense in depth and is currently one selector with three
# zeros behind it. The three are kept — an A/B layout that renders none of them
# today may be what some other account gets, and a marker that matches nothing
# costs a `count()` call — but they are recorded as unverified rather than left
# to look like cover. `report_markers` prints which ones actually carried each
# real login, so the next reading of this list comes from a measurement instead
# of from this comment.
#
# Note what the zeros cost, because it is not symmetric with the seller chain in
# `live.py`: this gate is what stands between a working login and a refused one,
# so if `.order-card` goes the way the other three went, *every* login fails and
# the fallbacks contribute nothing to stopping it.
# `.your-orders-content-container` is the one entry here verified on *both*
# pages that matter, which is what a marker actually has to be: present on the
# order list (it is the <section> every one of the ten cards sits inside) and
# absent from the sign-in page Amazon bounces a dead session to. Measured
# 2026-08-10 against a fresh context with no storage state, landing on
# /ap/signin: zero. That makes it strictly more discriminating than the card
# selector currently carrying every login, which counts 1 there — the URL check
# in `order_access_ok` is the only reason that 1 does not pass for proof, and
# now that number is measured rather than asserted.
#
# It is NOT evidence for the empty-account case below. Whether that section
# renders for an account with zero orders is unmeasured, and assuming it does —
# because containers usually do — would be the retracted claim again, one
# selector over.
ORDER_MARKERS = (
    ".order-card, .js-order-card",
    ".your-orders-content-container",
    "[data-component=orderCard]",
    "#ordersContainer",
    "#your-orders-content",
)


# Consecutive poll ticks in which every DOM probe raised. At the 2s tick that is
# ten seconds — long enough that a frame detaching mid-navigation rides through
# it, short enough that a dropped connection doesn't buy ten minutes of a
# heartbeat cheerfully reporting the page it can no longer read.
MAX_PROBE_FAILURES = 5


def describe_state(url: str | None) -> str:
    """Short human-readable "where are we" for the waiting heartbeat."""
    if not url:
        return "no page loaded yet"
    if is_signin_url(url):
        return "on Amazon's sign-in / verification page"
    if is_order_history_url(url):
        return "on the orders page, but the order list hasn't rendered"
    return f"on {url[:60]}"


def is_amazon_domain(domain: str | None) -> bool:
    """Ours, for the purposes of what gets written to the jar.

    An `endswith("amazon.com")` substring test would accept `notamazon.com`.
    Unreachable through the login flow, which only ever visits Amazon and the
    ad-tech Amazon's pages load — a measured 46 of the 68 cookies in a real
    context are third-party (`.doubleclick.net`, `.pubmatic.com`, and 29 other
    domains), and they are dropped here rather than written to disk. The
    correct test costs nothing, and "unreachable today" is the premise that has
    been wrong most often in this module.
    """
    if not domain:
        return False
    d = domain.lstrip(".")
    return d == "amazon.com" or d.endswith(".amazon.com")


def is_signin_url(url: str | None) -> bool:
    return bool(url) and any(p in url for p in SIGNIN_URLS)


def is_order_history_url(url: str | None) -> bool:
    return bool(url) and any(p in url for p in ORDER_HISTORY_PATHS)


def marker_counts(page: Any) -> dict[str, int]:
    """Per-selector counts, so the gate can say which marker carried it."""
    return {sel: page.locator(sel).count() for sel in ORDER_MARKERS}


def report_markers(counts: dict[str, int]) -> None:
    """Say which markers rendered, once, on the login that passed.

    `amazon login` is the only probe in this repo that runs against a real
    signed-in account every time it runs, which makes it the one place a
    selector list can be measured in production rather than argued about. The
    comment on `ORDER_MARKERS` is a reading of one account on one day; this is
    the reading from whoever ran it last.
    """
    live = [sel for sel, n in counts.items() if n]
    emit(
        "log",
        msg=(
            f"order list confirmed by {len(live)} of {len(ORDER_MARKERS)} markers: "
            + ", ".join(f"{sel} ({counts[sel]})" for sel in live)
        ),
    )


def order_access_ok(url: str | None, order_cards: int) -> bool:
    """True only when order history actually rendered for this session.

    Both halves are load-bearing and neither is sufficient.

    The URL, because the sign-in page carries nodes that match the order-card
    selector — counting markers without checking where we are is how a
    recognized-but-unauthenticated session used to pass for a real one. That is
    now a measurement and not a warning: on /ap/signin, reached with no storage
    state at all, `.order-card, .js-order-card` counts exactly 1.

    The markers, because the URL alone only says what we asked for, not what
    Amazon served.

    Note what is deliberately *not* consulted: `#nav-item-signout`. Amazon
    renders that on every page it serves a session it recognizes, including the
    ones it bounces from order history — it is the signature of precisely the
    tier this module exists to reject, so it can never be evidence for the
    opposite conclusion. It used to be accepted here on its own, which meant a
    signed-in homepage counted as proof of order access.

    An account with no orders was supposed to still pass, on the grounds that
    `#your-orders-content` is the page *container* and renders empty — so "your
    order list is empty" would be distinguished from "you cannot see your order
    list" by the same probe. That is now known to be wrong: measured on a live
    orders page with ten orders on it, `#your-orders-content` matched zero
    times, so it cannot be the container that carries an empty account either.
    The card selector was the only marker that fired.

    So on today's markup an account with no orders times out at ten minutes
    having been signed in the whole time. Left as a known gap rather than
    guessed at: closing it needs the real container from a live empty account,
    and inventing a selector here would restore exactly the false assurance
    this docstring just lost.

    How the wrong one got written is worth keeping, because it is not
    carelessness: `your-orders-content` is genuinely on the page — as a *class*
    prefix on the <section> wrapping the cards, never as an id. A half-recalled
    real string reads exactly like a checked one.

    `.your-orders-content-container` is the candidate, and it is in
    ORDER_MARKERS on its own merits. It is not promoted to closing this gap,
    because it has only been measured on an account that *has* orders.
    """
    if not url or is_signin_url(url) or not is_order_history_url(url):
        return False
    return order_cards > 0


# The one cookie every consumer actually requires: amazon-orders'
# `COOKIES_SET_WHEN_AUTHENTICATED` is exactly `["x-main"]`, and `sync.rb`'s
# `cookies_authenticated?` tests the same name. Deliberately not a longer list —
# names Amazon doesn't set in every request context (`sess-at-main`) would turn
# a working session into a refusal.
AUTH_COOKIE = "x-main"

# The gate runs now, `sync.rb` runs later — so a cookie with seconds left would
# pass a check whose entire purpose is to assert what sync asserts.
EXPIRY_MARGIN = 60.0


def cookie_lifetime(cookie: Mapping[str, Any]) -> float:
    """How far into the future this cookie survives a round-trip through disk.

    `-inf` for one that doesn't survive at all: a missing, non-numeric or
    negative expiry is Playwright's way of saying "dies with the window", and
    the jar's whole job is being read back after the window is gone.
    """
    expires = cookie.get("expires")
    if isinstance(expires, bool) or not isinstance(expires, (int, float)):
        return float("-inf")
    return float(expires) if expires >= 0 else float("-inf")


def resolve_cookies(cookies: Sequence[Mapping[str, Any]]) -> dict[str, Mapping[str, Any]]:
    """One cookie per name, keeping the entry worth writing down.

    `context.cookies()` is a flat list, not a map, and Amazon puts the same name
    in it twice: a host-scoped `www.amazon.com` duplicate alongside the
    domain-scoped `.amazon.com` cookie during some sign-in flows. The gate and
    the jar used to resolve that collision independently and in opposite
    directions — `next(...)` took the first match, a name-keyed dict
    comprehension took the last — so the cookie that was validated and the
    cookie that was stored could be different objects with different expiries.

    Both directions are bugs the user cannot diagnose. Validate the session
    duplicate and a perfectly good login is refused with advice to check a box
    that was already checked; validate the durable one and store the session
    one, and login reports success on a jar `amazon order sync` will reject —
    the original bug, surviving its own fix.

    Resolving once, here, makes the disagreement unrepresentable. Longest-lived
    wins; the broader (domain-scoped) cookie breaks a tie.
    """
    best: dict[str, Mapping[str, Any]] = {}
    for cookie in cookies:
        name = cookie.get("name")
        if not name:
            continue
        current = best.get(name)
        if current is None or _rank(cookie) > _rank(current):
            best[name] = cookie
    return best


def _rank(cookie: Mapping[str, Any]) -> tuple[float, int]:
    domain = cookie.get("domain") or ""
    return (cookie_lifetime(cookie), 1 if domain.startswith(".") else 0)


def unsavable_reason(cookies: Mapping[str, Mapping[str, Any]], now: float) -> str | None:
    """None when this jar is worth writing; otherwise why it isn't.

    Asserts, before writing, the same predicate `sync.rb` will apply after —
    `x-main` present, with an `expires` that is numeric, non-negative and far
    enough in the future to still be there when sync looks. Login had every one
    of those timestamps in `context.cookies()` and read none of them, so it
    printed "saved 47 cookies, run `amazon order sync`" for a session the next
    sync would immediately call unauthenticated and replace with a full password
    login. That is the loop 4bff129 exists to break.

    The likely trigger is signing in without "Keep me signed in" checked: Amazon
    issues the auth cookies as *session* cookies, which Playwright records as
    `expires: -1`, and a session cookie proves nothing about a jar reloaded from
    disk later.

    A reason string rather than a bool, because the two failures have different
    fixes and a user can act on the difference.
    """
    if not cookies:
        # Enumeration raced a navigation. Writing `{}` here overwrote a working
        # jar, emitted `done` with count=0, and exited 0 — destroying the
        # session while reporting success.
        return (
            "the browser returned no cookies, so nothing was saved rather than "
            "overwrite the session you already had. Try `amazon login` again."
        )

    match = cookies.get(AUTH_COOKIE)
    if match is None:
        return (
            f"order history loaded but Amazon never issued the `{AUTH_COOKIE}` "
            "session cookie, which `amazon order sync` requires. Nothing was "
            "saved. Try `amazon login` again."
        )

    expires = match.get("expires")
    if not isinstance(expires, (int, float)) or isinstance(expires, bool):
        return (
            f"the `{AUTH_COOKIE}` cookie has no usable expiry, so `amazon order "
            "sync` would reject it. Nothing was saved."
        )
    if expires < 0:
        # Playwright writes -1 for a session cookie.
        return (
            "signed in, but Amazon issued a browser-session cookie that dies with "
            "this window — `amazon order sync` would reject it, so nothing was "
            "saved. Sign in again with \"Keep me signed in\" checked."
        )
    if expires <= now + EXPIRY_MARGIN:
        return (
            f"the `{AUTH_COOKIE}` cookie expires in under a minute, so `amazon "
            "order sync` would reject it before you could run it. Nothing was "
            "saved. Try `amazon login` again."
        )
    return None


def write_private(path: Path, content: str) -> None:
    """Write 0600, atomically. A half-written jar is indistinguishable from a
    corrupt one, and the failure lands on the next command rather than this one.

    The mode is set on the temp file before any content goes into it: the 0700
    on the parent directory is applied under `except OSError: pass`, so on a
    filesystem that rejects chmod it silently isn't there to fall back on.
    """
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(content)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def timeout_message(url: str | None, last_error: str | None) -> str:
    """What to say when ten minutes pass without order history rendering.

    This used to assert one cause unconditionally — "Amazon asks for the
    password again before it will show orders". Under a hijacked captcha, a
    closed window, a dropped connection or a stale first tab that sentence is
    simply false, and a user who acts on it retries the password and fails the
    same way. So: say where it stopped, offer the password explanation only when
    the page it stopped on supports it, and carry the last swallowed exception —
    which is worth more than the state on its own.
    """
    parts = [
        f"timed out waiting for sign-in (10 min) — {describe_state(url)}.",
        "Order history never rendered, so nothing was saved.",
    ]
    if is_signin_url(url):
        parts.append(
            "Amazon guards order history separately and will ask for the password "
            "again even when the browser already looks signed in."
        )
    if last_error:
        parts.append(f"Last error while checking the page: {last_error}")
    return " ".join(parts)


def close_quietly(*closeables: Any) -> None:
    """Shut down without letting teardown overwrite the diagnosis.

    On the closed-window path these are already gone, so `close()` raises and
    replaces a clear `error` event with a Playwright traceback on stderr — which
    the Ruby side only shows under -v, leaving the user with a bare exit code.
    """
    for c in closeables:
        try:
            c.close()
        except Exception:  # noqa: BLE001
            pass


def poll_state(urls: Sequence[str | None]) -> str | None:
    """Which open tab describes where the login flow actually is.

    The poll used to look at one tab — the one it opened. Amazon's challenges
    open new ones (and the user opens their own), so the original tab can sit on
    an untouched homepage for ten minutes while the whole sign-in happens
    somewhere else. Everything the poll reports and everything it does was being
    decided from the least interesting window on screen.

    A tab mid-sign-in wins, because that is where the user is and because
    `should_renavigate` reads this: nudging while a 2FA prompt is open in
    another tab throws away a code they have already been sent. Order history
    next. Otherwise the first tab, which is the one we opened.
    """
    for url in urls:
        if is_signin_url(url):
            return url
    for url in urls:
        if is_order_history_url(url):
            return url
    # Load-bearing, not arbitrary. The poll decides with this and then acts on
    # `pages[0]`, and those are only the same tab because the two branches above
    # return URLs `should_renavigate` always declines — so a nudge can only ever
    # come from this one. Prefer some other tab here (most-recently-opened, say)
    # and the poll starts approving tab N while `goto` still fires on tab 0,
    # yanking a page the user was in the middle of.
    return urls[0] if urls else None


def should_prefill_email(email_visible: bool, password_visible: bool) -> bool:
    """Only auto-advance the email step when it really is the email step.

    The re-auth page Amazon serves on the `max_auth_age=0` bounce already knows
    who you are and wants the password, but it still renders an email field
    beside it. Filling that and clicking Continue submits the form with an empty
    password, and Amazon answers by dropping the context and rendering a clean
    sign-in page — so the pre-fill costs the user the very step it meant to skip.
    A password box on screen means the human is the only one who can proceed.
    """
    return email_visible and not password_visible


def should_renavigate(url: str | None) -> bool:
    """Nudge an idle tab back to order history.

    Amazon sometimes returns you to the homepage after sign-in instead of the
    page you asked for. Without this the poll would watch a signed-in homepage
    until it timed out, having never tested the thing it cares about.

    An allowlist, not a blocklist, and that is the whole point. This used to
    nudge anything outside /ap/, which meant it also nudged the bot captcha —
    served from /errors/validateCaptcha, not /ap/ — every ten seconds. The user
    types the characters, `page.goto` throws the input away, Amazon mints a
    fresh captcha, and the login cannot be completed no matter what they do; it
    burns the full ten minutes and then blames the password. /ap/forgotpassword,
    /ap/accountfixup and /ap/switchaccount were hijacked the same way.

    A URL we don't recognize is far more likely a challenge we haven't seen than
    an idle tab, and the cost of the two mistakes is not symmetric: failing to
    nudge costs a nudge, and nudging a challenge costs the whole login. So
    steer only from pages known to be idle, and leave everything else alone.
    """
    if not url or is_order_history_url(url):
        return False
    try:
        parts = urlparse(url)
    except ValueError:
        return False
    if "amazon." not in (parts.netloc or ""):
        return False
    return parts.path in IDLE_PATHS


def should_dismiss_upsell(url: str | None) -> bool:
    """Whether this page is the kind that might hold a "Not now" worth clicking.

    Not the sign-in flow: those pages ask for things only the user has, and a
    stray click on one is how you throw away a 2FA code. Not order history
    either — that's the finish line. What's left is the interstitial Amazon
    invented this quarter, which is precisely the page we can't enumerate in
    advance and the only kind worth probing.
    """
    if not url or is_signin_url(url) or is_order_history_url(url):
        return False
    # An idle page — the homepage, usually — already has an owner: the nudge
    # steers it back to orders. Probing it too would put "nothing to decline"
    # in the log for the most ordinary path through a login.
    if should_renavigate(url):
        return False
    try:
        parts = urlparse(url)
    except ValueError:
        return False
    return "amazon." in (parts.netloc or "")


def dismiss_upsell(page: Any) -> str | None:
    """Click a decline control if one is on the page. Returns what it clicked.

    Declining is always the safe half of these prompts: "Not now" adds nothing,
    changes nothing, and is the button the user would press. The risk is
    clicking something else by accident, so the match is exact and the search
    is limited to buttons and links.
    """
    with contextlib.suppress(Exception):
        known = page.locator(DECLINE_SELECTOR).first
        if known.count() > 0 and known.is_visible():
            known.click()
            return DECLINE_SELECTOR

    for label in DECLINE_LABELS:
        pattern = re.compile(rf"^\s*{re.escape(label)}\s*$", re.I)
        for role in ("button", "link"):
            with contextlib.suppress(Exception):
                control = page.get_by_role(role, name=pattern).first
                if control.count() > 0 and control.is_visible():
                    control.click()
                    return label
    return None


def read_request() -> dict[str, Any]:
    """The optional credentials line the Ruby side writes to stdin.

    Optional in both directions: `python login.py` from a shell is a supported
    way to run this, and it must not hang waiting for a line that no one is
    going to type — hence the isatty guard. An unreadable or malformed line is
    not fatal either; the browser window still opens and the human still has
    hands.
    """
    if sys.stdin is None or sys.stdin.isatty():
        return {}
    try:
        raw = sys.stdin.readline()
    except (OSError, ValueError):
        return {}
    if not raw.strip():
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        # Deliberately not echoed. If this line is malformed it is still the
        # line with the password in it.
        emit("log", msg="ignoring an unreadable credentials line on stdin")
        return {}
    return parsed if isinstance(parsed, dict) else {}


def credentials_from(req: Mapping[str, Any]) -> tuple[str | None, str | None]:
    """Pull (password, otp_secret) out of the request.

    Empty strings become None so that a config with a blank field behaves like
    a config without one, rather than filling the form with nothing and
    submitting it.
    """
    password = req.get("password") or None
    try:
        secret = normalize_otp_secret(req.get("otp_secret") or None)
    except ValueError as e:
        emit("log", msg=f"ignoring the OTP secret: {e}")
        return password, None
    return password, secret


def should_submit_otp(current_value: str, code: str, last_code: str | None) -> bool:
    """Whether to type this code into the two-factor box.

    Two ways to get this wrong, both of which cost the login:

    Typing over the user. The box may already hold digits they are halfway
    through entering from their phone; `fill` would silently replace them.

    Resubmitting. This runs inside a poll that ticks every couple of seconds,
    and a TOTP is valid for thirty of them. If Amazon rejects a code — clock
    skew, a stale secret — the field comes back empty and unchanged, and
    without this check the loop would submit the same six digits ten times in
    a row and earn a rate limit. One attempt per code; the next window brings
    a new one.
    """
    if current_value.strip():
        return False
    return code != last_code


def fill_password(page: Any, password: str) -> bool:
    """Fill and submit the password field, if it turns up."""
    field = page.locator(PASSWORD_SELECTOR).first
    try:
        field.wait_for(state="visible", timeout=PASSWORD_WAIT_MS)
    except Exception:  # noqa: BLE001
        return False
    field.fill(password)
    submit = page.locator(PASSWORD_SUBMIT_SELECTOR).first
    if submit.count() > 0:
        submit.click()
    return True


def fill_otp(page: Any, secret: str, last_code: str | None) -> str | None:
    """Type the current TOTP into the two-factor box. Returns the code sent."""
    field = page.locator(OTP_SELECTOR).first
    if field.count() == 0 or not field.is_visible():
        return None
    code = current_code(secret)
    if not should_submit_otp(field.input_value(), code, last_code):
        return None
    field.fill(code)
    submit = page.locator(OTP_SUBMIT_SELECTOR).first
    if submit.count() > 0:
        submit.click()
    return code


def autofill_otp(pages: Any, secret: str, last_code: str | None) -> tuple[str | None, str | None]:
    """Type the 2FA code into whichever tab is asking. Never raises.

    Returns ``(code_sent, error_name)``, at most one of which is set.

    The "never raises" is the whole point, and it is a function rather than a
    `try` in the poll loop so that it can be tested. Autofill is a convenience
    laid over a login that works without it — the person is sitting right there
    with an authenticator app. But the call used to sit unguarded among the
    loop's DOM probes, so an unusable secret raised on every tick, counted as a
    failed probe, and five ticks later closed the browser window mid-login with
    a message blaming the network. The convenience destroyed the thing it was
    assisting.
    """
    try:
        for page in pages:
            sent = fill_otp(page, secret, last_code)
            if sent:
                return sent, None
    except Exception as e:  # noqa: BLE001
        return None, type(e).__name__
    return None, None


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

    password, otp_secret = credentials_from(read_request())
    if password:
        emit("log", msg="got credentials from 1Password — the window is for captcha only")

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
                pw = page.locator("#ap_password")
                password_visible = pw.count() > 0 and pw.first.is_visible()

                email_input = page.locator("#ap_email_login, #ap_email").first
                email_visible = False
                if not password_visible:
                    try:
                        email_input.wait_for(state="visible", timeout=5000)
                        email_visible = True
                    except Exception:  # noqa: BLE001
                        email_visible = False

                if should_prefill_email(email_visible, password_visible):
                    email_input.fill(email)
                    emit("log", msg=f"pre-filled email: {email}")
                    cont = page.locator("#continue, input[type=submit][aria-labelledby*=continue]").first
                    if cont.count() > 0:
                        cont.click()
                        if password and fill_password(page, password):
                            emit("log", msg="filled the password from 1Password and submitted it")
                        else:
                            emit("log", msg="clicked Continue — finish password + any 2FA in the window")
                elif password_visible:
                    if password and fill_password(page, password):
                        emit("log", msg="filled the password from 1Password and submitted it")
                    else:
                        emit(
                            "log",
                            msg=(
                                "Amazon is asking for your password on this page — type it in "
                                "the window. Leaving the form alone so Continue can't reset it."
                            ),
                        )
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
        window_closed = False
        last_nudge = 0.0
        last_report = time.time()
        last_state: str | None = None
        # `#your-orders-content` is the page *container*, so Amazon can render it
        # a tick before it knows whether it will show you the list or bounce you.
        # Requiring two consecutive passing ticks costs two seconds and removes
        # the only way this check can fire on a shell.
        streak = 0
        # The counts from the tick that proved it, so the report names what
        # actually rendered rather than re-probing a page that has moved on.
        matched: dict[str, int] = {}
        last_error: str | None = None
        probe_failures = 0
        # The last TOTP we submitted, so a rejected code isn't retried on every
        # tick for the thirty seconds it stays current.
        last_otp_code: str | None = None
        # Whether the "autofill broke, carry on by hand" line has been said.
        otp_warned = False
        # URLs we've already tried to dismiss, so one unanswerable page doesn't
        # get clicked at every tick for ten minutes.
        dismissed: set[str] = set()
        while time.time() < deadline:
            # Above the try, because closing the window is not an error to retry
            # past. The blanket `except` below used to swallow it, buying ten more
            # minutes of waiting on a browser that no longer exists.
            if not browser.is_connected() or not context.pages:
                window_closed = True
                break

            # Read the URLs and report *before* touching the DOM. `page.url` is
            # cached client-side and does not raise — every locator call does, and
            # with the heartbeat below the probes a dead network or a closing
            # window took the entire loop silent until t=600s. That is the one
            # case where the heartbeat is the only thing the user has.
            open_pages = list(context.pages)
            last_state = poll_state([p.url for p in open_pages])
            if time.time() - last_report > 30:
                last_report = time.time()
                left = int(deadline - time.time())
                emit("log", msg=f"waiting ({left}s left) — {describe_state(last_state)}")

            try:
                # Every tab, not just the one we opened. Amazon's challenges open
                # their own windows and the user opens theirs; `page` was bound
                # once at launch, so the original tab sat on /ap/signin — where
                # `should_renavigate` declines to steer it — while a working
                # session was authenticating in the tab beside it. Nothing has to
                # change about saving: `context.cookies()` is context-wide and
                # already sees it.
                proved = False
                for p in open_pages:
                    counts = marker_counts(p)
                    if order_access_ok(p.url, sum(counts.values())):
                        proved = True
                        matched = counts
                        break
                # The two-factor box only exists after the password is accepted,
                # so it is checked here rather than in the setup above — and on
                # every tab, because Amazon's challenges open their own.
                if otp_secret:
                    sent, otp_error = autofill_otp(open_pages, otp_secret, last_otp_code)
                    if sent:
                        last_otp_code = sent
                        emit("log", msg="entered the 2FA code from 1Password")
                    elif otp_error and not otp_warned:
                        # Once. This runs every two seconds for up to ten
                        # minutes, and a warning repeated 300 times buries the
                        # sign-in instructions printed next to it.
                        otp_warned = True
                        emit(
                            "log",
                            level="warn",
                            msg=(
                                f"could not enter the 2FA code ({otp_error}) — "
                                "type it yourself; nothing else about this login changes"
                            ),
                        )
                # An upsell is only in the way once. Re-clicking a page we have
                # already answered would fight whatever the user chose to do
                # with it instead — so each URL gets one attempt, and a page
                # that stays put after that is theirs.
                for p in open_pages:
                    if not should_dismiss_upsell(p.url) or p.url in dismissed:
                        continue
                    dismissed.add(p.url)
                    clicked = dismiss_upsell(p)
                    if clicked:
                        emit("log", msg=f"declined an Amazon prompt ({clicked}) to get back to your orders")
                    else:
                        # The URL, because the next unknown interstitial is
                        # only knowable if this line names the last one.
                        emit("log", msg=f"nothing to decline on {p.url[:80]} — over to you")
                # Give the tab a few seconds to settle before steering it, so a
                # redirect in flight isn't mistaken for an idle page.
                # `last_state` is `poll_state`'s pick, so a sign-in tab anywhere
                # suppresses the nudge — not only one in the tab we would steer.
                if should_renavigate(last_state) and time.time() - last_nudge > 10:
                    last_nudge = time.time()
                    open_pages[0].goto(ORDERS_URL, wait_until="domcontentloaded")
                probe_failures = 0
            except Exception as e:  # noqa: BLE001
                # A navigation mid-poll detaches the frame, so one failure means
                # nothing. A run of them means no probe is completing and the
                # loop is testing nothing while claiming to wait — `guard()`
                # refuses to guess in exactly this situation, and this loop used
                # to fail open into a ten-minute wait instead. Fail closed.
                proved = False
                last_error = f"{type(e).__name__}: {e}"
                probe_failures += 1
                if probe_failures >= MAX_PROBE_FAILURES:
                    emit(
                        "error",
                        msg=(
                            f"gave up checking the browser — {MAX_PROBE_FAILURES} "
                            f"consecutive probes failed ({last_error}). Nothing was "
                            "saved. This is usually a dropped network connection."
                        ),
                    )
                    close_quietly(context, browser)
                    return 1

            streak = streak + 1 if proved else 0
            if streak >= 2:
                authenticated = True
                report_markers(matched)
                break
            time.sleep(2)

        if window_closed:
            emit(
                "error",
                msg=(
                    "the browser window was closed before order history loaded, so "
                    "nothing was saved. Run `amazon login` again and leave the "
                    "window open until your orders appear."
                ),
            )
            close_quietly(context, browser)
            return 1

        if not authenticated:
            emit("error", msg=timeout_message(last_state, last_error))
            close_quietly(context, browser)
            return 1

        # Collapse duplicate names once, here, so the cookie the gate judges and
        # the cookie the jar records are the same object by construction.
        amazon_cookies = resolve_cookies(
            [c for c in context.cookies() if is_amazon_domain(c.get("domain"))]
        )

        # Check before writing. Order history rendering proves this *window* can
        # read orders; it does not prove the cookies outlive it.
        reason = unsavable_reason(amazon_cookies, time.time())
        if reason:
            emit("error", msg=reason)
            close_quietly(context, browser)
            return 1

        # Persist in two places:
        #   1) amazon-orders cookie_jar_path: simple {name: value} dict
        #   2) Playwright storageState: full storage for future Playwright runs (e.g., `amazon buy`)
        ao_cookies = {name: c.get("value", "") for name, c in amazon_cookies.items()}
        write_private(cookies_path, json.dumps(ao_cookies))

        # Playwright writes this one itself, so it goes to a temp path and gets
        # moved into place — same reason as the jar, and it has to land 0600
        # before it is readable under its real name.
        tmp_state = storage_state_path.with_name(storage_state_path.name + ".tmp")
        context.storage_state(path=str(tmp_state))
        os.chmod(tmp_state, 0o600)
        os.replace(tmp_state, storage_state_path)

        emit("done", cookies_path=str(cookies_path), count=len(ao_cookies))

        close_quietly(context, browser)

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as e:  # noqa: BLE001
        # Several statements in `main()` sit outside any handler and raise
        # straight out — `page.goto`, the two writes, the chmods. A disk-full
        # `OSError` used to leave the traceback on stderr, which the Ruby side
        # only prints under -v, so the user got an exit code and no output at
        # all. Put the failure on the NDJSON channel the parent actually reads;
        # the traceback still goes to stderr for anyone who wants it.
        emit("error", msg=f"login worker crashed: {type(e).__name__}: {e}")
        traceback.print_exc()
        sys.exit(1)
