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
    {"action":"item","asin":"B0747R1M51","reviews":true,"review_pages":2}
    {"action":"search","query":"pla filament","limit":10}

Reviews ride along on the `item` action rather than getting their own: the
product page already carries the rating histogram and the top ~8 reviews, so
folding them in costs no extra page load. `review_pages` > 0 additionally walks
/product-reviews/ for depth.
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

MONTH_ALT = "Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec"
# "Reviewed in the United States on July 26, 2025"
REVIEW_DATE_RE = re.compile(
    rf"(?P<month>{MONTH_ALT})[a-z]*\s+(?P<day>\d{{1,2}}),?\s+(?P<year>\d{{4}})", re.IGNORECASE
)
# Non-US locales invert it: "Reviewed in Canada on 26 July 2025".
REVIEW_DATE_INTL_RE = re.compile(
    rf"(?P<day>\d{{1,2}})\s+(?P<month>{MONTH_ALT})[a-z]*\s+(?P<year>\d{{4}})", re.IGNORECASE
)
# "Reviewed in the United States on ..." -> "the United States"
REVIEW_COUNTRY_RE = re.compile(r"reviewed in\s+(.+?)\s+on\b", re.IGNORECASE)

# "12 people found this helpful" / "One person found this helpful"
HELPFUL_RE = re.compile(r"([\d,]*\d)\s+(?:person|people)\s+found", re.IGNORECASE)
HELPFUL_ONE_RE = re.compile(r"\bone person found\b", re.IGNORECASE)

# The histogram renders as an aria-label in either order ("5 stars represent
# 71% of rating", "71 percent of reviews have 5 stars") or as a bare row
# ("5 star  71%"). The share is spelled "%" or "percent" depending on the
# layout. All of these reduce to the same (stars, percent) pair.
PCT = r"(?P<pct>\d{1,3})\s*(?:%|percent\b)"
HISTOGRAM_RE = re.compile(rf"(?P<stars>[1-5])\s*stars?\b.*?{PCT}", re.IGNORECASE | re.DOTALL)
HISTOGRAM_PCT_FIRST_RE = re.compile(rf"{PCT}.*?(?P<stars>[1-5])\s*stars?\b", re.IGNORECASE | re.DOTALL)

# The review-title hook's text often leads with the star rating on its own line
# ("5.0 out of 5 stars\nWorks great"). That prefix is the rating, not the title.
STAR_PREFIX_RE = re.compile(r"^\s*\d+(?:\.\d+)?\s+out of\s+\d+(?:\.\d+)?\s+stars\s*", re.IGNORECASE)

SORT_KEYS = {"helpful": "helpful", "recent": "recent"}


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


def parse_review_date(raw: str | None) -> str | None:
    """"Reviewed in the United States on July 26, 2025" -> "2025-07-26".

    Unlike delivery blurbs, review datelines carry a real year, so nothing has
    to be inferred. Both the US ("July 26, 2025") and international
    ("26 July 2025") orderings appear, and a day-first string must not be read
    as month-first.
    """
    if not raw:
        return None
    m = REVIEW_DATE_RE.search(raw) or REVIEW_DATE_INTL_RE.search(raw)
    if not m:
        return None
    try:
        return date(
            int(m.group("year")), MONTHS[m.group("month")[:3].lower()], int(m.group("day"))
        ).isoformat()
    except ValueError:
        return None


def parse_review_country(raw: str | None) -> str | None:
    if not raw:
        return None
    m = REVIEW_COUNTRY_RE.search(raw)
    if not m:
        return None
    country = re.sub(r"^the\s+", "", m.group(1).strip(), flags=re.IGNORECASE)
    return country or None


def parse_helpful_votes(raw: str | None) -> int | None:
    """Vote count from the helpfulness line. None means "no votes shown"."""
    if not raw:
        return None
    m = HELPFUL_RE.search(raw)
    if m:
        return int(m.group(1).replace(",", ""))
    return 1 if HELPFUL_ONE_RE.search(raw) else None


def strip_star_prefix(raw: str | None) -> str | None:
    if not raw:
        return None
    cleaned = STAR_PREFIX_RE.sub("", raw).strip()
    return cleaned or None


def parse_histogram_label(raw: str | None) -> tuple[int, int] | None:
    """"5 stars represent 71% of rating" -> (5, 71). None when unparseable."""
    if not raw:
        return None
    m = HISTOGRAM_RE.search(raw) or HISTOGRAM_PCT_FIRST_RE.search(raw)
    if not m:
        return None
    pct = int(m.group("pct"))
    # A percentage over 100 means the two numbers were matched out of a string
    # that isn't a histogram row at all.
    return (int(m.group("stars")), pct) if pct <= 100 else None


