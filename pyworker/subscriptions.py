"""
Subscribe & Save worker: what you're subscribed to, and what ships next.

Amazon has no customer-facing API for this — the Replenishment SP-API is
seller-side offer metrics — so everything here is scraped from the signed-in
`/auto-deliveries/` pages through the session `amazon login` saved.

Two views, because Amazon splits the data across two and neither is a superset:

    subscriptions  what you subscribe to: title, schedule, next delivery date
    deliveries     what actually ships on a date: prices, discounts, the
                   last day you can still edit it
    subscription   one subscription's edit modal: ASIN, seller, backup item,
                   lifetime savings

Prices live only in the deliveries view — a subscription card carries none,
because the price is whatever it is when the delivery is placed. So
`subscriptions` reads both views and joins them on subscription id, rather
than inventing a price from the product page or reporting none at all.

Protocol (NDJSON over stdout):
    {"event":"log","level":"info","msg":"..."}
    {"event":"subscription","data":{...}}     # one per subscription
    {"event":"delivery","data":{...}}         # one per scheduled delivery
    {"event":"detail","data":{...}}           # one subscription, in full
    {"event":"done","count":N,"total":N}
    {"event":"error","msg":"...","kind":"not_logged_in"|"blocked"|null}

Stdin (one-shot request):
    {"action":"subscriptions"}
    {"action":"subscriptions","all":true}
    {"action":"subscriptions","prices":false}
    {"action":"deliveries"}
    {"action":"subscription","subscription_id":"SNSD0_…"}
    {"action":"subscription","query":"dishwasher"}

Read-only. Nothing here clicks skip, cancel, or a schedule change; the only
clicks are "Show more subscriptions" (pagination) and opening an edit modal to
read it.
"""

from __future__ import annotations

import json
import re
import sys
import traceback
from datetime import date, datetime, timezone
from collections.abc import Sequence
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
from live import MONTHS, parse_delivery_date

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

# Skipping is a click, and a click needs the page's JavaScript. The deliveries
# *fragment* we scrape for reading has none — `window.P` is undefined there and
# the Skip button is inert markup, which is a fine thing to read and a useless
# thing to press. The tab control on the subscription list loads the same
# markup into a page that has AUI attached, so mutations go through there.
DELIVERIES_TAB = "a[href*='ref_=myd_nav_op']"
SKIP_BUTTON = ".skip-subscription-button"
SKIP_MODAL = ".confirm-skip-container"
SKIP_APPROVE = "#confirmSkipApprove"
SKIP_TITLE = "#skip-title"
SKIP_WARNING = ".skip-discount-warning"
SKIP_CSRF = "input[name='skip-workflow-csrf']"
DELIVERY_HEADER = ".delivery-header-message"
# Amazon animates the modal in and the tab content is an XHR away.
MODAL_WAIT_MS = 15000
TAB_WAIT_MS = 20000

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

