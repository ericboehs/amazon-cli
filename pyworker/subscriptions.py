"""
Subscribe & Save worker: what you're subscribed to, and what ships next.

Amazon has no customer-facing API for this — the Replenishment SP-API is
seller-side offer metrics — so everything here is scraped from the signed-in
`/auto-deliveries/` pages through the session `amazon login` saved.

Two views, because Amazon splits the data across two and neither is a superset:

    subscriptions  what you subscribe to: title, schedule, next delivery date
    deliveries     what actually ships on a date: prices, discounts, the
                   last day you can still edit it

Prices live only in the deliveries view. A subscription card doesn't carry one
(the price is whatever it is when the delivery is placed), so `subscriptions`
deliberately reports none rather than inventing one from the product page.

Protocol (NDJSON over stdout):
    {"event":"log","level":"info","msg":"..."}
    {"event":"subscription","data":{...}}     # one per subscription
    {"event":"delivery","data":{...}}         # one per scheduled delivery
    {"event":"done","count":N,"total":N}
    {"event":"error","msg":"...","kind":"not_logged_in"|"blocked"|null}

Stdin (one-shot request):
    {"action":"subscriptions"}
    {"action":"subscriptions","all":true}
    {"action":"deliveries"}

Read-only. Nothing here clicks skip, cancel, or a schedule change; the only
click is "Show more subscriptions", which is pagination.
"""

from __future__ import annotations

import json
import re
import sys
import traceback
from datetime import datetime, timezone
from typing import Any

from browser import (
    Blocked,
    NotLoggedIn,
    attr,
    clean_text,
    emit,
    guard,
    launch,
    new_context,
    parse_money,
    text,
)

SUBSCRIPTION_LIST_URL = "https://www.amazon.com/auto-deliveries/subscriptionList"

# Scoped to the list container on purpose. `.subscription-card` also appears in
# the "recommended for you" carousels further down the same page, and those
# carry no `data-subscription-id` — but they *do* carry titles and frequency
# labels, so an unscoped chain that skipped the id check would report products
# you have never subscribed to as subscriptions.
SUBSCRIPTION_CARD = ".subscription-list-container .subscription-card[data-subscription-id]"
# The deliveries fragments have no list container; there the cards are nested
# inside a delivery card, which is scope enough.
DELIVERY_SUBSCRIPTION_CARD = ".subscription-card[data-subscription-id]"

DELIVERY_CARD = ".delivery-card"

# `.a-truncate-full` is the untruncated copy Amazon keeps for screen readers;
# `.a-truncate-cut` next to it is the visible one, ellipsised mid-word. Reading
# the cut span would silently store "Cascade Free & Clear Dishwasher Detergent…"
# as the product's name.
TITLE_SELECTORS = (
    ".subscription-product-title .a-truncate-full",
    ".subscription-product-title",
)
VARIATION_SELECTORS = (
    ".subscription-product-variation .a-truncate-full",
    ".subscription-product-variation",
)
PRICE_SELECTORS = (".subscription-price",)
DISCOUNT_SELECTORS = (".subscription-discount-message",)

# Amazon's own test hooks. They are the only thing in this card that names
# which of the two identical-looking links is the date and which is the
# schedule, which is also why they are worth a fallback: a `data-cypress`
# attribute is a QA convenience, not a contract with anyone outside Amazon.
NEXT_DELIVERY_SELECTOR = "a[data-cypress='copa-link-updateDeliveryDate']"
SCHEDULE_SELECTOR = "a[data-cypress='copa-link-updateDeliveryFrequency']"
COPA_CONTAINER = ".copa-ingress-container"
COPA_LINK = ".consumption-pattern-ingress-text"
# The label sitting above the date link. The schedule link's own label is
# empty, so this distinguishes them without relying on document order.
NEXT_DELIVERY_LABEL_RE = re.compile(r"next delivery", re.IGNORECASE)

