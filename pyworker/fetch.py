"""
Amazon CLI Python worker.

Reads a single JSON request from stdin describing the action to perform,
then drives `amazon-orders` to log in and fetch order history.

Protocol (NDJSON over stdout):
    {"event":"otp_required","prompt":"..."}      # then read one line on stdin
    {"event":"prompt","prompt":"...","kind":"text"|"choice","choices":[...]}
    {"event":"log","level":"info","msg":"..."}
    {"event":"order","data":{...}}               # one per order
    {"event":"done","count":N}
    {"event":"error","msg":"..."}

Stdin (one-shot request):
    {"action":"sync","email":"...","password":"...","years":[2025,2024],
     "full_details":true,"otp_secret":null}

The worker never logs the password. Cookies are persisted under
$XDG_DATA_HOME/amazon/cache/ so subsequent runs skip 2FA.
"""

from __future__ import annotations

import json
import os
import random
import sys
import time
import traceback
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any

from browser import session_rejected

# amazon-orders is imported inside `main()`, not here. CI runs the pyworker
# tests on a bare interpreter with no dependency install, so anything imported
# at module scope has to exist in an empty environment or the whole test file
# becomes uncollectable — `live.py` defers playwright for the same reason. The
# cost is confined to `main()`, which cannot run without the package anyway.

# Cookies Amazon only sets for a signed-in session. amazon-orders rewrites the
# whole jar after every request (session.py:213), so when Amazon bounces a
# request to sign-in — expiring these in the response — the stripped jar is
# persisted straight over the good one. The session that `amazon login` just
# spent a password challenge earning is destroyed by the first failed sync, and
# the error's own advice ("Run: amazon login") walks you back into the same trap.
AUTH_COOKIE_NAMES = ("x-main", "at-main", "sess-at-main", "sst-main", "ubid-main")


def jar_cookie_names(raw: str | None) -> set[str]:
    """Cookie *names* in a jar blob. Names only — values are never handled here."""
    if not raw:
        return set()
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        return set()
    return set(data) if isinstance(data, dict) else set()


def jar_regressed(before: str | None, after: str | None) -> bool:
    """True when a run stripped sign-in cookies the jar had going in.

    Compares names, not contents: a jar that merely gained or refreshed cookies
    is a normal, healthy write and must be left alone. Only the loss of an
    authentication cookie means the run traded a working session for a dead one.
    """
    if before is None:
        return False
    had = jar_cookie_names(before) & set(AUTH_COOKIE_NAMES)
    return bool(had - jar_cookie_names(after))


def jar_without_auth(raw: str | None) -> str | None:
    """The jar minus its sign-in cookies, or None when there's nothing to write.

    None covers both "already has none" and "can't be parsed": neither is a jar
    this can safely rewrite, and the caller's fallback in both cases is to leave
    the file exactly as it found it.
    """
    if not raw:
        return None
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        return None
    if not isinstance(data, dict):
        return None
    kept = {k: v for k, v in data.items() if k not in AUTH_COOKIE_NAMES}
    return json.dumps(kept) if len(kept) != len(data) else None


def clear_dead_session(cookies_path: Path) -> bool:
    """Drop the sign-in cookies Amazon has just told us are dead. True if it wrote.

    The exact inverse of restoring the jar, and the distinction is the whole
    point. A stripped jar after a *transient* failure is damage to undo. A jar
    Amazon rejected mid-request is a session that is provably gone, and putting
    it back leaves `sync.rb`'s `cookies_authenticated?` seeing `x-main` with a
    live expiry — so every later sync takes the "we already have cookies" branch
    and posts the literal placeholder `unused-have-cookies` at Amazon's password
    form. Wedged, permanently, with the fix (`amazon login`) being the one thing
    the tool has stopped being able to recommend, because it believes it is
    already logged in.

    Only the auth cookies go. Amazon's anonymous cookies are what the next
    sign-in continues from; deleting the file turns a re-auth into a
    fresh-device challenge. `storage_state.json` is deliberately untouched — it
    is a separate Playwright session that `amazon item` still uses, and it is
    where `sync.rb` reads session expiry from.
    """
    try:
        if not cookies_path.exists():
            return False
        cleared = jar_without_auth(cookies_path.read_text())
        if cleared is None:
            return False
        cookies_path.write_text(cleared)
        os.chmod(cookies_path, 0o600)
    except OSError as e:
        emit("log", level="warn", msg=f"could not clear the dead session's cookies: {e}")
        return False
    return True