def reviews_url(asin: str, page_number: int = 1, sort: str = "helpful") -> str:
    return (
        f"https://www.amazon.com/product-reviews/{asin}"
        f"?pageNumber={page_number}&sortBy={SORT_KEYS.get(sort, 'helpful')}"
        "&reviewerType=all_reviews"
    )


STAR_ROWS = 5


def scrape_histogram(page: Any) -> dict[str, int]:
    """Star -> percent of all ratings, e.g. {"5": 71, "4": 12, ...}.

    Percentages are what Amazon publishes; absolute per-star counts are not on
    the page. Returns {} when the table can't be found, which callers must treat
    as "unknown" rather than "no ratings".

    A star distribution is five rows or it is not a distribution, so a selector
    yielding fewer is treated as a partial read and the remaining selectors
    still get their turn. Stopping at the first non-empty result let one
    surviving row pass for the whole table, and downstream every star that
    never arrived scored as 0% — turning routine selector drift into a
    five-star wall with no middle and no tail, which is precisely the shape the
    fraud model treats as damning.
    """
    out: dict[str, int] = {}
    for selector in (
        "#histogramTable a[aria-label]",
        "#cm_cr_dp_d_rating_histogram a[aria-label]",
        "[data-hook=cr-histogram-row] a[aria-label]",
    ):
        try:
            rows = page.locator(selector)
            for i in range(rows.count()):
                parsed = parse_histogram_label(rows.nth(i).get_attribute("aria-label"))
                if parsed:
                    out.setdefault(str(parsed[0]), parsed[1])
        except Exception:  # noqa: BLE001
            continue
        if len(out) == STAR_ROWS:
            return out

    # Fallback: no aria-labels, so read the rendered row text ("5 star  71%").
    try:
        rows = page.locator("#histogramTable .a-histogram-row, .a-histogram-row")
        for i in range(rows.count()):
            parsed = parse_histogram_label(" ".join(rows.nth(i).inner_text().split()))
            if parsed:
                out.setdefault(str(parsed[0]), parsed[1])
    except Exception:  # noqa: BLE001
        pass

    # Nothing at all is a listing with no histogram, which is ordinary. Some of
    # it is markup we no longer understand, and that is worth saying: the rows
    # we did read still get shown, but nothing will be scored off them.
    if out and len(out) < STAR_ROWS:
        emit("log", level="warn", msg=(
            f"read only {len(out)} of {STAR_ROWS} star rows from the rating histogram — "
            "reporting the rows found and skipping the distribution check"
        ))
    return out


def scrape_review_cards(scope: Any) -> list[dict[str, Any]]:
    """Every [data-hook=review] card under `scope`, in page order."""
    out: list[dict[str, Any]] = []
    try:
        cards = scope.locator("[data-hook=review], [data-hook=cmps-review]")
        total = cards.count()
    except Exception:  # noqa: BLE001
        return out

    for i in range(total):
        card = cards.nth(i)
        try:
            dateline = text(card, "[data-hook=review-date]")
            # reviewRichContentContainer holds just the prose; reviewText wraps
            # it in a card deck that also carries "double tap to read full
            # content" teaser copy. That copy is display:none, so inner_text
            # drops it, but preferring the inner hook keeps us off that ledge.
            body = text(
                card,
                "[data-hook=reviewRichContentContainer]",
                "[data-hook=reviewText]",
                "[data-hook=review-body]",
                ".review-text-content",
            )
            # The Vine badge marks a review Amazon itself incentivized with a
            # free product. That is disclosed and legitimate, so it is reported
            # separately rather than folded into the paid-review signals.
            vine = _has(card, "[data-hook=review-vine-badge]", ".vine-review-badge")
            record = {
                    "id": _review_id(card),
                    "title": strip_star_prefix(
                        text(
                            card,
                            "[data-hook=reviewTitle]",
                            "[data-hook=review-title] span:last-child",
                            "[data-hook=review-title]",
                        )
                    ),
                    "rating": _first_float(
                        text(card, "[data-hook=review-star-rating]", "[data-hook=cmps-review-star-rating]", ".a-icon-alt")
                    ),
                    "date": parse_review_date(dateline),
                    "country": parse_review_country(dateline),
                    "verified": _has(card, "[data-hook=avp-badge]"),
                    "vine": vine,
                    "author": text(card, ".a-profile-name"),
                    "variant": text(card, "[data-hook=format-strip]"),
                    "helpful_votes": parse_helpful_votes(text(card, "[data-hook=helpful-vote-statement]")),
                    "body": body,
            }
            # `text()` reports a detached or unrecognized card as all-None
            # rather than raising, so an empty record is indistinguishable from
            # a real review with nothing filled in. Dropping it matters: the
            # scoring downstream would otherwise count the phantom as an
            # unverified review and inflate the manipulation score.
            if not any((record["title"], record["body"], record["rating"], record["date"])):
                continue
            out.append(record)
        except Exception:  # noqa: BLE001
            # One malformed card must not cost us the rest of the page.
            continue
    return out


