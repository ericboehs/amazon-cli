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

import contextlib
import fcntl
import json
import os
import random
import sys
import time
import traceback
from collections.abc import Container, Sequence
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

# The one every consumer decides on: amazon-orders' COOKIES_SET_WHEN_AUTHENTICATED
# is `["x-main"]`, and `sync.rb`'s `cookies_authenticated?` reads the same name.
# Losing it is what costs you the session; the rest are collateral, put back by
# the repair but never the thing that arms it.
AUTH_COOKIE = "x-main"


def _jar_dict(raw: str | None) -> dict[str, Any]:
    """A jar blob as a mapping. Anything unreadable is `{}` — never an exception."""
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        return {}
    return data if isinstance(data, dict) else {}


def jar_cookie_names(raw: str | None) -> set[str]:
    """Names of the cookies a jar actually holds.

    A name with an empty value doesn't count. Deleting a cookie over HTTP is
    setting it to `""` with an expiry in the past, and requests' jar keeps the
    name — so the quiet form of a sign-in bounce leaves `x-main` sitting there,
    empty. Counting that as held reads a deletion as a session: the strip this
    module exists to catch stops looking like one, and the restore never fires.

    Values are compared against nothing and never leave this function.
    """
    return {name for name, value in _jar_dict(raw).items() if value}


def jar_regressed(before: str | None, after: str | None) -> bool:
    """True when a run lost the sign-in cookie the jar had going in.

    Compares names, not contents: a jar that merely gained or refreshed cookies
    is a normal, healthy write and must be left alone.

    Only `x-main` arms it. `ubid-main` is a device id Amazon sets before you
    have ever signed in, so counting its loss put the rollback on a hair
    trigger over jars that were never sessions — the first sync of a new
    install being the worst case, where what it would roll back over is the jar
    the login had just earned. A rollback is a destructive act; it should need
    the one cookie whose absence actually costs you the session.
    """
    if before is None:
        return False
    return AUTH_COOKIE in jar_cookie_names(before) and AUTH_COOKIE not in jar_cookie_names(after)


def repaired_jar(before: str | None, after: str | None) -> str:
    """The pre-run jar with everything this run actually wrote layered on top.

    Rolling the file back wholesale undoes more than the failure did. Amazon
    rotates its anonymous cookies constantly and amazon-orders persists every
    one of those writes, so a jar restored byte-for-byte comes back stale in
    ways that had nothing to do with the bounce. Overlaying keeps every value
    the run wrote and puts back only what it dropped — which on a wiped jar is
    still the whole thing, and on a stripped one is just the sign-in cookies.

    Empty values are not written: they are how the strip spells a deletion, and
    letting them win here would be restoring the damage.
    """
    merged = _jar_dict(before)
    merged.update({name: value for name, value in _jar_dict(after).items() if value})
    return json.dumps(merged)