def emit(event: str, **fields: Any) -> None:
    sys.stdout.write(json.dumps({"event": event, **fields}, default=_json_default) + "\n")
    sys.stdout.flush()


def _json_default(obj: Any) -> Any:
    if isinstance(obj, (date, datetime)):
        return obj.isoformat()
    raise TypeError(f"not serializable: {type(obj).__name__}")


class WorkerIO:
    """Bridge amazon-orders prompts to the Ruby parent over stdin/stdout.

    `IODefault` is the natural base and is bolted on by `worker_io()` instead of
    in this class statement, because a base class is resolved at import time and
    that is the one thing this module must not need amazon-orders for.
    """

    def echo(self, msg: str, **kwargs: Any) -> None:
        emit("log", level="info", msg=str(msg))

    def prompt(self, msg: str, type: Any = None, **kwargs: Any) -> Any:
        choices = kwargs.get("choices") or []
        kind = "choice" if choices else "text"
        # Heuristic: amazon-orders uses "OTP" / "verification code" wording.
        lowered = str(msg).lower()
        if "otp" in lowered or "verification code" in lowered or "one-time" in lowered:
            emit("otp_required", prompt=str(msg))
        else:
            emit("prompt", prompt=str(msg), kind=kind, choices=[str(c) for c in choices])
        line = sys.stdin.readline()
        if not line:
            raise EOFError("parent closed stdin while prompting")
        return line.rstrip("\n")


def worker_io() -> Any:
    """A `WorkerIO` that amazon-orders will accept.

    Inherits rather than duck-types because amazon-orders calls IO methods this
    module doesn't override, and `IODefault` is where their defaults live.
    """
    from amazonorders.session import IODefault

    class _WorkerIO(WorkerIO, IODefault):
        pass

    return _WorkerIO()


def xdg_path(env: str, default_subpath: str) -> Path:
    base = os.environ.get(env)
    if base:
        return Path(base)
    return Path.home() / default_subpath


def order_to_dict(order: Any, source_version: str) -> dict[str, Any]:
    items = []
    for item in (order.items or []):
        items.append(
            {
                "title": getattr(item, "title", None),
                "link": getattr(item, "link", None),
                "price": getattr(item, "price", None),
                "quantity": getattr(item, "quantity", None),
                "image_link": getattr(item, "image_link", None),
                "seller": _seller_name(getattr(item, "seller", None)),
            }
        )

    shipments = []
    for ship in (order.shipments or []):
        shipments.append(
            {
                "delivery_status": getattr(ship, "delivery_status", None),
                "tracking_link": getattr(ship, "tracking_link", None),
            }
        )

    recipient = order.recipient
    recipient_name = getattr(recipient, "name", None) if recipient else None
    recipient_address = getattr(recipient, "address", None) if recipient else None

    return {
        "order_id": order.order_number,
        "order_placed": order.order_placed_date.isoformat() if order.order_placed_date else None,
        "grand_total": order.grand_total,
        "currency": "USD",
        "order_details_link": order.order_details_link,
        "ship_to": recipient_name,
        "ship_to_address": recipient_address,
        "items": items,
        "shipments": shipments,
        "subtotal": getattr(order, "subtotal", None),
        "shipping_total": getattr(order, "shipping_total", None),
        "estimated_tax": getattr(order, "estimated_tax", None),
        "total_before_tax": getattr(order, "total_before_tax", None),
        "refund_total": getattr(order, "refund_total", None),
        "payment_method": getattr(order, "payment_method", None),
        "payment_method_last_4": getattr(order, "payment_method_last_4", None),
        "_synced_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "_source": f"amazon-orders@{source_version}",
    }


def _seller_name(seller: Any) -> str | None:
    if seller is None:
        return None
    return getattr(seller, "name", None) or str(seller)