# The edit modal, whose URL each card publishes in a `data-a-modal` payload.
# Following Amazon's own URL rather than assembling one from a scraped shipId:
# the payload carries listFilter and sourcePage too, and a hand-built URL that
# drops them renders a different modal.
EDIT_MODAL_NAME = "editSubscriptionModal"
# `data-cypress` hooks again — Amazon's QA handles, not a contract, so each has
# a structural fallback.
DETAIL_NEXT_DELIVERY = (
    "[data-cypress='next-delivery-date']",
    ".productInformation .a-text-bold",
)
DETAIL_NEXT_DELIVERY_LABEL = ("[data-cypress='next-delivery-date-text']",)
DETAIL_DISCOUNT_NOW = ("a[data-cypress='need-this-item-right-now']",)
DETAIL_TITLE = (".productInformation h2", ".productInformation a")
DETAIL_MERCHANT = (".t-action-type-MERCHANT_INFORMATION",)
DETAIL_SCHEDULE = (".t-action-type-CHANGE_QUANTITY_FREQUENCY .actionDetail",)
DETAIL_BACKUP = (".t-action-type-ADD_BACKUP_ITEM .actionDetail",)
# A stable id on a box whose own class name is content-hashed
# (`_sns-subscription-savings-desktop_style_...`), so the id is the only part
# of it worth depending on.
DETAIL_SAVINGS_BOX = "#subscription-savings-banner"
ACTION_TYPE_RE = re.compile(r"t-action-type-([A-Z_]+)")
# Case-insensitive and applied to the href as-is: upper-casing the URL first
# would break the `/dp/` needle itself, which is a bug that hides because the
# ASIN half of the pattern still looks right.
ASIN_RE = re.compile(r"/dp/([A-Z0-9]{10})", re.IGNORECASE)
# "You have saved $12.34$12.34 on this subscription!" — Amazon renders the
# amount twice, once for screen readers, and `.a-price`'s text is both copies
# run together. Taking the first token is what makes that parse.
MONEY_RE = re.compile(r"\$\s*\d[\d,]*(?:\.\d{2})?")
# "Sold by Amazon.com and top rated sellers" — the label is part of the link.
SOLD_BY_RE = re.compile(r"^\s*sold by\s*:?\s*", re.IGNORECASE)
# "Get it now with 5% off"
PERCENT_RE = re.compile(r"(\d{1,2})\s*%")
# "Select a backup" is Amazon's placeholder for "none set", not a product.
NO_BACKUP_RE = re.compile(r"^\s*select a backup\s*$", re.IGNORECASE)

# "March 3, 2027" — an explicit year, which the list renders once a date is far
# enough out. Without this the year would be inferred, and inference is only
# right for the next twelve months.
LABEL_DATE_WITH_YEAR_RE = re.compile(
    r"(?P<month>" + "|".join(m.capitalize() for m in MONTHS) + r")[a-z]*\s+"
    r"(?P<day>\d{1,2}),?\s+(?P<year>\d{4})",
    re.IGNORECASE,
)

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


def parse_label_date(raw: str | None, today: Any = None) -> str | None:
    """"September 30" / "March 3, 2027" -> ISO, for sorting the list by date.

    Two shapes, because Amazon prints the year only once the date is far
    enough out. The bare shape is `live.parse_delivery_date`'s problem — it
    already infers the year and rolls December into January — but that
    inference caps out at twelve months, so an explicit year has to win before
    it runs. "March 3, 2027" inferred from an August 2026 today happens to come
    out right; "March 3, 2029" does not.
    """
    if not raw:
        return None
    m = LABEL_DATE_WITH_YEAR_RE.search(raw)
    if m:
        try:
            return date(
                int(m.group("year")), MONTHS[m.group("month")[:3].lower()], int(m.group("day"))
            ).isoformat()
        except ValueError:
            return None
    return parse_delivery_date(raw, today=today)


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


# Amazon lazy-loads anything below the fold: `src` holds a 35-byte grey pixel
# until the card scrolls into view, and the real photograph waits in
# data-a-hires (290px) or data-src (145px). Reading src alone gets a picture
# for the first screenful and a tracking pixel for the other 29 — which is
# invisible in the JSON, where both are strings ending in a plausible filename.
LAZY_PLACEHOLDER = re.compile(r"grey-pixel|transparent-pixel|1x1", re.I)

# Amazon's own "no image available" graphic is left alone: it is not a
# loading artifact, it is the answer.
IMAGE_ATTRS = ("data-a-hires", "data-src", "src")


def product_image(scope: Any, *selectors: str) -> str | None:
    for selector in selectors:
        for name in IMAGE_ATTRS:
            url = attr(scope, selector, name)
            if url and not LAZY_PLACEHOLDER.search(url):
                return url
    return None


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
        "image": product_image(card, "img.sns-product-image", "img"),
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
        "image": product_image(card, "img.sns-product-image", "img"),
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
        "date_label": text(card, DELIVERY_HEADER),
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