# "1 unit every 1 month", "2 units every 3 weeks".
SCHEDULE_RE = re.compile(
    r"^\s*(?P<qty>\d+)\s+units?\s+every\s+(?P<count>\d+)\s+(?P<unit>week|month)s?\s*$",
    re.IGNORECASE,
)

# Amazon publishes the pagination cursor, the deliveries tab URL, and the
# future-deliveries URL as JSON in `<script type="a-state">` blocks. Following
# those beats constructing URLs from a shipId we scraped: the parameters they
# carry (listFilter, ref_, deviceType) are Amazon's business, and a hand-built
# URL that drops one silently returns a different list.
PAGINATION_KEY = "subscription-list-pagination"
NAVIGATION_KEY = "navigation-page-state"
FUTURE_DELIVERIES_KEY = "future-delivery-list"

# Pagination stops when the cards on the page reach the total Amazon claims.
# This is the backstop for the case where it doesn't — a click that adds
# nothing would otherwise spin forever against Amazon.
MAX_PAGES = 20
PAGE_SETTLE_MS = 2500
# The trigger stays in the DOM after the last page and is simply hidden, so a
# click on it can never succeed. Bounded so discovering that costs a second
# rather than Playwright's 30.
CLICK_TIMEOUT_MS = 5000


def parse_schedule(raw: str | None) -> dict[str, Any]:
    """"1 unit every 1 month" -> quantity, interval, and the raw phrase.

    Unparsed input keeps `schedule_raw` and nulls the rest. The phrase is what
    the user sees on the page, so it is the one field worth preserving verbatim
    even when the shape changes underneath it.
    """
    out: dict[str, Any] = {
        "schedule_raw": raw or None,
        "quantity": None,
        "interval_count": None,
        "interval_unit": None,
    }
    m = SCHEDULE_RE.match(raw or "")
    if not m:
        return out
    out["quantity"] = int(m.group("qty"))
    out["interval_count"] = int(m.group("count"))
    out["interval_unit"] = m.group("unit").lower()
    return out


def parse_epoch_date(raw: str | None) -> str | None:
    """Amazon's millisecond epoch -> "YYYY-MM-DD".

    The timestamps are midnight in the delivery address's timezone, so the UTC
    calendar date is the same date for any US zone (midnight PST is 08:00 UTC,
    midnight EST is 05:00). Reading it as UTC therefore agrees with the header
    Amazon prints beside it, which is checked against the fixture rather than
    asserted here.
    """
    if not raw:
        return None
    try:
        ms = int(raw)
    except (TypeError, ValueError):
        return None
    try:
        return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).date().isoformat()
    except (OverflowError, OSError, ValueError):
        return None


def page_state(scope: Any, key: str) -> dict[str, Any] | None:
    """The JSON body of the `<script type="a-state">` block with this key.

    Returns None when the block is absent or unparseable — both mean "Amazon
    didn't tell us", and neither is worth an exception on a read-only path.
    """
    try:
        scripts = scope.locator('script[type="a-state"]')
        total = scripts.count()
    except Exception:  # noqa: BLE001
        return None
    for i in range(total):
        node = scripts.nth(i)
        try:
            meta = node.get_attribute("data-a-state") or ""
            if json.loads(meta).get("key") != key:
                continue
            bodies = node.all_text_contents()
        except Exception:  # noqa: BLE001
            continue
        for body in bodies:
            try:
                parsed = json.loads(body)
            except (TypeError, ValueError):
                continue
            if isinstance(parsed, dict):
                return parsed
    return None


def _copa_links(card: Any) -> tuple[str | None, str | None]:
    """(next delivery, schedule) when the `data-cypress` hooks are gone.

    Both links render identically — same class, same modal action — so the only
    thing separating them in the markup is the label above the date one
    ("Next delivery by"); the schedule link's label is an empty span. Keying on
    that label rather than on document order is the difference between a
    fallback and a coin flip: if Amazon reorders the two rows, order-based code
    reports the date as the schedule and neither field looks wrong.
    """
    found: list[str | None] = [None, None]
    try:
        containers = card.locator(COPA_CONTAINER)
        total = containers.count()
    except Exception:  # noqa: BLE001
        return (None, None)
    for i in range(total):
        box = containers.nth(i)
        value = text(box, COPA_LINK)
        if not value:
            continue
        label = clean_text(_inner_text(box))
        # The label text contains the link text too, so strip the value before
        # deciding — otherwise a product whose schedule link happens to read
        # "Next delivery" would classify itself as the date.
        label = label.replace(value, " ")
        slot = 0 if NEXT_DELIVERY_LABEL_RE.search(label) else 1
        if found[slot] is None:
            found[slot] = value
    return (found[0], found[1])


