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
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any

from amazonorders.conf import AmazonOrdersConfig
from amazonorders.session import AmazonSession, IODefault
from amazonorders.orders import AmazonOrders


def emit(event: str, **fields: Any) -> None:
    sys.stdout.write(json.dumps({"event": event, **fields}, default=_json_default) + "\n")
    sys.stdout.flush()


def _json_default(obj: Any) -> Any:
    if isinstance(obj, (date, datetime)):
        return obj.isoformat()
    raise TypeError(f"not serializable: {type(obj).__name__}")


class WorkerIO(IODefault):
    """Bridge amazon-orders prompts to the Ruby parent over stdin/stdout."""

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

    email = req.get("email")
    password = req.get("password")
    years = req.get("years") or [date.today().year]
    full_details = bool(req.get("full_details", True))
    otp_secret = req.get("otp_secret")
    known_order_ids = set(req.get("known_order_ids") or [])
    # Rate-limit knobs (seconds). Conservative defaults so Amazon doesn't 503.
    detail_delay = float(req.get("detail_delay", 0.1))
    detail_jitter = float(req.get("detail_jitter", 0.1))
    retry_backoff = [float(x) for x in (req.get("retry_backoff") or [30, 60, 120])]

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

    config = AmazonOrdersConfig(
        config_path=str(config_dir / "amazon-orders.yml"),
        data={
            "cookie_jar_path": str(cache_dir / "cookies.json"),
            "output_dir": str(cache_dir / "output"),
            # Cap parallel detail fetches; Amazon 503s above ~5 concurrent.
            "thread_pool_size": 5,
            "connection_pool_size": 10,
        },
    )

    session = AmazonSession(
        username=email,
        password=password,
        io=WorkerIO(),
        config=config,
        otp_secret_key=otp_secret,
    )

    try:
        session.login()
    except Exception as e:  # noqa: BLE001 — surface any auth failure to parent
        emit("error", msg=f"login failed: {e}")
        return 1

    api = AmazonOrders(session, config=config)

    import amazonorders as _ao_mod

    total = 0
    skipped = 0
    for year in years:
        emit("log", level="info", msg=f"fetching year {year} (history page)")
        try:
            orders = api.get_order_history(year=int(year), full_details=False)
        except Exception as e:  # noqa: BLE001
            emit("error", msg=f"history fetch failed for {year}: {e}", trace=traceback.format_exc())
            return 1

        n = len(orders)
        new_orders = [o for o in orders if o.order_number not in known_order_ids]
        cached_count = n - len(new_orders)
        emit("total", year=int(year), count=n, new=len(new_orders), cached=cached_count)
        if cached_count:
            emit("log", level="info", msg=f"year {year}: skipping {cached_count} already-stored orders")
        for i, order in enumerate(new_orders, start=1):
            first_item = order.items[0] if getattr(order, "items", None) else None
            title = (getattr(first_item, "title", "") or "").strip()[:60] if first_item else ""
            emit(
                "progress",
                year=int(year),
                i=i,
                n=len(new_orders),
                order_id=order.order_number,
                date=order.order_placed_date.isoformat() if order.order_placed_date else None,
                grand_total=order.grand_total,
                title=title,
            )
            if full_details:
                order = _fetch_with_retry(
                    api, order, retry_backoff, emit_fn=emit
                ) or order
                if i < len(new_orders):
                    sleep_for = detail_delay + random.uniform(-detail_jitter, detail_jitter)
                    if sleep_for > 0:
                        time.sleep(sleep_for)
            emit("order", data=order_to_dict(order, _ao_mod.__version__))
            total += 1

    emit("done", count=total, skipped=skipped)
    return 0


if __name__ == "__main__":
    sys.exit(main())
