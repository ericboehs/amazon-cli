"""
Live product worker: current price, availability, and delivery estimates.

Unlike fetch.py (which drives `amazon-orders` against your order history),
this scrapes live product pages through Playwright using the session saved by
`amazon login`. Being signed in matters: delivery promises are personalized to
your default shipping address.

Protocol (NDJSON over stdout):
    {"event":"log","level":"info","msg":"..."}
    {"event":"item","data":{...}}
    {"event":"result","data":{...}}      # one per search hit
    {"event":"done","count":N}
    {"event":"error","msg":"...","kind":"not_logged_in"|"blocked"|null}

Stdin (one-shot request):
    {"action":"item","asin":"B0747R1M51"}
    {"action":"search","query":"pla filament","limit":10}
"""

from __future__ import annotations

import json
import re
import sys
import traceback
from datetime import date, datetime
from typing import Any
from urllib.parse import quote_plus

from browser import (
    Blocked,
    NotLoggedIn,
    attr,
    emit,
    guard,
    launch,
    new_context,
    parse_money,
    text,
)

# The URL path is authoritative. Matching a bare token anywhere in the input
# lets a slug word shadow the real ASIN (".../Bluetooth5-Speaker/dp/B0CH7T8QTR"
# would yield BLUETOOTH5), and lets the ISBN form match a 10-digit "qid=" epoch
# on a search URL that has no ASIN at all.
ASIN_PATH_RE = re.compile(r"/(?:dp|gp/product|product)/([A-Z0-9]{10})(?:[/?#]|$)", re.IGNORECASE)
# Only accepted when it is the entire input, i.e. typed on the command line.
ASIN_BARE_RE = re.compile(r"^(B[0-9A-Z]{9}|\d{9}[\dX])$")

# "4.6 out of 5 stars, 4,640 ratings" — the leading number is the rating, so the
# count has to be anchored on its trailing noun rather than taken as the first
# integer in the string.
REVIEW_COUNT_RE = re.compile(r"([\d,]*\d)\s*(?:ratings?|reviews?)", re.IGNORECASE)
RATING_PHRASE_RE = re.compile(r"out of\s+\d+(?:\.\d+)?\s+stars", re.IGNORECASE)

# "FREE delivery Tuesday, July 28" / "Tomorrow, Jul 27" / "Tue, Jul 28"
DATE_RE = re.compile(
    r"(?:(?P<dow>Mon|Tues?|Wed(?:nes)?|Thur?s?|Fri|Satur?|Sun)(?:day)?,?\s+)?"
    r"(?P<month>Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+(?P<day>\d{1,2})",
    re.IGNORECASE,
)
MONTHS = {m: i for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], 1
)}


def extract_asin(raw: str) -> str | None:
    """Accept a bare ASIN, a /dp/ URL, or a /gp/product/ URL.

    Returns None rather than guessing when the input has neither shape — a URL
    with no product path (a search page, a share link) has no ASIN to find.
    """
    if not raw:
        return None
    raw = raw.strip()
    m = ASIN_PATH_RE.search(raw)
    if m:
        return m.group(1).upper()
    m = ASIN_BARE_RE.match(raw.upper())
    return m.group(1) if m else None


def parse_delivery_date(raw: str | None, today: date | None = None) -> str | None:
    """Pull the first date out of a delivery blurb -> ISO 'YYYY-MM-DD'.

    Amazon omits the year, so infer it: a month more than one behind today has
    rolled into next year.
    """
    if not raw:
        return None
    today = today or date.today()
    m = DATE_RE.search(raw)
    if not m:
        if "tomorrow" in raw.lower():
            return date.fromordinal(today.toordinal() + 1).isoformat()
        if "today" in raw.lower():
            return today.isoformat()
        return None
    month = MONTHS[m.group("month")[:3].lower()]
    day = int(m.group("day"))
    year = today.year
    if month < today.month - 1:
        year += 1
    try:
        return date(year, month, day).isoformat()
    except ValueError:
        return None


def scrape_item(page: Any, asin: str) -> dict[str, Any]:
    page.goto(f"https://www.amazon.com/dp/{asin}", wait_until="domcontentloaded", timeout=45000)
    page.wait_for_timeout(1500)
    guard(page)

    title = text(page, "#productTitle", "#title", "h1#title span")
    if not title:
        raise RuntimeError(f"no product found for {asin} (page may be a 404 or a redirect)")

    price_raw = text(
        page,
        "#corePriceDisplay_desktop_feature_div .a-price .a-offscreen",
        "#corePrice_feature_div .a-price .a-offscreen",
        "#priceblock_ourprice",
        "#priceblock_dealprice",
        ".a-price .a-offscreen",
    )
    list_raw = text(
        page,
        "#corePriceDisplay_desktop_feature_div .basisPrice .a-offscreen",
        ".a-text-price .a-offscreen",
    )
    delivery_raw = text(
        page,
        "#deliveryBlockMessage",
        "#mir-layout-DELIVERY_BLOCK",
        "#delivery-block-message",
        "[data-csa-c-delivery-time]",
    )
    fastest_raw = text(
        page,
        "#fastest-desktop-delivery-message",
        "#mir-layout-DELIVERY_BLOCK-slot-PRIMARY_DELIVERY_MESSAGE_LARGE",
    )
    rating_raw = text(page, "#acrPopover", "[data-hook=rating-out-of-text]")
    reviews_raw = text(page, "#acrCustomerReviewText")

    price = parse_money(price_raw)
    list_price = parse_money(list_raw)

    data = {
        "asin": asin,
        "url": f"https://www.amazon.com/dp/{asin}",
        "title": title,
        "price": price,
        "price_raw": price_raw,
        "list_price": list_price if list_price and price and list_price > price else None,
        "availability": text(page, "#availability", "#outOfStock", "#availability_feature_div"),
        "delivery_raw": delivery_raw,
        "delivery_date": parse_delivery_date(delivery_raw or fastest_raw),
        "fastest_raw": fastest_raw,
        "seller": text(page, "#sellerProfileTriggerId", "#merchant-info", "#tabular-buybox"),
        "rating": _first_float(rating_raw),
        "reviews": _review_count(reviews_raw),
        "coupon": text(page, "#promoPriceBlockMessage_feature_div", "#couponFeature"),
        "image": attr(page, "#landingImage, #imgBlkFront, #main-image", "src"),
        "_fetched_at": datetime.now().astimezone().isoformat(timespec="seconds"),
    }
    _warn_selector_rot(data)
    return data