def scrape_subscriptions(
    page: Any, load_all: bool = False, with_prices: bool = True
) -> tuple[list[dict[str, Any]], int | None]:
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

    # Read the navigation state *before* leaving the list page; it is the only
    # place the deliveries-tab URL is published, and the join below navigates
    # away from it.
    nav = page_state(page, NAVIGATION_KEY) or {} if with_prices and rows else {}
    if with_prices and rows:
        join_delivery_facts(rows, _delivery_cards_or_warn(page, nav))

    sort_by_next_delivery(rows)
    return rows, (int(total) if isinstance(total, int) else None)


def _delivery_cards_or_warn(page: Any, nav: dict[str, Any]) -> list[dict[str, Any]]:
    """The deliveries view, or an empty list and a warning saying so.

    The prices are an enrichment of the subscription list, not the point of it.
    A deliveries page that fails should cost you the price column, not the
    schedules you asked for — but silently, it would cost you the price column
    and look exactly like an account with no upcoming deliveries.
    """
    try:
        return fetch_delivery_cards(page, nav)
    except Exception as e:  # noqa: BLE001
        emit(
            "log",
            level="warn",
            msg=f"could not read the deliveries view ({type(e).__name__}), so prices "
            "and discounts are missing below — the schedules are still real",
        )
        return []