def scrape_reviews(
    page: Any, asin: str, pages: int = 0, sort: str = "helpful"
) -> tuple[list[dict[str, Any]], str]:
    """Reviews already on the loaded product page, plus `pages` more from
    /product-reviews/.

    Assumes `page` is sitting on the product page. Deduplicates by review id
    because the product page's top reviews reappear on the full listing.

    Returns the reviews and how the walk ended, one of:

      "complete"  — every page asked for was read
      "exhausted" — Amazon stopped serving new reviews before that
      "failed"    — a page load fell over, so depth is unknown

    Three states, not the boolean this used to be. "Didn't finish" was doing
    double duty for "there is no more" and "we couldn't get at it", and the
    report turned that into advice: a crashed pagination leg told the user
    "Amazon served no more for this session" — a confident statement about the
    listing, made out of our own network error, and one that talks them out of
    the retry that would have worked.
    """
    seen: set[str] = set()

    def fresh(cards: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """Cards not already collected, `seen` updated as it goes.

        Running rather than a set comprehension so that one page rendering the
        same review twice is caught the same way a repeated page is.
        """
        out = []
        for r in cards:
            key = dedupe_key(r)
            if key not in seen:
                seen.add(key)
                out.append(r)
        return out

    collected = fresh(scrape_review_cards(page))
    walk = "complete"

    for n in range(1, max(pages, 0) + 1):
        try:
            page.goto(reviews_url(asin, n, sort), wait_until="domcontentloaded", timeout=45000)
            page.wait_for_timeout(1200)
            guard(page)
        except (Blocked, NotLoggedIn):
            # Not a depth problem — the session itself is gone, or Amazon is
            # serving a robot check. Both subclass RuntimeError, so the handler
            # below used to swallow them and hand back a complete-looking fraud
            # report built on the ~8 product-page reviews, exit 0, with the one
            # actionable message ("Run: amazon login") never reaching the user.
            # guard() fails closed on purpose; catching it here undid that.
            raise
        except Exception as exc:  # noqa: BLE001
            # /product-reviews/ demands a signed-in session even when /dp/ will
            # still render for a stale one, so this leg fails on its own. The
            # sample from the product page is already in hand and is exactly
            # what `--pages 0` would have returned — reporting on it beats
            # discarding a good partial answer over the depth we couldn't get.
            emit("log", level="warn", msg=f"could not load review page {n} ({exc}) — reporting on {len(collected)} from the product page")
            walk = "failed"
            break
        batch = fresh(scrape_review_cards(page))
        if not batch:
            # Amazon serves the same page over again rather than 404ing past the
            # end, so duplicates are the only "no more" signal there is. It does
            # the same thing when it simply won't paginate for this session, and
            # the two are indistinguishable from here — which is why stopping on
            # page 1 of a product with thousands of ratings is worth saying out
            # loud rather than logging as routine.
            walk = "exhausted"
            if n < pages:
                emit("log", level="warn", msg=(
                    f"Amazon served no new reviews past page {n} of the {pages} requested — "
                    f"analyzing the {len(collected)} it did give up. Either it caps this "
                    "listing, or it won't paginate reviews for this session."
                ))
            else:
                emit("log", level="info", msg=f"no new reviews on page {n} — stopping")
            break
        collected.extend(batch)
        emit("log", level="info", msg=f"review page {n}: +{len(batch)} ({len(collected)} total)")

    return collected, walk


# Enough of the body to tell two reviews apart without tripping over the
# "Read more" truncation that the listing applies to long reviews and the
# product page does not.
DEDUPE_BODY_CHARS = 120


def dedupe_key(review: dict[str, Any]) -> str:
    """What makes this review the same review as one we already have.

    The id when Amazon gives us one, and the content when it doesn't. There has
    to be a fallback: keeping every id-less card unconditionally meant the same
    review came back once per requested page, because Amazon serves the page
    over again past the end of the listing rather than 404ing. The sample
    inflated, the "nothing new" end-of-walk signal never fired, and the
    duplicate-wording check — which reads shared phrasing as bought reviews —
    was handed a listing's own reviews repeated verbatim. One renamed `id`
    attribute would have been enough to manufacture that.

    Deliberately over-specified. A re-served card matches on every field, so
    extra fields cost nothing there, while each one makes it less likely that
    two people who genuinely bought the same thing collapse into one.
    """
    if review["id"]:
        return f"id:{review['id']}"
    body = " ".join((review["body"] or "").split())[:DEDUPE_BODY_CHARS]
    parts = (review["author"], review["date"], review["title"], body)
    return "content:" + "\x1f".join(p or "" for p in parts)


def _review_id(card: Any) -> str | None:
    try:
        raw = card.get_attribute("id") or ""
    except Exception:  # noqa: BLE001
        return None
    # On the product page the container id is prefixed ("customer_review-R1A2B3").
    return raw.split("-")[-1] if raw else None


def _has(scope: Any, *selectors: str) -> bool | None:
    """True / False / None, where None means "couldn't tell".

    Same contract as _is_sponsored, and for the same reason: this feeds the
    verified-purchase check, the heaviest signal in the trust model, where a
    missing badge is read as evidence of a review farm. Returning False for a
    probe that never completed made a detached card look like an accusation.
    """
    probed = 0
    for sel in selectors:
        try:
            found = scope.locator(sel).count() > 0
        except Exception:  # noqa: BLE001
            continue
        probed += 1
        if found:
            return True
    return False if probed else None


def scrape_item(
    page: Any, asin: str, reviews: bool = False, review_pages: int = 0, sort: str = "helpful"
) -> dict[str, Any]:
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

    if reviews:
        # Must come last: walking to /product-reviews/ navigates away from the
        # product page, so every field above has to be read off it first.
        # Not "reviews" — that key is already the sitewide rating *count* that
        # `item` and `search` render.
        data["histogram"] = scrape_histogram(page)
        sample, walk = scrape_reviews(page, asin, pages=review_pages, sort=sort)
        data["reviews_sample"] = sample
        # Lets the report distinguish "your sample is thin, go deeper" from
        # "this is everything Amazon will hand over" from "we fell over, try
        # again" — three different pieces of advice, and only one of them is
        # advice the user has already taken.
        data["reviews_walk"] = walk
        # How deep this sample actually went, so the report can suggest a number
        # larger than the one already run instead of parroting `--pages 3` back
        # at someone who just used it.
        data["review_pages"] = review_pages
        # The timing check cannot mean anything on a sample Amazon ordered by
        # date for us, so it has to know how the sample was chosen.
        data["reviews_sort"] = sort
        if not sample:
            emit("log", level="warn", msg=f"no reviews found for {asin}")

    # Last, so it sees the finished payload. Omitted when whole, to keep the
    # key's absence meaning "nothing to report" rather than padding every
    # --json result with an empty list.
    degraded = degradations(data)
    if degraded:
        data["_degraded"] = degraded

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


def _selector_rot_warning(data: dict[str, Any]) -> str | None:
    missing = [f for f in EXPECTED_ITEM_FIELDS if not data.get(f)]
    if len(missing) < ROT_THRESHOLD:
        return None
    return (
        f"{len(missing)}/{len(EXPECTED_ITEM_FIELDS)} expected fields were empty "
        f"({', '.join(missing)}) — Amazon's markup may have changed"
    )


def _warn_selector_rot(data: dict[str, Any]) -> None:
    msg = _selector_rot_warning(data)
    if msg:
        emit("log", level="warn", msg=msg)


def degradations(data: dict[str, Any]) -> list[str]:
    """Ways this scrape came back less than whole, recorded on the payload.

    Every one of these is already announced live while the scrape runs — and
    then the result is written to the cache for the TTL. Every run after that
    renders the same partial data with none of the warnings that came with it,
    so the run that looks clean is the run where the user has no way of knowing
    it isn't. Reading them back off the payload is what closes that.

    Derived from the finished payload rather than accumulated as we go, so it
    cannot disagree with what was actually returned. The selector-rot line is
    the same string that was emitted, from the same function, so the live
    warning and the replayed one can't drift apart.
    """
    out = []
    rot = _selector_rot_warning(data)
    if rot:
        out.append(rot)
    # A table we only half-read, which is not the same as a listing with no
    # ratings — plenty of those exist, and calling them degraded cries wolf.
    histogram = data.get("histogram")
    if histogram and len(histogram) < STAR_ROWS:
        out.append(
            f"read only {len(histogram)} of {STAR_ROWS} star rows from the rating histogram"
        )
    # `in` rather than truthiness: `amazon item` without --reviews has no
    # sample by design, and that is not a scrape that came back short.
    if "reviews_sample" in data and not data["reviews_sample"]:
        out.append("no reviews were found for this listing")
    return out


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
                    want_reviews = bool(req.get("reviews"))
                    review_pages = int(req.get("review_pages") or 0)
                    emit("log", level="info", msg=f"fetching {asin}")
                    emit(
                        "item",
                        data=scrape_item(
                            page,
                            asin,
                            reviews=want_reviews,
                            review_pages=review_pages,
                            sort=str(req.get("sort") or "helpful"),
                        ),
                    )
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