def scrape_search(page: Any, query: str, limit: int) -> list[dict[str, Any]]:
    page.goto(
        f"https://www.amazon.com/s?k={quote_plus(query)}",
        wait_until="domcontentloaded",
        timeout=45000,
    )
    page.wait_for_timeout(1500)
    guard(page)

    cards = page.locator('[data-component-type="s-search-result"]')
    total = cards.count()
    out: list[dict[str, Any]] = []
    for i in range(total):
        if len(out) >= limit:
            break
        card = cards.nth(i)
        asin = card.get_attribute("data-asin")
        if not asin:
            continue
        title = text(card, "h2 span", "h2 a span", "h2")
        if not title:
            continue
        price_raw = text(card, ".a-price .a-offscreen")
        delivery_raw = text(card, "[data-cy=delivery-recipe]", ".udm-primary-delivery-message")
        rating_raw = text(card, "[data-cy=reviews-ratings-slot]", ".a-icon-alt")
        out.append(
            {
                "asin": asin,
                "url": f"https://www.amazon.com/dp/{asin}",
                "title": title,
                "price": parse_money(price_raw),
                "price_raw": price_raw,
                "rating": _first_float(rating_raw),
                # The visible text is rounded ("(4.6K)"); the aria-label has the
                # exact count ("4.6 out of 5 stars, 4,640 ratings").
                "reviews": _review_count(
                    attr(card, "a[aria-label*='ratings']", "aria-label")
                    or text(card, "[data-csa-c-slot-id=alf-reviews] span")
                ),
                "sponsored": _is_sponsored(card),
                "delivery_raw": delivery_raw,
                "delivery_date": parse_delivery_date(delivery_raw),
                "image": attr(card, "img.s-image", "src"),
            }
        )
    return out


def _is_sponsored(card: Any) -> bool | None:
    """None means "couldn't tell" — callers must not read that as "organic"."""
    try:
        return card.locator("span:has-text('Sponsored')").count() > 0
    except Exception:  # noqa: BLE001
        return None


def _first_float(raw: str | None) -> float | None:
    if not raw:
        return None
    m = re.search(r"\d+(?:\.\d+)?", raw)
    return float(m.group(0)) if m else None


def _first_int(raw: str | None) -> int | None:
    if not raw:
        return None
    m = re.search(r"\d[\d,]*", raw)
    return int(m.group(0).replace(",", "")) if m else None


def _review_count(raw: str | None) -> int | None:
    """Review count from an aria-label or a bare "(391)" span."""
    if not raw:
        return None
    m = REVIEW_COUNT_RE.search(raw)
    if m:
        return int(m.group(1).replace(",", ""))
    # A bare rating with no count attached: report no count rather than the
    # rating's leading digit.
    if RATING_PHRASE_RE.search(raw):
        return None
    return _first_int(raw)


# Fields a normal product page always renders. Several empty at once means a
# selector chain has rotted, not that Amazon left them out — worth saying so,
# since each field degrades to null independently and the output still looks
# complete.
EXPECTED_ITEM_FIELDS = ("price", "availability", "delivery_raw", "seller", "rating", "image")
ROT_THRESHOLD = 3


def _warn_selector_rot(data: dict[str, Any]) -> None:
    missing = [f for f in EXPECTED_ITEM_FIELDS if not data.get(f)]
    if len(missing) >= ROT_THRESHOLD:
        emit(
            "log",
            level="warn",
            msg=(
                f"{len(missing)}/{len(EXPECTED_ITEM_FIELDS)} expected fields were empty "
                f"({', '.join(missing)}) — Amazon's markup may have changed"
            ),
        )


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

                if action == "item":
                    asin = extract_asin(str(req.get("asin") or ""))
                    if not asin:
                        emit("error", msg=f"could not parse an ASIN from {req.get('asin')!r}")
                        return 2
                    emit("log", level="info", msg=f"fetching {asin}")
                    emit("item", data=scrape_item(page, asin))
                    emit("done", count=1)

                elif action == "search":
                    query = str(req.get("query") or "").strip()
                    limit = int(req.get("limit") or 10)
                    if not query:
                        emit("error", msg="search requires a query")
                        return 2
                    emit("log", level="info", msg=f"searching {query!r}")
                    results = scrape_search(page, query, limit)
                    for r in results:
                        emit("result", data=r)
                    emit("done", count=len(results))

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