def write_jar(cookies_path: Path, content: str) -> None:
    """Replace the jar with `content`, atomically and never world-readable.

    Both writers here exist to stop a bad jar reaching disk, so neither can
    afford to be a way one gets there. `write_text` truncates first: a crash
    between truncate and write leaves a half-written jar, and the damage then
    surfaces on some later command as unparseable JSON, pointing at the reader
    rather than at the run that broke it. chmod-after-write has the same shape
    in the other dimension — the file is briefly 0644 with live session cookies
    in it, on a path any local process can read.

    Writing a private temp file and renaming it over the target closes both:
    `os.replace` is atomic, so a reader sees the old jar or the new one, and the
    mode is set before the content is reachable under the real name.
    """
    tmp = cookies_path.with_name(cookies_path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(content)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, cookies_path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


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
        write_jar(cookies_path, cleared)
    except Exception as e:  # noqa: BLE001 — see the note in `restore_jar`
        emit("log", level="warn", msg=f"could not clear the dead session's cookies: {e}")
        return False
    return True


def split_known(
    orders: Sequence[Any], known_order_ids: Container[str]
) -> tuple[list[Any], dict[str, int]]:
    """Partition a year's listing, and the `total` event's payload alongside it.

    Three numbers rather than one, because a zero in `new` has two opposite
    causes — Amazon listed nothing, or everything it listed is already on disk —
    and an event carrying only that number cannot say which happened. It used to
    send `count` and `new` from the same variable, so `worker.rb` printed
    "year 2026: 0 orders" for an account holding 222 of them.

    These key names are a contract with `Worker::Progress#start` on the Ruby
    side, which reads all three by name. Nothing in either suite crosses that
    boundary, so a rename here fails no test over there — hence pinning the
    names in `SplitKnownTest` rather than leaving them implicit in a kwargs
    call halfway down `main`.
    """
    new_orders = [o for o in orders if o.order_number not in known_order_ids]
    return new_orders, {
        "listed": len(orders),
        "new": len(new_orders),
        "cached": len(orders) - len(new_orders),
    }


def restore_jar(cookies_path: Path, jar_before: str | None, reason: str) -> bool:
    """Put the pre-run jar back if this run stripped its sign-in cookies.

    `jar_before` is the snapshot taken before amazon-orders could touch the
    file. It is held in memory only and written back solely to the file it came
    from. Returns whether it wrote, which is also whether the caller's run
    damaged something.

    Nothing in here may escape. This is best-effort cleanup running alongside a
    diagnostic the user needs, and `read_text()` raises `UnicodeDecodeError` —
    a `ValueError`, not an `OSError` — on a jar with invalid UTF-8, which is
    exactly what a killed write leaves behind. Escaping used to take `main()`
    with it, so the sign-in bounce that this whole path exists to explain
    reached the user as `python worker exited 1`, with no error event for the
    stderr tail to attach to either.
    """
    if jar_before is None:
        return False
    try:
        after = cookies_path.read_text() if cookies_path.exists() else None
        if not jar_regressed(jar_before, after):
            return False
        write_jar(cookies_path, repaired_jar(jar_before, after))
    except Exception as e:  # noqa: BLE001 — cleanup must not outrank the message
        emit("log", level="warn", msg=f"could not restore the cookie jar: {e}")
        return False
    emit(
        "log",
        level="warn",
        msg=(
            f"{reason} stripped the saved sign-in cookies from {cookies_path}; "
            "put them back. Your session may still be dead — but a failed sync "
            "no longer destroys a working one."
        ),
    )
    return True


class JarGuard:
    """Owns the cookie jar for the length of one sync.

    Owns, exclusively: everything below assumes the file only changes because
    of this run. Two syncs at once — a cron job and a hand-run one, which is
    the ordinary way this happens — each snapshot the jar and each write their
    snapshot back, so the one that finishes second reverts the other's work.
    The claim is an `flock` on a sidecar, taken before the snapshot and held to
    the end of the run; a run that can't take it does nothing at all. The lock
    can't outlive the process that took it, so a killed sync leaves nothing to
    clean up.

    It holds three more things that have to stay together: the pre-run
    snapshot, the write-back that undoes damage, and a one-way latch saying
    Amazon has declared this session dead.

    The latch is the part that isn't optional. Restoring and clearing are exact
    opposites, and the run that clears is followed by the same cleanup as every
    other run — so without it, `clear()` strips `x-main` and the restore on the
    way out reads that as a regression and puts it straight back. That is
    finding 1 reappearing through the door marked "cleanup", which is precisely
    the kind of bug that survives being fixed once. Once `clear()` has been
    called, no restore can run.
    """

    def __init__(self, cookies_path: Path) -> None:
        self.cookies_path = cookies_path
        self.dead = False
        self._lock_fd: int | None = None
        self.locked = self._claim()
        # Read under the claim, before amazon-orders can touch the file. Held
        # in memory only, and written back solely to the file it came from.
        self.jar_before = self._snapshot() if self.locked else None

    def _claim(self) -> bool:
        """Whether this run owns the jar. False only when another run does.

        The lock lives on a sidecar rather than on the jar itself: `write_jar`
        replaces the file by rename, so a lock held on the jar's inode would
        stop being the lock the next process finds.

        Scope, deliberately: this serialises syncs against each other, and
        nothing else. `amazon login` (login.py) writes the same cookies.json
        without taking this lock, so a login racing a sync is still unprotected
        — it just isn't the collision that motivated this. Closing that gap
        belongs with the atomic-write helper both files now have a copy of;
        when those are hoisted into browser.py, a shared `jar_lock()` goes with
        them and this claim moves to it.
        """
        lock_path = self.cookies_path.with_name(self.cookies_path.name + ".lock")
        try:
            fd = os.open(lock_path, os.O_WRONLY | os.O_CREAT, 0o600)
        except OSError as e:
            # Not being able to check is not a reason to refuse to sync. Say
            # the check is off and carry on: the collision it guards against is
            # rare, and a sync that won't run is a certainty.
            emit("log", level="warn", msg=(
                f"cannot open {lock_path} ({e}) — two syncs at once would race "
                "over the cookie jar"
            ))
            return True
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            return False
        self._lock_fd = fd
        return True

    def close(self) -> None:
        """Drop the claim. Idempotent; the OS would do it at exit anyway."""
        if self._lock_fd is not None:
            os.close(self._lock_fd)  # releases the flock
            self._lock_fd = None
        self.locked = False

    def resnapshot(self) -> None:
        """Start protecting the jar as it stands now.

        Called once a real sign-in has succeeded. amazon-orders persists the
        jar after every request, including the ones inside a password login, so
        a run that authenticates for real has already written a *better* jar
        than the one this guard was constructed with. Without this, a later
        bounce rolls that fresh session back to the stale pre-login one — and
        the stale `x-main` is enough for `cookies_authenticated?`, so the next
        run walks into the placeholder-password loop. The fix would be handing
        back the harm it exists to prevent, on the one path that just spent a
        password challenge earning something worth keeping.
        """
        self.jar_before = self._snapshot()

    def _snapshot(self) -> str | None:
        try:
            return self.cookies_path.read_text() if self.cookies_path.exists() else None
        except (OSError, ValueError) as e:
            # Say so. `None` is also how "first-ever sync, nothing to protect"
            # is spelled, so swallowing this left the two indistinguishable and
            # turned the whole feature off without a word — the session then
            # dies exactly as it did before the fix, and nothing in the output
            # suggests the net was never strung up. Reachable through a jar
            # written by an earlier run under sudo or launchd, an NFS
            # `XDG_DATA_HOME` going stale, or EMFILE under load.
            emit("log", level="warn", msg=(
                f"cannot read {self.cookies_path} ({e}) — if Amazon bounces this "
                "sync it will leave the stripped jar there instead of putting "
                "yours back"
            ))
            return None

    def restore(self, reason: str) -> bool:
        """Undo a strip, unless Amazon has told us there's nothing worth undoing."""
        if self.dead or not self.locked:
            return False
        return restore_jar(self.cookies_path, self.jar_before, reason)

    def clear(self) -> bool:
        """Latch the session dead and drop its cookies. Never reversible."""
        if not self.locked:
            return False
        self.dead = True
        return clear_dead_session(self.cookies_path)


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


# Why an order was lost, which is the whole difference between a run worth
# failing and one worth a warning.
TRANSIENT = "transient"
PERMANENT = "permanent"

# Exceptions amazon-orders raises when the page itself can't be turned into an
# order: a required field its selectors can't find, or an order that isn't
# there. Retrying is pointless, and so is failing the run — the next sync hits
# the identical failure, so a non-zero exit here is one the tool can never get
# out of on its own. amazon-orders' own default (`warn_on_missing_required_field`)
# concedes this class is routine on pre-2018 orders.
#
# Matched by exact type name, not `isinstance`: `AmazonOrdersAuthError`
# subclasses `AmazonOrdersError`, and an expired session is the one loss with
# an obvious fix. Name matching also means a rename in a future amazon-orders
# silently stops matching, so `PackageAssumptionsTest` checks these names
# against the installed package.
UNFETCHABLE_ERRORS = (
    "AmazonOrdersError",
    "AmazonOrdersEntityError",
    "AmazonOrdersNotFoundError",
)


def _throttled(msg: str) -> bool:
    """True when Amazon is objecting to the pace rather than to the order."""
    lowered = msg.lower()
    return "503" in msg or "throttle" in lowered or "rate" in lowered


def classify_failure(e: BaseException) -> str:
    """Whether a failed detail fetch is worth another attempt, ever.

    The throttle check goes first so this and the retry decision below cannot
    disagree about the same exception. Everything unrecognized is `TRANSIENT`:
    the list above is an allowlist because the two mistakes don't cost the
    same — calling an outage permanent turns a real failure into a warning
    nobody reads, while calling a parse error transient costs three retries and
    an exit code that is at worst too honest.
    """
    if _throttled(str(e)):
        return TRANSIENT
    return PERMANENT if type(e).__name__ in UNFETCHABLE_ERRORS else TRANSIENT


def _fetch_with_retry(api: Any, order: Any, backoff: list[float],
                      emit_fn: Any) -> tuple[Any, str | None]:
    """Fetch full order details with retry-on-503.

    Returns `(order, None)`, or `(None, reason)` — the reason being what the
    caller needs to tell "Amazon started bouncing us at order 150" apart from
    "this 2016 order has never been parseable."
    """
    for attempt, wait in enumerate([0.0, *backoff]):
        if wait > 0:
            emit_fn("log", level="warn",
                    msg=f"retrying {order.order_number} after {wait:.0f}s (attempt {attempt})")
            time.sleep(wait)
        try:
            fetched = api.get_order(order.order_number, clone=order)
        except Exception as e:  # noqa: BLE001
            if attempt < len(backoff) and _throttled(str(e)):
                continue
            emit_fn("log", level="warn",
                    msg=f"detail fetch skipped for {order.order_number}: {e}")
            return None, classify_failure(e)
        # A library that returns nothing without raising has said nothing about
        # why, and unexplained is loud. `is None` and not truthiness: an `Order`
        # that grew a `__len__` over its items would make a real zero-item order
        # falsy, and it would come back here as a loss that fails the sync.
        return (fetched, None) if fetched is not None else (None, TRANSIENT)
    return None, TRANSIENT


def _name_some(numbers: list[str], limit: int = 5) -> str:
    shown = ", ".join(numbers[:limit])
    return shown + (f" (and {len(numbers) - limit} more)" if len(numbers) > limit else "")


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
    # `or` would read an explicit `[]` — a config saying "don't retry" — as
    # absent and hand back the three-attempt default, which is over three
    # minutes of sleeping per order the user asked not to wait on.
    raw_backoff = req.get("retry_backoff")
    retry_backoff = ([float(x) for x in raw_backoff] if isinstance(raw_backoff, list)
                     else [30.0, 60.0, 120.0])
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
    guard = JarGuard(cookies_path)
    if not guard.locked:
        emit("error", msg=(
            "another `amazon order sync` is already running — it owns the cookie "
            f"jar at {cookies_path}. Nothing was fetched. Wait for it to finish "
            "and try again."))
        return 1

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
        try:
            session.login()
        except Exception as e:  # noqa: BLE001 — surface any auth failure to parent
            emit("error", msg=f"login failed: {e}")
            guard.restore("the login attempt")
            return 1

        # Whatever is on disk now is the session we just proved good. Anything
        # older than this line is only worth putting back if this line never ran.
        guard.resnapshot()

        api = AmazonOrders(session, config=config)

        total = 0
        skipped = 0
        lost: dict[str, str] = {}
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
                    # The message goes first. It is the only actionable thing
                    # the user gets on this path, and best-effort cleanup has
                    # no business being able to preempt it.
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
                    # Not a restore. Amazon has just proven these cookies are
                    # dead, and putting them back is what leaves
                    # `cookies_authenticated?` answering yes forever.
                    guard.clear()
                    return 1
                emit("error", msg=f"history fetch failed for {year}: {e}", trace=traceback.format_exc())
                guard.restore(f"the failed {year} history fetch")
                return 1

            new_orders, totals = split_known(orders, known_order_ids)
            new_n = totals["new"]
            cached_count = totals["cached"]
            emit("total", year=int(year), **totals)
            skipped += cached_count
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
                    fetched, why = None, TRANSIENT
                    try:
                        fetched, why = fut.result()
                    except Exception as e:  # noqa: BLE001
                        # Nothing should escape `_fetch_with_retry`, so this is
                        # our bug rather than Amazon's — which is exactly the
                        # kind of loss that has to stay loud.
                        emit("log", level="warn",
                             msg=f"detail fetch raised for {original.order_number}: {e}")
                    _emit_progress(year, completed, new_n, fetched or original)
                    if fetched is None:
                        # Not `fetched or original`. The parent writes every
                        # order event it is handed and feeds those ids back as
                        # `known_order_ids`, so emitting the history-page stub
                        # caches a detail-less order permanently: the next sync
                        # sees the id, calls it already-stored, and never tries
                        # again. Being forgiving here is what makes the loss
                        # unrecoverable. Leaving it out costs one order this
                        # run and gets it in full on the next.
                        lost[original.order_number] = why or TRANSIENT
                        continue
                    emit("order", data=order_to_dict(fetched, _ao_mod.__version__))
                    total += 1

        unfetchable = [n for n, why in lost.items() if why == PERMANENT]
        bounced = [n for n, why in lost.items() if why != PERMANENT]

        if unfetchable:
            # Loud, but not fatal. These fail the same way every run, so an exit
            # code would be an alarm that can never be cleared. They stay out of
            # the store, so whenever Amazon's HTML changes back a later sync
            # picks them up with no intervention.
            emit("log", level="warn", msg=(
                f"{len(unfetchable)} order(s) could not be parsed from Amazon's page and "
                f"were left unstored: {_name_some(unfetchable)}. This is usually an older "
                "order missing a field the parser requires; later syncs will keep trying."))

        if bounced:
            # An `error` rather than a `done`: the parent stops at whichever
            # arrives first, keeps the orders it already received, and exits
            # non-zero. Silently exiting 0 is what makes a sync that gave up on
            # orders indistinguishable from a complete one to cron and `&&`.
            # The counts ride along because this is the run where the shape of
            # what was kept matters most, and it was the one run not printing it.
            emit("error", count=total, skipped=skipped, msg=(
                f"could not fetch full details for {len(bounced)} order(s): "
                f"{_name_some(bounced)}. Kept {total} order(s) ({skipped} already stored); "
                "the rest were left unstored so the next sync retries them."))
            return 1

        emit("done", count=total, skipped=skipped)
        return 0
    finally:
        # Not a list of known failures — the ones that matter are the ones
        # nobody enumerated. A long full-details sync is interrupted by hand
        # constantly, and Ctrl-C during `as_completed` unwinds straight past
        # every explicit call site above, leaving a stripped jar on disk:
        # this fix's own bug, on its most likely path. Restoring is
        # idempotent — with nothing to undo it writes nothing and says
        # nothing — so the backstop costs a no-op on the happy path.
        guard.restore("this sync")
        guard.close()


if __name__ == "__main__":
    sys.exit(main())