def _emit_progress(year: int, i: int, n: int, order: Any) -> None:
    first_item = order.items[0] if getattr(order, "items", None) else None
    title = (getattr(first_item, "title", "") or "").strip()[:60] if first_item else ""
    emit(
        "progress",
        year=int(year),
        i=i,
        n=n,
        order_id=order.order_number,
        date=order.order_placed_date.isoformat() if order.order_placed_date else None,
        grand_total=order.grand_total,
        title=title,
    )


def _fetch_with_retry(api: Any, order: Any, backoff: list[float], emit_fn: Any) -> Any:
    """Fetch full order details with retry-on-503. Returns the populated order, or None to skip."""
    for attempt, wait in enumerate([0.0, *backoff]):
        if wait > 0:
            emit_fn("log", level="warn",
                    msg=f"retrying {order.order_number} after {wait:.0f}s (attempt {attempt})")
            time.sleep(wait)
        try:
            return api.get_order(order.order_number, clone=order)
        except Exception as e:  # noqa: BLE001
            msg = str(e)
            transient = "503" in msg or "throttle" in msg.lower() or "rate" in msg.lower()
            if attempt >= len(backoff) or not transient:
                emit_fn("log", level="warn",
                        msg=f"detail fetch skipped for {order.order_number}: {e}")
                return None
    return None