def _inner_text(scope: Any) -> str:
    try:
        return scope.inner_text() or ""
    except Exception:  # noqa: BLE001
        return ""


def scrape_subscription_card(card: Any) -> dict[str, Any] | None:
    """One `.subscription-card` -> a record, or None if it has no id.

    A card without `data-subscription-id` is a placeholder ("add a
    subscription") or a recommendation, and there is nothing to act on later.
    """
    sub_id = None
    try:
        sub_id = card.get_attribute("data-subscription-id")
    except Exception:  # noqa: BLE001
        sub_id = None
    if not sub_id:
        return None

    next_delivery = text(card, NEXT_DELIVERY_SELECTOR)
    schedule = text(card, SCHEDULE_SELECTOR)
    if next_delivery is None or schedule is None:
        fallback_date, fallback_schedule = _copa_links(card)
        next_delivery = next_delivery or fallback_date
        schedule = schedule or fallback_schedule

    record: dict[str, Any] = {
        "subscription_id": sub_id,
        "title": text(card, *TITLE_SELECTORS),
        "variation": text(card, *VARIATION_SELECTORS),
        "next_delivery_label": next_delivery,
        "image": attr(card, "img.sns-product-image", "src") or attr(card, "img", "src"),
    }
    record.update(parse_schedule(schedule))
    return record


def scrape_delivery_item(card: Any) -> dict[str, Any] | None:
    sub_id = None
    try:
        sub_id = card.get_attribute("data-subscription-id")
    except Exception:  # noqa: BLE001
        sub_id = None
    if not sub_id:
        return None
    price_raw = text(card, *PRICE_SELECTORS)
    return {
        "subscription_id": sub_id,
        "title": text(card, *TITLE_SELECTORS),
        "variation": text(card, *VARIATION_SELECTORS),
        "price": parse_money(price_raw),
        "price_raw": price_raw,
        "discount": text(card, *DISCOUNT_SELECTORS),
        # Only the current delivery renders skip buttons; a future one has to
        # be brought forward first. Reporting the button's absence is how a
        # later `subscribe skip` knows the difference without guessing from
        # the date.
        "skippable": _has(card, ".skip-subscription-button"),
    }


def _has(scope: Any, selector: str) -> bool | None:
    """None means "couldn't tell" — never read that as False."""
    try:
        return scope.locator(selector).count() > 0
    except Exception:  # noqa: BLE001
        return None


def scrape_delivery_card(card: Any) -> dict[str, Any]:
    epoch = None
    kind = None
    try:
        epoch = card.get_attribute("data-delivery-date")
        kind = card.get_attribute("data-delivery-type")
    except Exception:  # noqa: BLE001
        pass

    items: list[dict[str, Any]] = []
    try:
        nodes = card.locator(DELIVERY_SUBSCRIPTION_CARD)
        for i in range(nodes.count()):
            item = scrape_delivery_item(nodes.nth(i))
            if item:
                items.append(item)
    except Exception:  # noqa: BLE001
        pass

    priced = [i["price"] for i in items if isinstance(i["price"], (int, float))]
    return {
        "date": parse_epoch_date(epoch),
        "date_label": text(card, ".delivery-header-message"),
        "kind": kind,
        # "Last day to edit delivery" — the one date on this page with a
        # deadline attached, and the reason the deliveries view exists at all.
        "editable_until": text(card, ".delivery-blackout-message"),
        "editable_until_label": text(card, ".delivery-blackout-label"),
        # Amazon's savings message is a bare amount ("$1.95"); its label is the
        # only thing that says what the amount *is*, so the two travel together.
        "savings": text(card, ".delivery-savings-message"),
        "savings_label": text(card, ".delivery-savings-label"),
        "tiering": text(card, ".delivery-base-tiering-message"),
        "items": items,
        # Only meaningful where prices render (the current delivery). Summing
        # an empty list to 0.0 would present a future delivery as free.
        "subtotal": round(sum(priced), 2) if priced else None,
    }