def delivery_index(cards: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """subscription id -> facts from the *earliest* delivery containing it.

    A subscription recurs across several future deliveries, and only the
    earliest one is the answer to "what happens next". Cards arrive sorted, so
    first write wins.
    """
    index: dict[str, dict[str, Any]] = {}
    for card in cards:
        for item in card.get("items") or []:
            sub_id = item.get("subscription_id")
            if not sub_id or sub_id in index:
                continue
            index[sub_id] = {
                "next_delivery_date": card.get("date"),
                "price": item.get("price"),
                "price_raw": item.get("price_raw"),
                "discount": item.get("discount"),
            }
    return index


def join_delivery_facts(rows: list[dict[str, Any]], cards: list[dict[str, Any]]) -> None:
    """Attach price, discount, and a real date to each subscription, in place.

    `next_delivery_date` prefers the delivery card's timestamp over the label
    on the subscription card: the card says "September 30" and the delivery
    knows which September 30.
    """
    index = delivery_index(cards)
    for row in rows:
        facts = index.get(row["subscription_id"]) or {}
        row["price"] = facts.get("price")
        row["price_raw"] = facts.get("price_raw")
        row["discount"] = facts.get("discount")
        row["next_delivery_date"] = facts.get("next_delivery_date") or parse_label_date(
            row.get("next_delivery_label")
        )


def sort_by_next_delivery(rows: list[dict[str, Any]]) -> None:
    """Soonest first; undated last.

    Amazon's own order is neither date nor alphabetical — it interleaves
    September, March, and December — so preserving it preserves nothing. A row
    whose date could not be read sorts to the end rather than to 1970.
    """
    rows.sort(
        key=lambda r: (
            r.get("next_delivery_date") is None,
            r.get("next_delivery_date") or "",
            (r.get("title") or "").lower(),
        )
    )


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
    """The current delivery, then every future one Amazon has scheduled."""
    open_subscription_list(page)
    return fetch_delivery_cards(page, page_state(page, NAVIGATION_KEY) or {})


def fetch_delivery_cards(page: Any, nav: dict[str, Any]) -> list[dict[str, Any]]:
    """Follow the deliveries-tab URL out of `nav`, then the future one.

    Both arrive as HTML fragments from URLs the subscription list publishes in
    page state. Navigating straight to a fragment is unusual but it is what the
    tab does; the alternative is clicking through a React hub whose class names
    are content-hashed and change on deploy.

    Takes the state rather than reading it, because the caller may already have
    navigated away from the page that carries it.
    """
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


class NoSuchSubscription(Exception):
    """The id or search term matched nothing, or matched too much."""


def find_subscription_card(page: Any, wanted: str | None, query: str | None) -> Any:
    """The card for an id, or the single card whose title matches a query.

    Ids are 26 characters of Amazon's alphabet, which nobody types twice, so a
    query is the humane way in. Ambiguity raises rather than picking the first
    match: `show` is what you run before deciding what to cancel, and quietly
    showing a different subscription than the one you meant is the failure that
    survives longest.

    Pages through the list when the first page doesn't have it — the id may
    well have come from `list --all`.
    """
    open_subscription_list(page)
    card = _card_by_id(page, wanted) if wanted else None
    if card is None:
        load_all_pages(page)
        card = _card_by_id(page, wanted) if wanted else _card_by_query(page, query or "")
    if card is None:
        raise NoSuchSubscription(
            f"no active subscription matching {(wanted or query)!r}. "
            "`amazon subscribe list --all` shows every one you have."
        )
    return card


def _card_by_id(page: Any, sub_id: str) -> Any:
    try:
        nodes = page.locator(f"{SUBSCRIPTION_CARD}[data-subscription-id={json.dumps(sub_id)}]")
        return nodes.first if nodes.count() else None
    except Exception:  # noqa: BLE001
        return None


def _card_by_query(page: Any, query: str) -> Any:
    needle = query.strip().lower()
    if not needle:
        return None
    matches = [
        (card, title)
        for card in _cards(page, SUBSCRIPTION_CARD)
        for title in [text(card, *TITLE_SELECTORS) or ""]
        if needle in title.lower()
    ]
    if len(matches) > 1:
        # One per line: four product titles run together with semicolons is a
        # wall, and this message exists to be read and chosen from.
        listed = "".join(f"\n  - {t[:70]}" for _, t in matches[:6])
        more = "" if len(matches) <= 6 else f"\n  …and {len(matches) - 6} more"
        raise NoSuchSubscription(
            f"{len(matches)} subscriptions match {query!r}:{listed}{more}\n"
            "Narrow the search, or pass the subscription id."
        )
    return matches[0][0] if matches else None


class NotSkippable(RuntimeError):
    """The subscription exists but nothing about it can be skipped right now."""


def open_deliveries_tab(page: Any) -> None:
    """Load the deliveries view into a page whose JavaScript is running.

    Navigating to the tab's href does not work: that URL renders the React hub,
    which comes back with no delivery cards at all. Clicking the tab does, and
    the click is what a person would do.
    """
    open_subscription_list(page)
    tab = page.locator(DELIVERIES_TAB).first
    if not _clickable(tab):
        raise RuntimeError(
            "no deliveries tab on the subscriptions page — Amazon's layout has changed"
        )
    tab.click(timeout=CLICK_TIMEOUT_MS)
    try:
        page.wait_for_selector(DELIVERY_CARD, timeout=TAB_WAIT_MS)
    except Exception as e:  # noqa: BLE001
        raise RuntimeError(f"the deliveries tab never rendered a delivery: {e}") from e
    page.wait_for_timeout(PAGE_SETTLE_MS)


def current_delivery(page: Any) -> Any:
    """The delivery about to ship — the only one with anything to skip."""
    cards = page.locator(f"{DELIVERY_CARD}[data-delivery-type='current']")
    if cards.count() == 0:
        raise NotSkippable(
            "no delivery is currently scheduled, so there is nothing to skip"
        )
    return cards.first


def skippable_items(card: Any) -> list[tuple[Any, str]]:
    """(node, title) for each item in this delivery that offers a Skip button."""
    out = []
    for item in _cards(card, DELIVERY_SUBSCRIPTION_CARD):
        if item.locator(SKIP_BUTTON).count() > 0:
            out.append((item, text(item, *TITLE_SELECTORS) or ""))
    return out


def match_delivery_item(items: Sequence[tuple[Any, str]], wanted: str | None, query: str | None) -> Any:
    """Pick the one item the user meant, or refuse to guess.

    Same rule as `show`: an id is exact, a query has to be unambiguous. The
    stakes are higher here — `show` printing the wrong subscription wastes a
    glance, skipping the wrong one means a product does not arrive.
    """
    if wanted:
        for node, _title in items:
            if node.get_attribute("data-subscription-id") == wanted:
                return node
        raise NoSuchSubscription(
            f"{wanted} is not in the next delivery. `amazon subscribe upcoming` "
            "shows what is."
        )

    needle = (query or "").strip().lower()
    if not needle:
        raise NoSuchSubscription("skip needs a subscription id or a search")
    matches = [(node, title) for node, title in items if needle in title.lower()]
    if len(matches) > 1:
        listed = "".join(f"\n  - {t[:70]}" for _, t in matches[:6])
        raise NoSuchSubscription(
            f"{len(matches)} items in the next delivery match {query!r}:{listed}\n"
            "Narrow the search, or pass the subscription id."
        )
    if not matches:
        listed = "".join(f"\n  - {t[:70]}" for _, t in items[:8])
        raise NoSuchSubscription(
            f"nothing in the next delivery matches {query!r}. It holds:{listed}"
        )
    return matches[0][0]


def read_skip_modal(page: Any) -> dict[str, Any]:
    """What the confirmation dialog says, before anyone agrees to it.

    The warning line is the point. Amazon says "This will cancel your order.
    You may lose applied coupons." — which is not what "skip" sounds like, and
    is worth putting in front of someone before they say yes.
    """
    return {
        "heading": text(page, SKIP_TITLE),
        "product": text(page, f"{SKIP_MODAL} .product-title", f"{SKIP_MODAL} .a-size-medium"),
        "warning": text(page, SKIP_WARNING),
        # Not the token itself — only whether the form Amazon rendered is the
        # one we know how to submit.
        "has_csrf": page.locator(SKIP_CSRF).count() > 0,
    }


def skip_delivery_item(
    page: Any, wanted: str | None, query: str | None, confirm: bool
) -> dict[str, Any]:
    """Skip one item from the next delivery, or describe what that would do.

    The dry run is not a simulation — it opens Amazon's own confirmation dialog
    and reads it back. A hand-written summary of what skipping means would be a
    guess that ages badly; the dialog is what Amazon will actually do, in
    Amazon's words, including the part about losing coupons.
    """
    open_deliveries_tab(page)
    card = current_delivery(page)
    items = skippable_items(card)
    if not items:
        raise NotSkippable(
            "nothing in the next delivery can be skipped — it may already be "
            "too late to change it. `amazon subscribe upcoming` shows the "
            "last day to edit."
        )

    node = match_delivery_item(items, wanted, query)
    sub_id = node.get_attribute("data-subscription-id")
    title = text(node, *TITLE_SELECTORS)
    delivery_date = card.get_attribute("data-delivery-date")

    node.locator(SKIP_BUTTON).first.click(timeout=CLICK_TIMEOUT_MS)
    try:
        page.wait_for_selector(SKIP_MODAL, timeout=MODAL_WAIT_MS)
    except Exception as e:  # noqa: BLE001
        raise RuntimeError(f"the skip confirmation never appeared: {e}") from e

    result = {
        "subscription_id": sub_id,
        "title": title,
        "delivery_date": parse_epoch_date(delivery_date),
        "delivery_label": text(card, DELIVERY_HEADER),
        "confirmed": False,
        "verified": None,
        **read_skip_modal(page),
    }
    if not confirm:
        # Nothing has changed: the dialog is open and no one has agreed to it.
        # Closing the browser is the same as walking away from it.
        return result

    approve = page.locator(SKIP_APPROVE).first
    if not _clickable(approve):
        raise RuntimeError("the confirmation dialog has no approve button")
    approve.click(timeout=CLICK_TIMEOUT_MS)
    page.wait_for_timeout(PAGE_SETTLE_MS)
    result["confirmed"] = True
    result["verified"] = verify_skipped(page, sub_id)
    return result


def verify_skipped(page: Any, sub_id: str | None) -> bool | None:
    """Re-read the next delivery and check the item really left it.

    A click that returns without error is not evidence. Amazon can answer with
    a dialog that closes on failure just as readily as on success, and the only
    thing that settles it is the delivery no longer containing the item — which
    costs one more page load and is the difference between reporting what we
    did and reporting what we asked for.

    None, not False, when the check itself could not be made: "we could not
    confirm" and "it did not work" are different things to tell someone about
    a change to their account.
    """
    if not sub_id:
        return None
    try:
        open_deliveries_tab(page)
        card = current_delivery(page)
        still_there = card.locator(
            f"{DELIVERY_SUBSCRIPTION_CARD}[data-subscription-id={json.dumps(sub_id)}]"
        ).count()
        return still_there == 0
    except Exception:  # noqa: BLE001
        return None


def edit_modal_url(card: Any) -> str | None:
    """The modal URL the card publishes for itself, if it still does."""
    for node in _cards(card, "[data-a-modal]"):
        try:
            payload = json.loads(node.get_attribute("data-a-modal") or "{}")
        except (TypeError, ValueError):
            continue
        if payload.get("name") == EDIT_MODAL_NAME and payload.get("url"):
            return str(payload["url"])
    return None


def scrape_subscription_detail(page: Any) -> dict[str, Any]:
    """The edit modal: what neither list view carries.

    No price, deliberately — the modal has none. Its "$16.92" is lifetime
    savings on this subscription, which is a different number and a much more
    tempting one to mislabel as a price.

    No shipping address or payment method either. Both render here; neither is
    something this command needs to put on a terminal or into JSON.
    """
    merchant = text(page, *DETAIL_MERCHANT)
    backup = text(page, *DETAIL_BACKUP)
    next_label = text(page, *DETAIL_NEXT_DELIVERY)
    discount_now = text(page, *DETAIL_DISCOUNT_NOW)
    href = attr(page, 'a[href*="/dp/"]', "href") or ""
    asin = ASIN_RE.search(href)

    detail: dict[str, Any] = {
        "title": text(page, *DETAIL_TITLE),
        "asin": asin.group(1).upper() if asin else None,
        "image": product_image(page, ".productImage img", "img"),
        "merchant": SOLD_BY_RE.sub("", merchant) if merchant else None,
        "next_delivery_label": next_label,
        "next_delivery_date": parse_label_date(next_label),
        "next_delivery_prefix": text(page, *DETAIL_NEXT_DELIVERY_LABEL),
        "discount_now": discount_now,
        "discount_percent": _percent(discount_now),
        # Amazon shows "Select a backup" when there isn't one. Reporting that
        # string as the backup item's name would be a lie with a straight face.
        "backup_item": None if not backup or NO_BACKUP_RE.match(backup) else backup,
        "lifetime_savings": first_money(
            text(
                page,
                f"{DETAIL_SAVINGS_BOX} .a-price .a-offscreen",
                f"{DETAIL_SAVINGS_BOX} .a-price",
            )
        ),
        "lifetime_savings_text": text(page, DETAIL_SAVINGS_BOX),
        "tier_level": attr(page, "[data-tiered-level]", "data-tiered-level"),
        # Which actions Amazon is offering on this subscription. Read-only
        # today, but it is the difference between "you can cancel this" and
        # "this one is managed somewhere else", and it costs nothing to record.
        "actions": available_actions(page),
    }
    detail.update(parse_schedule(text(page, *DETAIL_SCHEDULE)))
    return detail


def _percent(raw: str | None) -> int | None:
    m = PERCENT_RE.search(raw or "")
    return int(m.group(1)) if m else None


def first_money(raw: str | None) -> float | None:
    """The first `$n` in a string, as a number. See MONEY_RE."""
    m = MONEY_RE.search(raw or "")
    return parse_money(m.group(0)) if m else None


def available_actions(page: Any) -> list[str]:
    """CANCEL, CHANGE_QUANTITY_FREQUENCY, … from the `t-action-type-*` classes."""
    found: set[str] = set()
    for node in _cards(page, "[class*='t-action-type-']"):
        try:
            classes = node.get_attribute("class") or ""
        except Exception:  # noqa: BLE001
            continue
        found.update(ACTION_TYPE_RE.findall(classes))
    return sorted(found)


def scrape_subscription(page: Any, sub_id: str | None, query: str | None) -> dict[str, Any]:
    card = find_subscription_card(page, sub_id, query)
    resolved = None
    try:
        resolved = card.get_attribute("data-subscription-id")
    except Exception:  # noqa: BLE001
        pass
    url = edit_modal_url(card)
    if not url:
        raise RuntimeError(
            "that subscription's card no longer publishes an edit-modal URL — "
            "Amazon's markup has changed shape"
        )
    # Fall back to the card's own fields for anything the modal doesn't render,
    # so a half-rotted modal degrades to the list view rather than to nulls.
    from_card = scrape_subscription_card(card) or {}

    page.goto(url, wait_until="domcontentloaded", timeout=45000)
    page.wait_for_timeout(1200)
    guard(page)

    detail = scrape_subscription_detail(page)
    merged = {k: (detail.get(k) if detail.get(k) is not None else v) for k, v in from_card.items()}
    merged.update({k: v for k, v in detail.items() if v is not None or k not in merged})
    merged["subscription_id"] = resolved or sub_id
    return merged


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
                    with_prices = req.get("prices") is not False
                    emit("log", level="info", msg="reading your subscriptions")
                    rows, total = scrape_subscriptions(
                        page, load_all=load_all, with_prices=with_prices
                    )
                    for row in rows:
                        emit("subscription", data=row)
                    emit("done", count=len(rows), total=total)

                elif action == "deliveries":
                    emit("log", level="info", msg="reading your scheduled deliveries")
                    cards = scrape_deliveries(page)
                    for card in cards:
                        emit("delivery", data=card)
                    emit("done", count=len(cards))

                elif action == "subscription":
                    sub_id = req.get("subscription_id")
                    query = req.get("query")
                    if not sub_id and not query:
                        emit("error", msg="subscription requires subscription_id or query")
                        return 2
                    emit("log", level="info", msg=f"looking up {sub_id or query}")
                    emit("detail", data=scrape_subscription(page, sub_id, query))
                    emit("done", count=1)

                elif action == "skip":
                    sub_id = req.get("subscription_id")
                    query = req.get("query")
                    if not sub_id and not query:
                        emit("error", msg="skip requires subscription_id or query")
                        return 2
                    confirm = bool(req.get("confirm"))
                    emit(
                        "log",
                        level="info",
                        msg=("skipping " if confirm else "checking what skipping ")
                        + f"{sub_id or query} would do",
                    )
                    emit("skip", data=skip_delivery_item(page, sub_id, query, confirm))
                    emit("done", count=1)

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
    except NotSkippable as e:
        # Not a failure of ours and not a user typo either — the account is
        # simply not in a state where this can happen.
        emit("error", msg=str(e), kind="not_skippable")
        return 2
    except NoSuchSubscription as e:
        # A search that matched nothing is a user error, not a scraper failure,
        # so it exits like one and skips the traceback.
        emit("error", msg=str(e), kind="not_found")
        return 2
    except Exception as e:  # noqa: BLE001
        print(traceback.format_exc(), file=sys.stderr)
        emit("error", msg=f"{type(e).__name__}: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