def main() -> int:
    raw = sys.stdin.readline()
    if not raw:
        emit("error", msg="empty stdin; expected request JSON on first line")
        return 2
    try:
        req = json.loads(raw)
    except json.JSONDecodeError as e:
        emit("error", msg=f"invalid request JSON: {e}")
        return 2

    action = req.get("action")
    if action != "sync":
        emit("error", msg=f"unsupported action: {action!r}")
        return 2

    try:
        import amazonorders as _ao_mod
        from amazonorders.conf import AmazonOrdersConfig
        from amazonorders.orders import AmazonOrders
        from amazonorders.session import AmazonSession
    except ImportError as e:
        emit("error", msg=f"amazon-orders not installed: {e}")
        return 2

    email = req.get("email")
    password = req.get("password")
    years = req.get("years") or [date.today().year]
    full_details = bool(req.get("full_details", True))
    otp_secret = req.get("otp_secret")
    known_order_ids = set(req.get("known_order_ids") or [])
    # Rate-limit knobs (seconds). Conservative defaults so Amazon doesn't 503.
    detail_delay = float(req.get("detail_delay", 0.05))
    detail_jitter = float(req.get("detail_jitter", 0.05))
    retry_backoff = [float(x) for x in (req.get("retry_backoff") or [30, 60, 120])]
    workers = int(req.get("workers", 7))

    if not email or not password:
        emit("error", msg="email and password are required")
        return 2

    cache_dir = xdg_path("XDG_DATA_HOME", ".local/share") / "amazon" / "cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(cache_dir, 0o700)
    except OSError:
        pass

    config_dir = xdg_path("XDG_CONFIG_HOME", ".config") / "amazon"
    config_dir.mkdir(parents=True, exist_ok=True)

    cookies_path = cache_dir / "cookies.json"
    # Read the jar before amazon-orders can touch it. Held in memory only, and
    # written back solely to the file it came from.
    try:
        jar_before = cookies_path.read_text() if cookies_path.exists() else None
    except OSError:
        jar_before = None

    def restore_jar(reason: str) -> None:
        """Put the pre-run jar back if this run stripped its sign-in cookies."""
        if jar_before is None:
            return
        try:
            after = cookies_path.read_text() if cookies_path.exists() else None
            if not jar_regressed(jar_before, after):
                return
            cookies_path.write_text(jar_before)
            os.chmod(cookies_path, 0o600)
        except OSError as e:
            emit("log", level="warn", msg=f"could not restore the cookie jar: {e}")
            return
        emit(
            "log",
            level="warn",
            msg=(
                f"{reason} stripped the saved sign-in cookies from {cookies_path}; "
                "restored the jar as it was. Your session may still be dead — but "
                "a failed sync no longer destroys a working one."
            ),
        )

    config = AmazonOrdersConfig(
        config_path=str(config_dir / "amazon-orders.yml"),
        data={
            "cookie_jar_path": str(cookies_path),
            "output_dir": str(cache_dir / "output"),
            # Cap parallel detail fetches; Amazon 503s above ~7 concurrent.
            "thread_pool_size": 7,
            "connection_pool_size": 14,
            # Don't blow up the whole year if one ancient order has an
            # unparseable required field (common on pre-2018 orders).
            "warn_on_missing_required_field": True,
        },
    )

    session = AmazonSession(
        username=email,
        password=password,
        io=worker_io(),
        config=config,
        otp_secret_key=otp_secret,
    )

    try:
        session.login()
    except Exception as e:  # noqa: BLE001 — surface any auth failure to parent
        restore_jar("the login attempt")
        emit("error", msg=f"login failed: {e}")
        return 1

    api = AmazonOrders(session, config=config)

    total = 0
    skipped = 0
    for year in years:
        emit("log", level="info", msg=f"fetching year {year} (history page)")
        try:
            orders = api.get_order_history(year=int(year), full_details=False)
        except Exception as e:  # noqa: BLE001
            # amazon-orders trusts the cookie jar on disk, so `session.login()`
            # returns without a network call and the first real request is what
            # discovers the session is dead. Its own message tells you to call
            # AmazonSession.login() — useless advice from a CLI.
            if session_rejected(e):
                # Not a restore. Amazon has just proven these cookies are dead,
                # and putting them back is what leaves `cookies_authenticated?`
                # answering yes forever — see `clear_dead_session`.
                clear_dead_session(cookies_path)
                emit(
                    "error",
                    kind="not_logged_in",
                    msg=(
                        "Amazon rejected the saved session — it redirected to the "
                        "login page. Cookie expiry can't detect this; the session "
                        "was invalidated server-side. The dead sign-in cookies have "
                        "been cleared so the next run signs in properly. "
                        "Run: amazon login"
                    ),
                )
                return 1
            restore_jar(f"the failed {year} history fetch")
            emit("error", msg=f"history fetch failed for {year}: {e}", trace=traceback.format_exc())
            return 1

        n = len(orders)
        new_orders = [o for o in orders if o.order_number not in known_order_ids]
        new_n = len(new_orders)
        cached_count = n - new_n
        emit("total", year=int(year), count=new_n, new=new_n, cached=cached_count)
        if cached_count:
            emit("log", level="info", msg=f"year {year}: skipping {cached_count} already-stored orders")

        if not full_details:
            for i, order in enumerate(new_orders, start=1):
                _emit_progress(year, i, new_n, order)
                emit("order", data=order_to_dict(order, _ao_mod.__version__))
                total += 1
            continue

        # Parallel detail fetches with throttled submission.
        completed = 0
        with ThreadPoolExecutor(max_workers=workers) as pool:
            futures = {}
            for order in new_orders:
                fut = pool.submit(_fetch_with_retry, api, order, retry_backoff, emit)
                futures[fut] = order
                if detail_delay > 0:
                    sleep_for = detail_delay + random.uniform(-detail_jitter, detail_jitter)
                    if sleep_for > 0:
                        time.sleep(sleep_for)
            for fut in as_completed(futures):
                completed += 1
                original = futures[fut]
                fetched = None
                try:
                    fetched = fut.result()
                except Exception as e:  # noqa: BLE001
                    emit("log", level="warn",
                         msg=f"detail fetch raised for {original.order_number}: {e}")
                order = fetched or original
                _emit_progress(year, completed, new_n, order)
                emit("order", data=order_to_dict(order, _ao_mod.__version__))
                total += 1

    # Detail-fetch failures are caught per-order and only logged, so a run that
    # got bounced part-way through can strip the jar and still exit 0, never
    # touching an error path. A run that genuinely worked never ends holding
    # fewer sign-in cookies than it started with, so this is safe to assert.
    restore_jar("this sync")

    emit("done", count=total, skipped=skipped)
    return 0


if __name__ == "__main__":
    sys.exit(main())