def _cards(scope: Any, selector: str) -> list[Any]:
    try:
        nodes = scope.locator(selector)
        return [nodes.nth(i) for i in range(nodes.count())]
    except Exception:  # noqa: BLE001
        return []


def load_all_pages(page: Any) -> None:
    """Click "Show more subscriptions" until the list is whole.

    Clicking rather than re-requesting the pagination URL: the trigger carries
    the page cursor in page state that the click advances, and a GET of that
    URL returns page one every time — the same trap `amazon reviews --pages`
    already fell into once.

    Progress is measured by counting cards, not by re-reading
    `loadedItemCount`. That field is server-rendered into the page once and
    never updated: measured against the live list, one click took the DOM from
    30 cards to all 59 while the state block still read 30. Trusting it meant
    the loop never saw itself finish, clicked a now-hidden trigger, and spent
    Playwright's full 30-second actionability timeout failing to.
    """
    state = page_state(page, PAGINATION_KEY) or {}
    try:
        total = int(state.get("totalItemCount") or 0)
    except (TypeError, ValueError):
        total = 0
    if not total:
        return

    for _ in range(MAX_PAGES):
        before = len(_cards(page, SUBSCRIPTION_CARD))
        if before >= total:
            return
        trigger = page.locator(".subscription-pagination-trigger")
        if not _clickable(trigger):
            emit(
                "log",
                level="warn",
                msg=f"only {before} of {total} subscriptions loaded and no usable "
                "'show more' trigger is on the page — reporting a partial list",
            )
            return
        try:
            trigger.first.click(timeout=CLICK_TIMEOUT_MS)
        except Exception as e:  # noqa: BLE001
            emit(
                "log",
                level="warn",
                msg=f"'show more' would not accept a click at {before} of {total} "
                f"subscriptions ({type(e).__name__}) — reporting a partial list",
            )
            return
        page.wait_for_timeout(PAGE_SETTLE_MS)
        after = len(_cards(page, SUBSCRIPTION_CARD))
        if after <= before:
            emit(
                "log",
                level="warn",
                msg=f"'show more' added no subscriptions (stuck at {after} of "
                f"{total}) — reporting a partial list",
            )
            return
    emit(
        "log",
        level="warn",
        msg=f"stopped after {MAX_PAGES} pages of subscriptions — reporting a partial list",
    )


def _clickable(trigger: Any) -> bool:
    """Present *and* visible. Presence alone is not enough here — see above."""
    try:
        return trigger.count() > 0 and trigger.first.is_visible()
    except Exception:  # noqa: BLE001
        return False


def open_subscription_list(page: Any) -> None:
    page.goto(SUBSCRIPTION_LIST_URL, wait_until="domcontentloaded", timeout=45000)
    # The list container is injected after load; without this the first scrape
    # sees an empty page and reports zero subscriptions, which is the one wrong
    # answer that looks like a correct one.
    try:
        page.wait_for_selector(".subscription-list-container", timeout=15000)
    except Exception:  # noqa: BLE001
        pass
    page.wait_for_timeout(1500)
    guard(page)


def scrape_subscriptions(page: Any, load_all: bool = False) -> tuple[list[dict[str, Any]], int | None]:
    open_subscription_list(page)
    if load_all:
        load_all_pages(page)

    rows = []
    for card in _cards(page, SUBSCRIPTION_CARD):
        record = scrape_subscription_card(card)
        if record:
            rows.append(record)

    state = page_state(page, PAGINATION_KEY) or {}
    total = state.get("totalItemCount")
    _warn_selector_rot(rows)
    return rows, (int(total) if isinstance(total, int) else None)


# Fields every subscription card renders. Each one degrades to null on its own,
# so a rotted chain reads as a complete list of subscriptions that happen to
# have no titles — which is why this counts them instead of trusting the shape.
EXPECTED_SUBSCRIPTION_FIELDS = ("title", "next_delivery_label", "schedule_raw")


def _warn_selector_rot(rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    for field in EXPECTED_SUBSCRIPTION_FIELDS:
        missing = sum(1 for r in rows if not r.get(field))
        if missing == len(rows):
            emit(
                "log",
                level="warn",
                msg=f"every subscription came back with no {field} — the selector "
                "for it has probably changed; the rest of this output is still real",
            )


def scrape_deliveries(page: Any) -> list[dict[str, Any]]:
    """The current delivery, then every future one Amazon has scheduled.

    Both arrive as HTML fragments from URLs the subscription list publishes in
    page state. Navigating straight to a fragment is unusual but it is what the
    tab does; the alternative is clicking through a React hub whose class names
    are content-hashed and change on deploy.
    """
    open_subscription_list(page)

    nav = page_state(page, NAVIGATION_KEY) or {}
    myd_url = ((nav.get("mydTabUpdateAjaxData") or {}).get("ajaxUrl")) or None
    if not myd_url:
        raise RuntimeError(
            "the subscriptions page did not publish a deliveries-tab URL — "
            "Amazon's page state has changed shape"
        )

    page.goto(myd_url, wait_until="domcontentloaded", timeout=45000)
    page.wait_for_timeout(1500)
    guard(page)

    cards = [scrape_delivery_card(c) for c in _cards(page, DELIVERY_CARD)]

    future_url = (page_state(page, FUTURE_DELIVERIES_KEY) or {}).get("ajaxUrl")
    if future_url:
        page.goto(future_url, wait_until="domcontentloaded", timeout=45000)
        page.wait_for_timeout(1500)
        guard(page)
        cards.extend(scrape_delivery_card(c) for c in _cards(page, DELIVERY_CARD))
    else:
        emit(
            "log",
            level="warn",
            msg="no future-deliveries URL in the page state — showing only the "
            "current delivery",
        )

    # A delivery with no date is a card we failed to read, not a delivery, and
    # sorting it against real ones would put it somewhere arbitrary.
    cards.sort(key=lambda c: (c["date"] is None, c["date"] or ""))
    return cards


def main() -> int:
    raw = sys.stdin.readline()
    if not raw.strip():
        emit("error", msg="no request on stdin")
        return 2
    req = json.loads(raw)
    action = req.get("action")

    try:
        from playwright.sync_api import sync_playwright
    except ImportError as e:
        emit("error", msg=f"playwright not installed: {e}")
        return 2

    try:
        with sync_playwright() as p:
            browser = launch(p, headless=True)
            try:
                context = new_context(browser)
                page = context.new_page()

                if action == "subscriptions":
                    load_all = bool(req.get("all"))
                    emit("log", level="info", msg="reading your subscriptions")
                    rows, total = scrape_subscriptions(page, load_all=load_all)
                    for row in rows:
                        emit("subscription", data=row)
                    emit("done", count=len(rows), total=total)

                elif action == "deliveries":
                    emit("log", level="info", msg="reading your scheduled deliveries")
                    cards = scrape_deliveries(page)
                    for card in cards:
                        emit("delivery", data=card)
                    emit("done", count=len(cards))

                else:
                    emit("error", msg=f"unknown action: {action!r}")
                    return 2
            finally:
                browser.close()
    except NotLoggedIn as e:
        emit("error", msg=str(e), kind="not_logged_in")
        return 1
    except Blocked as e:
        emit("error", msg=str(e), kind="blocked")
        return 1
    except Exception as e:  # noqa: BLE001
        print(traceback.format_exc(), file=sys.stderr)
        emit("error", msg=f"{type(e).__name__}: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
