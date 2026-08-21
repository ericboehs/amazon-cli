"""Unit tests for the pure parsing helpers in live.py / browser.py.

Run with: python -m unittest discover -s pyworker
No Playwright needed — these functions never touch a browser.
"""

import io
import json
import unittest
from contextlib import redirect_stdout
from datetime import date
from pathlib import Path

import browser
from browser import (
    Blocked,
    NoProduct,
    NotLoggedIn,
    clean_text,
    guard,
    is_signin_page,
    parse_money,
    session_rejected,
    text,
)
from live import (
    REVIEW_CARDS,
    SELLER_SELECTORS,
    SHOW_MORE_BUTTON,
    expand_reviews,
    extract_asin,
    normalize_seller,
    parse_delivery_date,
    parse_helpful_votes,
    parse_histogram_label,
    parse_review_country,
    parse_review_date,
    reviews_url,
    scrape_histogram,
    scrape_item,
    scrape_review_cards,
    scrape_reviews,
    strip_star_prefix,
    _first_float,
    _first_int,
    _has,
    _is_sponsored,
    _review_count,
    _review_id,
    _warn_selector_rot,
    _warn_tabular_seller,
    degradations,
)


class FakeLocator:
    def __init__(self, count, raises=False):
        self._count = count
        self._raises = raises

    def count(self):
        if self._raises:
            raise RuntimeError("execution context was destroyed")
        return self._count


class FakePage:
    """Minimal stand-in for a Playwright page: selector -> match count.

    `raises` lists selectors whose probe blows up, which is how a navigating
    page behaves mid-flight.
    """

    def __init__(self, url="https://www.amazon.com/dp/B1", matches=None, raises=()):
        self.url = url
        self._matches = matches or {}
        self._raises = set(raises)

    def locator(self, sel):
        return FakeLocator(self._matches.get(sel, 0), raises=sel in self._raises)


def emitted(fn):
    """Run fn, returning the NDJSON events it wrote to stdout."""
    buf = io.StringIO()
    with redirect_stdout(buf):
        fn()
    return [json.loads(line) for line in buf.getvalue().splitlines() if line.strip()]


class ExtractAsinTest(unittest.TestCase):
    def test_bare_asin(self):
        self.assertEqual(extract_asin("B0747R1M51"), "B0747R1M51")

    def test_lowercase_is_normalized(self):
        self.assertEqual(extract_asin("b0747r1m51"), "B0747R1M51")

    def test_dp_url_with_query(self):
        self.assertEqual(
            extract_asin("https://www.amazon.com/dp/B0747R1M51?ref_=ppx_hzod_title"),
            "B0747R1M51",
        )

    def test_gp_product_url(self):
        self.assertEqual(
            extract_asin("https://www.amazon.com/gp/product/B002QAVQ2S"), "B002QAVQ2S"
        )

    def test_long_slug_url(self):
        self.assertEqual(
            extract_asin("https://www.amazon.com/Some-Product-Name/dp/B0CH7T8QTR/ref=sr_1_3"),
            "B0CH7T8QTR",
        )

    def test_isbn_style_asin(self):
        self.assertEqual(extract_asin("https://www.amazon.com/dp/0306406152"), "0306406152")

    def test_no_asin(self):
        self.assertIsNone(extract_asin("https://www.amazon.com/s?k=filament"))
        self.assertIsNone(extract_asin(""))
        self.assertIsNone(extract_asin(None))

    # Regressions: a bare-ASIN match must never win over the /dp/ path, or a
    # slug word that happens to look like an ASIN gets returned as the product.
    def test_slug_word_does_not_beat_the_dp_path(self):
        self.assertEqual(
            extract_asin("https://www.amazon.com/BLUETOOTH5-Speaker/dp/B0CH7T8QTR"),
            "B0CH7T8QTR",
        )

    def test_trailing_slash_and_fragment(self):
        self.assertEqual(extract_asin("https://www.amazon.com/dp/B0747R1M51/"), "B0747R1M51")
        self.assertEqual(extract_asin("https://www.amazon.com/dp/B0747R1M51#reviews"), "B0747R1M51")

    def test_ten_digit_query_param_is_not_an_asin(self):
        # A unix timestamp in qid= is 10 chars of [A-Z0-9] but not an ASIN.
        self.assertIsNone(extract_asin("https://www.amazon.com/s?k=x&qid=1753574400"))

    def test_surrounding_whitespace(self):
        self.assertEqual(extract_asin("  B0747R1M51\n"), "B0747R1M51")


class ParseDeliveryDateTest(unittest.TestCase):
    TODAY = date(2026, 7, 26)

    def parse(self, raw):
        return parse_delivery_date(raw, today=self.TODAY)

    def test_full_weekday_and_month(self):
        self.assertEqual(self.parse("FREE delivery Tuesday, July 28"), "2026-07-28")

    def test_abbreviated(self):
        self.assertEqual(self.parse("Two-Day FREE delivery Tue, Jul 28"), "2026-07-28")

    def test_tomorrow_keyword(self):
        self.assertEqual(self.parse("FREE delivery Tomorrow"), "2026-07-27")

    def test_today_keyword(self):
        self.assertEqual(self.parse("Get it Today"), "2026-07-26")

    def test_explicit_date_wins_over_tomorrow_keyword(self):
        # Amazon writes "Tomorrow, Jul 27" — the explicit date is authoritative.
        self.assertEqual(self.parse("FREE delivery Tomorrow, Jul 27"), "2026-07-27")

    def test_month_rollover_into_next_year(self):
        # In late December, a January date belongs to next year.
        self.assertEqual(
            parse_delivery_date("FREE delivery Jan 3", today=date(2026, 12, 28)),
            "2027-01-03",
        )

    def test_recent_past_month_stays_this_year(self):
        # One month behind is treated as the same year, not a rollover.
        self.assertEqual(
            parse_delivery_date("delivery Dec 30", today=date(2026, 12, 31)),
            "2026-12-30",
        )

    def test_invalid_day_returns_none(self):
        self.assertIsNone(self.parse("delivery Feb 31"))

    def test_unparseable(self):
        self.assertIsNone(self.parse("Usually ships within 2 to 3 months"))
        self.assertIsNone(self.parse(None))
        self.assertIsNone(self.parse(""))


class ParseMoneyTest(unittest.TestCase):
    def test_plain(self):
        self.assertEqual(parse_money("$12.99"), 12.99)

    def test_thousands_separator(self):
        self.assertEqual(parse_money("$1,234.56"), 1234.56)

    def test_range_takes_low_end(self):
        self.assertEqual(parse_money("$10.00 - $20.00"), 10.0)

    def test_junk_and_empty(self):
        self.assertIsNone(parse_money("Currently unavailable"))
        self.assertIsNone(parse_money(None))
        self.assertIsNone(parse_money(""))


class NumberHelpersTest(unittest.TestCase):
    def test_first_float(self):
        self.assertEqual(_first_float("4.6 out of 5 stars"), 4.6)
        self.assertEqual(_first_float("5 stars"), 5.0)
        self.assertIsNone(_first_float("no rating"))
        self.assertIsNone(_first_float(None))

    def test_first_int_strips_commas(self):
        self.assertEqual(_first_int("4,640 ratings"), 4640)
        self.assertEqual(_first_int("(391)"), 391)
        self.assertIsNone(_first_int("no reviews"))
        self.assertIsNone(_first_int(None))


class ReviewCountTest(unittest.TestCase):
    """The count must come from the ratings phrase, not the first number seen —
    "4.6 out of 5 stars" would otherwise be reported as 4 reviews."""

    def test_plain_count(self):
        self.assertEqual(_review_count("4,640 ratings"), 4640)
        self.assertEqual(_review_count("391 reviews"), 391)
        self.assertEqual(_review_count("1 rating"), 1)

    def test_rating_prefix_is_skipped(self):
        self.assertEqual(_review_count("4.6 out of 5 stars, 4,640 ratings"), 4640)

    def test_rating_alone_is_not_a_count(self):
        self.assertIsNone(_review_count("4.6 out of 5 stars"))

    def test_bare_parenthesized_number_still_counts(self):
        self.assertEqual(_review_count("(391)"), 391)

    def test_empty(self):
        self.assertIsNone(_review_count(None))
        self.assertIsNone(_review_count(""))
        self.assertIsNone(_review_count("no reviews yet"))


class SponsoredTest(unittest.TestCase):
    SEL = "span:has-text('Sponsored')"

    def test_tagged_card(self):
        self.assertIs(_is_sponsored(FakePage(matches={self.SEL: 1})), True)

    def test_organic_card(self):
        self.assertIs(_is_sponsored(FakePage()), False)

    # None, not False: "couldn't tell" must stay distinguishable from "organic",
    # or --hide-sponsored silently drops listings it never checked.
    def test_unprobeable_card_is_unknown(self):
        self.assertIsNone(_is_sponsored(FakePage(raises=[self.SEL])))


class SelectorRotTest(unittest.TestCase):
    FULL = {
        "price": 12.99,
        "availability": "In Stock",
        "delivery_raw": "FREE delivery Tue",
        "seller": "Amazon.com",
        "rating": 4.6,
        "image": "https://m.media-amazon.com/x.jpg",
    }

    def test_complete_scrape_is_silent(self):
        self.assertEqual(emitted(lambda: _warn_selector_rot(dict(self.FULL))), [])

    def test_two_missing_fields_is_still_silent(self):
        # Deliberately not `seller` — a missing seller now has its own warning,
        # and this test used to use it as filler, which quietly asserted that
        # the very gap `_missing_seller_warning` exists to close was acceptable.
        data = dict(self.FULL, image=None, rating=None)
        self.assertEqual(emitted(lambda: _warn_selector_rot(data)), [])

    def test_three_missing_fields_warns(self):
        data = dict(self.FULL, delivery_raw=None, rating=None, image=None)
        events = emitted(lambda: _warn_selector_rot(data))
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["level"], "warn")
        self.assertIn("markup may have changed", events[0]["msg"])
        for field in ("delivery_raw", "rating", "image"):
            self.assertIn(field, events[0]["msg"])

    def test_empty_scrape_warns(self):
        # No price either, so the seller warning stays quiet: with nothing read
        # at all there is no evidence a buybox was even on the page, and the
        # 6/6 line already says everything there is to say.
        events = emitted(lambda: _warn_selector_rot({}))
        self.assertEqual(len(events), 1)
        self.assertIn("6/6", events[0]["msg"])


class MissingSellerWarningTest(unittest.TestCase):
    """A seller that went missing on its own, which the 3-of-6 threshold can't see.

    Every SELLER_SELECTORS entry is rooted at `#buybox`; none of the other five
    field chains is. So a rename of that one container empties exactly one field
    — 1/6, well under the threshold — and the user gets a card that looks whole
    with the Seller line simply absent.
    """

    def test_a_price_without_a_seller_is_announced(self):
        data = dict(SelectorRotTest.FULL, seller=None)
        events = emitted(lambda: _warn_selector_rot(data))
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["level"], "warn")
        self.assertIn("no seller", events[0]["msg"])
        self.assertIn("unknown rather than as absent", events[0]["msg"])

    def test_a_seller_that_was_read_says_nothing(self):
        self.assertEqual(emitted(lambda: _warn_selector_rot(dict(SelectorRotTest.FULL))), [])

    def test_no_price_means_no_claim_about_the_seller(self):
        # Currently-unavailable listings render no buybox price and no seller.
        # Warning here would fire on every one of them.
        data = dict(SelectorRotTest.FULL, seller=None, price=None)
        msgs = [e["msg"] for e in emitted(lambda: _warn_selector_rot(data))]
        self.assertFalse([m for m in msgs if "no seller" in m], msgs)

    def test_it_survives_the_cache(self):
        # Same reasoning as the rot line: the warning is emitted once, live, and
        # then the payload is served from cache for the TTL with no warnings at
        # all unless they are recorded on it.
        data = dict(SelectorRotTest.FULL, seller=None)
        self.assertIn(
            "no seller",
            " ".join(degradations(data)),
        )


class TabularSellerWarningTest(unittest.TestCase):
    """The known gap in SELLER_SELECTORS, made self-reporting.

    The second selector has never matched anything on any listing checked, so
    the comment recording that would stay true-or-not forever. This is the
    observation that settles it, the first time a real page produces one.
    """

    def test_the_tabular_selector_answering_is_announced(self):
        msgs = [e["msg"] for e in emitted(lambda: _warn_tabular_seller(SELLER_SELECTORS[1]))]
        self.assertEqual(len(msgs), 1)
        self.assertIn("tabular buybox selector", msgs[0])
        self.assertIn("capturing this listing as a fixture", msgs[0])

    def test_the_verified_selector_answering_is_not_news(self):
        self.assertEqual(emitted(lambda: _warn_tabular_seller(SELLER_SELECTORS[0])), [])

    def test_no_seller_at_all_is_not_this_warnings_business(self):
        # _missing_seller_warning covers that case; two warnings for one event
        # would teach the user to skim past both.
        self.assertEqual(emitted(lambda: _warn_tabular_seller(None)), [])


class NormalizeSellerTest(unittest.TestCase):
    """`seller` has to be a name, because two callers already assume it is.

    `formatter.rb` prints it after "Seller:" and `web.rb` substring-matches the
    search box against it, so "Sold by Amazon Resale and Fulfilled by Amazon."
    both reads as scraper output and makes a search for "amazon resale" behave
    differently depending on which layout Amazon happened to serve.
    """

    def test_a_bare_name_is_returned_unchanged(self):
        # Both captured fixtures produce this shape, so this is the case that
        # actually runs today. Everything below is the guard, not the path.
        for name in ("Amazon.com", "ELEGOO Official US", "Amazon.com Services LLC"):
            self.assertEqual(normalize_seller(name), name)

    def test_the_classic_merchant_info_sentence_is_reduced_to_the_name(self):
        # Verbatim from #merchant-info on B0DT8PV51T's used-offer row.
        self.assertEqual(
            normalize_seller("Sold by Amazon Resale and Fulfilled by Amazon."),
            "Amazon Resale",
        )

    def test_the_fulfiller_prefix_is_dropped_too(self):
        self.assertEqual(
            normalize_seller("Ships from and sold by Amazon.com."), "Amazon.com"
        )

    def test_a_name_containing_by_is_not_mistaken_for_prose(self):
        # The reason the prefix pattern is anchored and the suffix pattern
        # requires Amazon's own wording: "by" is a perfectly ordinary word in a
        # store name, and a looser rule would truncate this to "Books".
        self.assertEqual(normalize_seller("Books by Bob"), "Books by Bob")

    def test_nothing_is_still_nothing(self):
        # Not "" — `text()` returns None for a chain that matched nothing, and
        # _missing_seller_warning keys off exactly that.
        self.assertIsNone(normalize_seller(None))
        self.assertIsNone(normalize_seller("   "))


class SellerShapeWarningTest(unittest.TestCase):
    """A seller that came back as something other than a name.

    Distinct from the missing-seller warning: this one fires when the chain
    *did* match, which is the case that otherwise passes every check we have —
    the field is non-empty, so the rot threshold counts it as present.
    """

    # The exact string the whole merchant-info container yields when a selector
    # matches the block instead of the cell inside it — the shape that made
    # `Seller: Ships from Amazon` in the first place.
    CONTAINER = "Ships from Amazon.com Sold by ELEGOO Official US"

    def test_prose_that_normalization_did_not_recognize_is_announced(self):
        data = dict(SelectorRotTest.FULL, seller=self.CONTAINER)
        msgs = [e["msg"] for e in emitted(lambda: _warn_selector_rot(data))]
        self.assertTrue([m for m in msgs if "does not look like a seller name" in m], msgs)

    def test_the_offending_value_is_quoted_back(self):
        # A rot warning that doesn't say what it saw can't be acted on.
        data = dict(SelectorRotTest.FULL, seller=self.CONTAINER)
        msgs = [e["msg"] for e in emitted(lambda: _warn_selector_rot(data))]
        self.assertTrue([m for m in msgs if self.CONTAINER in m], msgs)

    def test_leftover_css_is_caught(self):
        # CSS_RULE_RE deliberately leaves a visible ".a," behind rather than
        # risk eating prose (browser.py). This is what makes that residue
        # visible instead of merely honest.
        data = dict(SelectorRotTest.FULL, seller=".a-section, ELEGOO Official US")
        msgs = [e["msg"] for e in emitted(lambda: _warn_selector_rot(data))]
        self.assertTrue([m for m in msgs if "does not look like a seller name" in m], msgs)

    def test_a_plain_name_says_nothing(self):
        for name in ("Amazon.com", "ELEGOO Official US", "Books by Bob"):
            data = dict(SelectorRotTest.FULL, seller=name)
            self.assertEqual(emitted(lambda: _warn_selector_rot(data)), [], name)

    def test_it_survives_the_cache(self):
        data = dict(SelectorRotTest.FULL, seller="Ships from and sold by Widgets Ltd")
        self.assertIn("does not look like a seller name", " ".join(degradations(data)))


class DegradationsTest(unittest.TestCase):
    """What a partial scrape has to carry with it into the cache.

    Every one of these is announced live while the scrape runs, and then the
    result is written to disk for the TTL. Every run after that renders the
    same partial data with none of the warnings — so the run that looks clean
    is the run where the user has no way of knowing it isn't.
    """

    def test_a_whole_scrape_records_nothing(self):
        data = dict(SelectorRotTest.FULL, histogram={str(s): 20 for s in range(1, 6)})
        self.assertEqual(degradations(data), [])

    def test_selector_rot_is_recorded_in_the_same_words_it_was_announced_in(self):
        # Every warning `_warn_selector_rot` emits has to come back off the
        # payload in the same words, so asserting on the whole list rather than
        # the first line keeps a newly-added warning from being announced live
        # and then silently dropped from the cached copy.
        data = dict(SelectorRotTest.FULL, seller=None, rating=None, image=None)
        announced = [e["msg"] for e in emitted(lambda: _warn_selector_rot(dict(data)))]
        self.assertEqual(degradations(data), announced)
        self.assertEqual(len(announced), 2)

    def test_a_half_read_histogram_is_recorded(self):
        data = dict(SelectorRotTest.FULL, histogram={"5": 79, "4": 10})
        self.assertEqual(len(degradations(data)), 1)
        self.assertIn("2 of 5", degradations(data)[0])

    def test_a_listing_with_no_histogram_at_all_is_ordinary(self):
        # Distinct from a table we half-read: plenty of listings have no
        # ratings, and calling that degraded would cry wolf on every one.
        self.assertEqual(degradations(dict(SelectorRotTest.FULL, histogram={})), [])

    def test_an_empty_review_sample_is_recorded(self):
        data = dict(SelectorRotTest.FULL, reviews_sample=[])
        self.assertEqual(len(degradations(data)), 1)
        self.assertIn("no reviews", degradations(data)[0])

    def test_reviews_that_were_never_asked_for_are_not_missing(self):
        # `amazon item` without --reviews has no sample by design.
        self.assertEqual(degradations(dict(SelectorRotTest.FULL)), [])


class GuardTest(unittest.TestCase):
    def test_normal_page_passes(self):
        guard(FakePage())  # no exception

    def test_captcha_form_is_blocked(self):
        with self.assertRaises(Blocked) as cm:
            guard(FakePage(matches={"#captchacharacters": 1}))
        self.assertIn("captcha", str(cm.exception))

    # Fail closed: if no probe completed we can't tell a robot check from real
    # content, so raise rather than scrape the block page as a product.
    def test_all_probes_failing_is_blocked_not_allowed(self):
        page = FakePage(raises=browser.CAPTCHA_MARKERS)
        with self.assertRaises(Blocked) as cm:
            guard(page)
        self.assertIn("could not determine", str(cm.exception))

    def test_one_successful_probe_is_enough(self):
        guard(FakePage(raises=browser.CAPTCHA_MARKERS[:2]))

    def test_signin_redirect_raises_not_logged_in(self):
        with self.assertRaises(NotLoggedIn):
            guard(FakePage(url="https://www.amazon.com/ap/signin?openid.return_to=x"))

    def test_a_verify_its_you_challenge_is_a_dead_session_not_a_product(self):
        # Spelled out as a literal rather than looped over SIGNIN_URLS, because
        # this path was added to that tuple for `login.py`'s benefit and it
        # changes what `sync` does too: without it, `guard()` waves the challenge
        # page through and the extractors scrape it, so an expired session
        # surfaces as a product with every field empty instead of "run: amazon
        # login". A loop over the constant would assert nothing about that.
        with self.assertRaises(NotLoggedIn):
            guard(FakePage(url="https://www.amazon.com/ap/challenge?arb=1"))


class SigninPageTest(unittest.TestCase):
    def test_product_page_is_not_signin(self):
        self.assertFalse(is_signin_page(FakePage()))

    def test_signin_urls(self):
        for path in browser.SIGNIN_URLS:
            self.assertTrue(is_signin_page(FakePage(url=f"https://www.amazon.com{path}")))

    def test_signin_markers_without_a_matching_url(self):
        # Amazon sometimes renders the sign-in form under a content URL.
        self.assertTrue(is_signin_page(FakePage(matches={"#ap_password": 1})))

    def test_unreadable_url_falls_back_to_markers(self):
        page = FakePage(matches={"#ap_email": 1})
        type(page).url = property(lambda self: (_ for _ in ()).throw(RuntimeError("closed")))
        try:
            self.assertTrue(is_signin_page(page))
        finally:
            del type(page).url


if __name__ == "__main__":
    unittest.main()


class SessionRejectedTest(unittest.TestCase):
    """A dead session shows up as a mid-request redirect, not a login failure —
    amazon-orders trusts the cookie jar and never calls out during login()."""

    def test_recognizes_the_amazon_orders_message(self):
        # Verbatim from a real run against an invalidated session.
        e = Exception(
            "Amazon redirected to login. Call AmazonSession.login() to "
            "reauthenticate first."
        )
        self.assertTrue(session_rejected(e))

    def test_case_insensitive(self):
        self.assertTrue(session_rejected(Exception("Redirected To Login")))

    def test_unrelated_failures_are_not_misread(self):
        self.assertFalse(session_rejected(Exception("connection reset by peer")))
        self.assertFalse(session_rejected(Exception("503 Service Unavailable")))
        self.assertFalse(session_rejected(Exception("")))


# --- review scraping ---------------------------------------------------


class FakeTextLocator:
    """Stand-in for a Playwright locator that also yields text and attributes."""

    def __init__(self, count=1, text="", attrs=None, raises=False):
        self._count = count
        self._text = text
        self._attrs = attrs or {}
        self._raises = raises

    @property
    def first(self):
        return self

    def nth(self, _i):
        return self

    def count(self):
        if self._raises:
            raise RuntimeError("execution context was destroyed")
        return self._count

    def inner_text(self):
        if self._raises:
            raise RuntimeError("execution context was destroyed")
        return self._text

    def get_attribute(self, name):
        if self._raises:
            raise RuntimeError("execution context was destroyed")
        return self._attrs.get(name)

    def locator(self, _sel):
        # `text()` asks every match for its <style>/<script> children. A locator
        # that can't answer raises, and `text()` catches everything and moves on
        # — so the field would come back empty with nothing said. Answering
        # "none" is what a real locator does for a container that has none.
        return FakeTextLocator(count=0)

    def all_text_contents(self):
        return []


class FakeScope:
    """selector -> FakeTextLocator. Unknown selectors match nothing."""

    def __init__(self, mapping=None, attrs=None, raises=False):
        self._mapping = mapping or {}
        self._attrs = attrs or {}
        self._raises = raises

    def locator(self, sel):
        if self._raises:
            raise RuntimeError("detached")
        found = self._mapping.get(sel)
        if found is None:
            return FakeTextLocator(count=0)
        return found

    def get_attribute(self, name):
        return self._attrs.get(name)


class FakeCardList:
    """A locator standing in for N review cards."""

    def __init__(self, cards):
        self._cards = cards

    def count(self):
        return len(self._cards)

    def nth(self, i):
        return self._cards[i]


class ParseReviewDateTest(unittest.TestCase):
    def test_us_ordering(self):
        self.assertEqual(
            parse_review_date("Reviewed in the United States on July 26, 2025"), "2025-07-26"
        )

    def test_international_day_first_ordering(self):
        # Must not be read as month-first; there is no 26th month.
        self.assertEqual(parse_review_date("Reviewed in Canada on 26 July 2025"), "2025-07-26")

    def test_abbreviated_month(self):
        self.assertEqual(parse_review_date("Reviewed on Jan 3, 2026"), "2026-01-03")

    def test_impossible_date_is_rejected_not_clamped(self):
        self.assertIsNone(parse_review_date("Reviewed on February 30, 2025"))

    def test_no_date_and_empty(self):
        self.assertIsNone(parse_review_date("Reviewed in the United States"))
        self.assertIsNone(parse_review_date(""))
        self.assertIsNone(parse_review_date(None))


class ParseReviewCountryTest(unittest.TestCase):
    def test_strips_leading_article(self):
        self.assertEqual(
            parse_review_country("Reviewed in the United States on July 26, 2025"),
            "United States",
        )

    def test_plain_country(self):
        self.assertEqual(parse_review_country("Reviewed in Canada on 26 July 2025"), "Canada")

    def test_unparseable(self):
        self.assertIsNone(parse_review_country("Top review from the United States"))
        self.assertIsNone(parse_review_country(""))
        self.assertIsNone(parse_review_country(None))


class ParseHelpfulVotesTest(unittest.TestCase):
    def test_plural(self):
        self.assertEqual(parse_helpful_votes("12 people found this helpful"), 12)

    def test_thousands_separator(self):
        self.assertEqual(parse_helpful_votes("1,234 people found this helpful"), 1234)

    def test_the_word_one(self):
        self.assertEqual(parse_helpful_votes("One person found this helpful"), 1)

    def test_absent(self):
        self.assertIsNone(parse_helpful_votes(""))
        self.assertIsNone(parse_helpful_votes(None))
        self.assertIsNone(parse_helpful_votes("Helpful"))


class StripStarPrefixTest(unittest.TestCase):
    def test_removes_the_rating_line(self):
        self.assertEqual(strip_star_prefix("5.0 out of 5 stars\nWorks great"), "Works great")

    def test_leaves_a_clean_title_alone(self):
        self.assertEqual(strip_star_prefix("Works great"), "Works great")

    def test_prefix_only_yields_none(self):
        self.assertIsNone(strip_star_prefix("4.0 out of 5 stars"))
        self.assertIsNone(strip_star_prefix(""))
        self.assertIsNone(strip_star_prefix(None))


class ParseHistogramLabelTest(unittest.TestCase):
    def test_aria_label_form(self):
        self.assertEqual(parse_histogram_label("5 stars represent 71% of rating"), (5, 71))

    def test_bare_row_text(self):
        self.assertEqual(parse_histogram_label("4 star 12%"), (4, 12))

    def test_percent_first_ordering(self):
        self.assertEqual(parse_histogram_label("71% of reviews have 5 stars"), (5, 71))

    def test_percent_over_100_is_not_a_histogram_row(self):
        self.assertIsNone(parse_histogram_label("5 stars out of 900% growth"))

    def test_unparseable(self):
        self.assertIsNone(parse_histogram_label("See all reviews"))
        self.assertIsNone(parse_histogram_label(""))
        self.assertIsNone(parse_histogram_label(None))


class ReviewsUrlTest(unittest.TestCase):
    def test_defaults_to_helpful(self):
        url = reviews_url("B0747R1M51")
        self.assertIn("/product-reviews/B0747R1M51", url)
        self.assertIn("sortBy=helpful", url)

    def test_recent_sort(self):
        self.assertIn("sortBy=recent", reviews_url("B0747R1M51", "recent"))

    def test_unknown_sort_falls_back_rather_than_injecting_it(self):
        self.assertIn("sortBy=helpful", reviews_url("B1", "bogus"))

    def test_no_page_number_is_asked_for(self):
        # Amazon ignores it — measured against B09BJMY8HL, pageNumber=1..4 each
        # served the same ten reviews. Sending it anyway produced a walk that
        # re-read batch one N times and then announced the listing had no more,
        # which is a claim about Amazon assembled out of our own dead parameter.
        self.assertNotIn("pageNumber", reviews_url("B0747R1M51", "recent"))


def aria_rows(*pairs):
    """A locator over N histogram rows, each carrying its own aria-label."""
    return FakeCardList([
        FakeTextLocator(attrs={"aria-label": f"{star} stars represent {pct}% of rating"})
        for star, pct in pairs
    ])


FULL_HISTOGRAM = ((5, 79), (4, 10), (3, 5), (2, 2), (1, 4))


class ScrapeHistogramTest(unittest.TestCase):
    def test_reads_aria_labels(self):
        page = FakeScope({"#histogramTable a[aria-label]": aria_rows(*FULL_HISTOGRAM)})
        self.assertEqual(scrape_histogram(page), {"5": 79, "4": 10, "3": 5, "2": 2, "1": 4})

    def test_falls_back_to_row_text_when_no_aria_labels(self):
        rows = FakeTextLocator(count=1, text="3 star   9%")
        page = FakeScope({"#histogramTable .a-histogram-row, .a-histogram-row": rows})
        self.assertEqual(scrape_histogram(page), {"3": 9})

    def test_missing_table_reports_unknown_not_zero(self):
        # {} must mean "couldn't read it", never "no ratings" — the Ruby side
        # drops the whole signal on {} rather than scoring a perfect record.
        self.assertEqual(scrape_histogram(FakeScope()), {})

    def test_survives_a_detached_page(self):
        self.assertEqual(scrape_histogram(FakeScope(raises=True)), {})

    # Was: a single row was accepted as the whole histogram and returned as
    # final. A star distribution is five rows by definition, so anything short
    # of five means the read is incomplete — and downstream, every absent star
    # scored as 0%, which is the shape the fraud model treats as damning.
    def test_a_partial_read_does_not_end_the_search(self):
        page = FakeScope({
            "#histogramTable a[aria-label]": aria_rows((5, 79)),
            "[data-hook=cr-histogram-row] a[aria-label]": aria_rows(*FULL_HISTOGRAM),
        })
        self.assertEqual(scrape_histogram(page), {"5": 79, "4": 10, "3": 5, "2": 2, "1": 4})

    def test_a_partial_read_is_reported_rather_than_passed_off_as_whole(self):
        page = FakeScope({"#histogramTable a[aria-label]": aria_rows((5, 79))})
        events = emitted(lambda: scrape_histogram(page))
        self.assertEqual([e["level"] for e in events], ["warn"])
        self.assertIn("1 of 5", events[0]["msg"])

    def test_a_complete_read_is_silent(self):
        page = FakeScope({"#histogramTable a[aria-label]": aria_rows(*FULL_HISTOGRAM)})
        self.assertEqual(emitted(lambda: scrape_histogram(page)), [])

    def test_an_unreadable_table_is_not_reported_as_a_partial(self):
        # Nothing read at all is already handled downstream as "unknown"; a
        # warn here would fire on every page that simply has no histogram.
        self.assertEqual(emitted(lambda: scrape_histogram(FakeScope())), [])


class ReviewIdTest(unittest.TestCase):
    def test_strips_the_product_page_prefix(self):
        self.assertEqual(_review_id(FakeScope(attrs={"id": "customer_review-R1A2B3"})), "R1A2B3")

    def test_bare_id_passes_through(self):
        self.assertEqual(_review_id(FakeScope(attrs={"id": "R1A2B3"})), "R1A2B3")

    def test_missing_id(self):
        self.assertIsNone(_review_id(FakeScope()))

    def test_detached_card(self):
        class Boom:
            def get_attribute(self, _name):
                raise RuntimeError("detached")

        self.assertIsNone(_review_id(Boom()))


class HasTest(unittest.TestCase):
    def test_true_when_any_selector_matches(self):
        scope = FakeScope({"[data-hook=avp-badge]": FakeTextLocator(count=1)})
        self.assertTrue(_has(scope, "[data-hook=nope]", "[data-hook=avp-badge]"))

    def test_false_when_none_match(self):
        self.assertFalse(_has(FakeScope(), "[data-hook=avp-badge]"))

    def test_a_throwing_probe_is_skipped_not_fatal(self):
        scope = FakeScope({"a": FakeTextLocator(raises=True), "b": FakeTextLocator(count=1)})
        self.assertTrue(_has(scope, "a", "b"))

    # None, not False — the same contract _is_sponsored already keeps. False is
    # a claim that the badge is absent, and a probe that never completed has
    # made no such claim. This feeds the verified-purchase signal, the heaviest
    # in the model, where "absent" is read as evidence of a review farm.
    def test_a_card_that_cannot_be_probed_at_all_is_unknown(self):
        self.assertIsNone(_has(FakeScope(raises=True), "[data-hook=avp-badge]"))

    def test_unknown_survives_when_every_probe_throws(self):
        scope = FakeScope({"a": FakeTextLocator(raises=True), "b": FakeTextLocator(raises=True)})
        self.assertIsNone(_has(scope, "a", "b"))

    def test_one_completed_probe_is_enough_to_say_absent(self):
        scope = FakeScope({"a": FakeTextLocator(raises=True)})
        self.assertIs(_has(scope, "a", "b"), False)


class ScrapeReviewCardsTest(unittest.TestCase):
    def card(self, **overrides):
        mapping = {
            "[data-hook=review-title] > span:last-child": FakeTextLocator(text="Works great"),
            "[data-hook=review-star-rating]": FakeTextLocator(text="5.0 out of 5 stars"),
            "[data-hook=review-date]": FakeTextLocator(
                text="Reviewed in the United States on July 26, 2025"
            ),
            "[data-hook=review-body]": FakeTextLocator(text="Solid little thing."),
            "[data-hook=avp-badge]": FakeTextLocator(count=1),
            ".a-profile-name": FakeTextLocator(text="Jamie"),
            "[data-hook=helpful-vote-statement]": FakeTextLocator(
                text="12 people found this helpful"
            ),
        }
        mapping.update(overrides)
        return FakeScope(mapping, attrs={"id": "customer_review-R1"})

    def scrape(self, cards):
        scope = FakeScope({"[data-hook=review], [data-hook=cmps-review]": FakeCardList(cards)})
        return scrape_review_cards(scope)

    def test_full_card(self):
        (r,) = self.scrape([self.card()])
        self.assertEqual(r["id"], "R1")
        self.assertEqual(r["title"], "Works great")
        self.assertEqual(r["rating"], 5.0)
        self.assertEqual(r["date"], "2025-07-26")
        self.assertEqual(r["country"], "United States")
        self.assertTrue(r["verified"])
        self.assertFalse(r["vine"])
        self.assertEqual(r["author"], "Jamie")
        self.assertEqual(r["helpful_votes"], 12)
        self.assertEqual(r["body"], "Solid little thing.")

    def test_unverified_and_vine_are_separate_flags(self):
        card = self.card(
            **{
                "[data-hook=avp-badge]": FakeTextLocator(count=0),
                "[data-hook=review-vine-badge]": FakeTextLocator(count=1),
            }
        )
        (r,) = self.scrape([card])
        self.assertFalse(r["verified"])
        self.assertTrue(r["vine"])

    def test_individually_missing_fields_degrade_to_none(self):
        card = self.card(
            **{
                "[data-hook=review-date]": FakeTextLocator(count=0),
                ".a-profile-name": FakeTextLocator(count=0),
                "[data-hook=helpful-vote-statement]": FakeTextLocator(count=0),
            }
        )
        (r,) = self.scrape([card])
        self.assertEqual(r["title"], "Works great")
        self.assertIsNone(r["date"])
        self.assertIsNone(r["country"])
        self.assertIsNone(r["author"])
        self.assertIsNone(r["helpful_votes"])

    def test_a_wholly_empty_card_is_dropped_not_counted(self):
        # An unreadable card yields all-None, which is indistinguishable from a
        # real review. Keeping it would add a phantom unverified review to the
        # sample and inflate the manipulation score downstream.
        self.assertEqual(self.scrape([FakeScope({}, attrs={"id": "R9"})]), [])

    def test_no_review_container_at_all(self):
        self.assertEqual(scrape_review_cards(FakeScope()), [])

    def test_a_detached_scope_yields_nothing_rather_than_raising(self):
        self.assertEqual(scrape_review_cards(FakeScope(raises=True)), [])

    def test_one_broken_card_does_not_lose_the_rest(self):
        class Boom:
            def locator(self, _sel):
                raise RuntimeError("detached mid-read")

            def get_attribute(self, _name):
                raise RuntimeError("detached mid-read")

        results = self.scrape([Boom(), self.card()])
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["id"], "R1")


class LiveMarkup2026Test(unittest.TestCase):
    """Regressions pinned to markup observed on a real product page.

    Every one of these silently produced None or {} against the selectors and
    patterns written from the older layout, which is exactly the failure mode
    that is invisible in a unit test written from the same assumption.
    """

    def scrape_card(self, mapping):
        card = FakeScope(mapping, attrs={"id": "customer_review-R1"})
        scope = FakeScope({"[data-hook=review], [data-hook=cmps-review]": FakeCardList([card])})
        return scrape_review_cards(scope)[0]

    def test_histogram_label_spells_out_percent(self):
        # "79 percent of reviews have 5 stars" — no "%" anywhere in the label.
        self.assertEqual(parse_histogram_label("79 percent of reviews have 5 stars"), (5, 79))
        self.assertEqual(parse_histogram_label("5 stars represent 79 percent of rating"), (5, 79))

    def test_percent_word_still_rejects_impossible_shares(self):
        self.assertIsNone(parse_histogram_label("5 stars, 900 percent growth"))

    def test_title_comes_from_the_reviewTitle_hook(self):
        r = self.scrape_card({"[data-hook=reviewTitle]": FakeTextLocator(text="Not a good purchase")})
        self.assertEqual(r["title"], "Not a good purchase")

    def test_body_comes_from_the_rich_content_hook(self):
        r = self.scrape_card(
            {"[data-hook=reviewRichContentContainer]": FakeTextLocator(text="Died in a month.")}
        )
        self.assertEqual(r["body"], "Died in a month.")

    def test_body_falls_back_to_the_review_text_deck(self):
        r = self.scrape_card({"[data-hook=reviewText]": FakeTextLocator(text="Died in a month.")})
        self.assertEqual(r["body"], "Died in a month.")

    def test_older_hooks_still_win_when_the_new_ones_are_absent(self):
        r = self.scrape_card(
            {
                "[data-hook=review-title] > span:last-child": FakeTextLocator(text="Old layout"),
                "[data-hook=review-body]": FakeTextLocator(text="Old body"),
            }
        )
        self.assertEqual(r["title"], "Old layout")
        self.assertEqual(r["body"], "Old body")


class ScrapeReviewsPaginationFailureTest(unittest.TestCase):
    class Page:
        """A product page whose /product-reviews/ leg is unreachable."""

        def __init__(self, cards):
            self._cards = cards

        def locator(self, sel):
            if sel == "[data-hook=review], [data-hook=cmps-review]":
                return FakeCardList(self._cards)
            return FakeTextLocator(count=0)

        def goto(self, *_a, **_kw):
            raise RuntimeError("redirected to sign-in")

        def wait_for_timeout(self, _ms):
            pass

    def test_a_dead_pagination_leg_keeps_the_product_page_sample(self):
        # /product-reviews/ demands a live session even when /dp/ renders for a
        # stale one. Losing the whole report over the depth we couldn't reach
        # would throw away an answer we already had in hand.
        card = FakeScope(
            {"[data-hook=reviewTitle]": FakeTextLocator(text="Works great")},
            attrs={"id": "customer_review-R1"},
        )
        got, walk = scrape_reviews(self.Page([card]), "B0TEST00001", pages=3)
        self.assertEqual(len(got), 1)
        self.assertEqual(got[0]["title"], "Works great")
        # "failed", not "exhausted": the report must not tell the user this is
        # everything Amazon would serve when the truth is the fetch broke.
        self.assertEqual(walk, "failed")


class ScrapeReviewsSessionFailureTest(unittest.TestCase):
    """A captcha or a dead session mid-walk must not be reported as a result.

    Both subclass RuntimeError, so the blanket `except Exception` around the
    pagination leg used to swallow them: the walk degraded to the product-page
    sample, the top-level handlers never emitted kind:"blocked"/"not_logged_in",
    and the user got a complete-looking fraud report built on ~8 reviews with
    exit 0 and no way to learn that `amazon login` was the fix. guard()'s own
    contract is to fail closed rather than scrape a robot check as a product;
    catching it one level up reopened exactly that hole.
    """

    class Page:
        def __init__(self, exc):
            self._exc = exc

        def locator(self, sel):
            if sel == "[data-hook=review], [data-hook=cmps-review]":
                return FakeCardList([
                    FakeScope(
                        {"[data-hook=reviewTitle]": FakeTextLocator(text="Works great")},
                        attrs={"id": "customer_review-R1"},
                    )
                ])
            return FakeTextLocator(count=0)

        def goto(self, *_a, **_kw):
            raise self._exc

        def wait_for_timeout(self, _ms):
            pass

    def test_a_captcha_mid_walk_propagates(self):
        with self.assertRaises(Blocked):
            scrape_reviews(self.Page(Blocked("captcha")), "B0TEST00001", pages=3)

    def test_an_expired_session_mid_walk_propagates(self):
        with self.assertRaises(NotLoggedIn):
            scrape_reviews(self.Page(NotLoggedIn("session expired")), "B0TEST00001", pages=3)

    def test_a_transport_failure_still_degrades_to_the_sample_in_hand(self):
        # The distinction that matters: a page that wouldn't load costs us depth
        # we can report around; a session that is gone costs us the answer.
        got, walk = scrape_reviews(
            self.Page(RuntimeError("net::ERR_CONNECTION_RESET")), "B0TEST00001", pages=3
        )
        self.assertEqual(len(got), 1)
        self.assertEqual(walk, "failed")


def review_card(ident=None, title="Works great", body=None, author=None, date=None):
    """One review card's worth of selector -> text, as `scrape_review_cards` reads it."""
    mapping = {"[data-hook=reviewTitle]": FakeTextLocator(text=title)}
    if body:
        mapping["[data-hook=reviewRichContentContainer]"] = FakeTextLocator(text=body)
    if author:
        mapping[".a-profile-name"] = FakeTextLocator(text=author)
    if date:
        mapping["[data-hook=review-date]"] = FakeTextLocator(text=date)
    return FakeScope(mapping, attrs={"id": f"customer_review-{ident}"} if ident else {})


class FakeListingPage:
    """A product page whose review listing appends ten more per click.

    Models the mechanism Amazon actually ships: loading /product-reviews/
    yields `batch` cards, and each "Show 10 more reviews" click appends another
    `batch` into the same DOM until `available` is exhausted, at which point the
    button is gone. There is no numbered pager and no second URL to load, which
    is why `gotos` is counted — a walk that navigates per page is re-reading
    batch one, and that is the bug this models.

    The product page's own reviews are a prefix of the listing's, as they are
    on a helpful-sorted listing, so the dedupe is exercised on every run.
    """

    def __init__(self, available=30, batch=10, on_product_page=2, click="grow", ids=True):
        self._available = available
        self._batch = batch
        self._on_product_page = on_product_page
        self._click = click
        self._ids = ids
        self._shown = 0
        self._listing = False
        self.gotos = 0

    def _card(self, i):
        return review_card(
            ident=f"R{i}" if self._ids else None,
            title=f"review {i}",
            body=f"Reviewer number {i} had a fine time with it.",
            author=f"Dana {i}",
        )

    # -- the page API scrape_reviews uses -------------------------------

    def goto(self, *_a, **_kw):
        self.gotos += 1
        self._listing = True
        self._shown = min(self._batch, self._available)

    def wait_for_timeout(self, _ms):
        pass

    def wait_for_function(self, _expr, arg=None, timeout=None):
        # The real call waits on the card count rising past `arg`. Asserting
        # that here rather than on a flag keeps the fake honest about what a
        # stalled click looks like: the button is clicked, nothing lands.
        if self._shown <= (arg or 0):
            raise RuntimeError("Timeout 15000ms exceeded")

    def locator(self, sel):
        if sel == REVIEW_CARDS:
            visible = self._shown if self._listing else self._on_product_page
            return FakeCardList([self._card(i) for i in range(visible)])
        if sel == SHOW_MORE_BUTTON:
            return FakeShowMore(self, self._listing and self._shown < self._available)
        return FakeTextLocator(count=0)

    def click_show_more(self):
        if self._click == "grow":
            self._shown = min(self._shown + self._batch, self._available)


class FakeShowMore:
    """The "Show 10 more reviews" button, or the absence of one."""

    def __init__(self, page, present):
        self._page = page
        self._present = present

    def count(self):
        return 1 if self._present else 0

    @property
    def first(self):
        return self

    def scroll_into_view_if_needed(self, timeout=None):
        pass

    def click(self, timeout=None):
        self._page.click_show_more()


class ScrapeItemMissingProductTest(unittest.TestCase):
    """An ASIN that resolves to nothing is a user error, not a crash.

    It raised a bare RuntimeError, and `main`'s catch-all treats every
    RuntimeError as a bug in us: traceback to stderr, `kind` left unset, and
    the CLI then prefixed the message with "live lookup failed" and stapled the
    last seven stderr lines underneath. Five lines of Python internals whose
    top frame is our own `raise`, shown to someone who mistyped an ASIN.
    """

    class Page:
        """A page that loads and passes guard(), but carries no product."""

        url = "https://www.amazon.com/dp/B0DEMO1234"

        def goto(self, *_a, **_kw):
            pass

        def wait_for_timeout(self, _ms):
            pass

        def locator(self, _sel):
            return FakeTextLocator(count=0)

    def test_a_page_with_no_title_raises_no_product(self):
        with self.assertRaises(NoProduct) as caught:
            scrape_item(self.Page(), "B0DEMO1234")
        self.assertIn("B0DEMO1234", str(caught.exception))

    def test_it_is_not_the_generic_runtime_error_the_catch_all_handles(self):
        # The distinction is the whole fix: `main` can only route this away
        # from the traceback path if it is its own class. Subclassing
        # RuntimeError keeps every existing caller working, so the type check
        # rather than the inheritance is what the routing turns on.
        self.assertTrue(issubclass(NoProduct, RuntimeError))
        self.assertNotIn(type(NoProduct("x")), (RuntimeError, Blocked, NotLoggedIn))


class ExpandReviewsTest(unittest.TestCase):
    """The three outcomes of one "show more" click, which the caller acts on
    differently: only "stalled" means the reviews exist and we failed to get
    them."""

    def test_a_click_that_appends_a_batch_grew(self):
        page = FakeListingPage(available=30)
        page.goto()
        self.assertEqual(expand_reviews(page), "grew")
        self.assertEqual(len(scrape_review_cards(page)), 20)

    def test_no_button_is_the_end_of_the_listing(self):
        page = FakeListingPage(available=10)
        page.goto()
        self.assertEqual(expand_reviews(page), "end")

    def test_a_button_that_delivers_nothing_is_stalled_not_the_end(self):
        page = FakeListingPage(available=30, click="stall")
        page.goto()
        self.assertEqual(expand_reviews(page), "stalled")


class ScrapeReviewsDepthTest(unittest.TestCase):
    """Whether the walk got everything it asked Amazon for."""

    def test_the_listing_is_loaded_once_however_many_pages_are_asked_for(self):
        # The defect this replaced: `--pages 10` navigated ten times to
        # `?pageNumber=1..10`, Amazon ignored the parameter and served the same
        # ten reviews each time, the dedupe correctly found nothing new on the
        # second — and the walk announced that Amazon had no more to give for a
        # listing with 6,258 ratings. Ten page loads to report fifteen reviews.
        page = FakeListingPage(available=100)
        got, walk = scrape_reviews(page, "B0TEST00001", pages=5)
        self.assertEqual(page.gotos, 1)
        self.assertEqual(len(got), 50)
        self.assertEqual(walk, "complete")

    def test_a_walk_that_runs_out_early_is_reported_as_incomplete(self):
        # 15 reviews on the listing, 3 batches asked for: the second click has
        # no button to press, and that is the listing's answer, not a failure.
        got, walk = scrape_reviews(FakeListingPage(available=15), "B0TEST00001", pages=3)
        self.assertEqual(len(got), 15)
        self.assertEqual(walk, "exhausted")

    def test_a_full_walk_is_reported_as_complete(self):
        got, walk = scrape_reviews(FakeListingPage(available=50), "B0TEST00001", pages=3)
        self.assertEqual(walk, "complete")
        self.assertEqual(len(got), 30)

    def test_the_product_pages_own_reviews_are_not_counted_twice(self):
        # They reappear at the top of the listing. Counting 10 for a listing
        # that served 10 is the whole assertion.
        got, _ = scrape_reviews(
            FakeListingPage(available=10, on_product_page=3), "B0TEST00001", pages=1
        )
        self.assertEqual(len(got), 10)

    def test_asking_for_no_pages_never_leaves_the_product_page(self):
        # `--pages 0` got exactly the depth it requested; nothing was refused,
        # and nothing was loaded to find that out.
        page = FakeListingPage(available=50, on_product_page=8)
        got, walk = scrape_reviews(page, "B0TEST00001", pages=0)
        self.assertEqual(walk, "complete")
        self.assertEqual(len(got), 8)
        self.assertEqual(page.gotos, 0)

    def test_a_button_that_stops_delivering_is_a_failure_not_the_end(self):
        # The distinction the report turns into advice. The button is still on
        # the page, so the reviews are there — calling that "exhausted" would
        # print "that is everything Amazon would serve for this listing" and
        # talk the user out of the retry that works.
        got, walk = scrape_reviews(
            FakeListingPage(available=100, click="stall"), "B0TEST00001", pages=4
        )
        self.assertEqual(walk, "failed")
        self.assertEqual(len(got), 10)


class ScrapeReviewsIdlessDedupeTest(unittest.TestCase):
    """Cards without a container id must still deduplicate.

    Dedup keyed on the id alone, and a card with no id was kept unconditionally.
    The listing appends rather than replaces, so every batch re-reads the cards
    already on the page: the sample inflated by a full batch per click, the
    "nothing new" end-of-walk signal never fired, and the duplicate-wording
    check — which scores reviews that share phrasing as bought — was handed a
    listing's own reviews repeated verbatim. Selector drift on one attribute
    would have manufactured a maximum-confidence accusation.

    The `read` offset in `scrape_reviews` skips most of that re-reading now, but
    it is an optimization and must not be what makes the count right: these
    cards are id-less, so if the content fallback stopped working the offset
    alone would still let the product page's copies through.
    """

    class Page:
        """Every card is id-less, and the listing serves the same one review."""

        def __init__(self):
            self._listing = False

        def locator(self, sel):
            if sel == REVIEW_CARDS:
                return FakeCardList([
                    review_card(
                        title="Works great",
                        date="Reviewed in the United States on March 2, 2024",
                        body="Held up to a full season of use with no complaints.",
                        author="Dana",
                    )
                ])
            if sel == SHOW_MORE_BUTTON:
                return FakeShowMore(self, self._listing)
            return FakeTextLocator(count=0)

        def goto(self, *_a, **_kw):
            self._listing = True

        def wait_for_timeout(self, _ms):
            pass

        def wait_for_function(self, _expr, arg=None, timeout=None):
            pass

        def click_show_more(self):
            pass

    def test_the_same_id_less_review_is_not_collected_once_per_batch(self):
        got, walk = scrape_reviews(self.Page(), "B0TEST00001", pages=3)
        self.assertEqual(len(got), 1)
        self.assertIsNone(got[0]["id"])
        # The listing handed back only what the product page already had, which
        # is the "all reviews already collected" branch — the walk stops rather
        # than clicking twice more for the same card.
        self.assertEqual(walk, "exhausted")

    def test_distinct_id_less_reviews_are_all_kept(self):
        # The fallback keys on content, so it must not collapse two people who
        # happened to be handed the same product.
        got, walk = scrape_reviews(
            FakeListingPage(available=40, batch=10, on_product_page=2, ids=False),
            "B0TEST00001",
            pages=3,
        )
        self.assertEqual(len(got), 30)
        self.assertEqual(walk, "complete")


class FakeTextPage:
    """Selector -> raw inner_text, for exercising `text()`'s fallback chain.

    Built on the review suite's `FakeTextLocator` rather than a second stand-in
    of its own: two locator fakes in one file is how one of them quietly stops
    resembling Playwright.
    """

    def __init__(self, texts):
        self._texts = texts

    def locator(self, sel):
        found = self._texts.get(sel)
        if found is None:
            return FakeTextLocator(count=0)
        return FakeTextLocator(count=1, text=found)


class TextFromTest(unittest.TestCase):
    """`text_from` has to name the selector that answered, not just the value."""

    PAGE = FakeTextPage(
        {
            "#first": "",
            "#second": "  Amazon.com  ",
            "#third": "Never reached",
        }
    )

    def test_it_reports_the_selector_that_produced_the_value(self):
        val, sel = browser.text_from(self.PAGE, "#missing", "#first", "#second", "#third")
        self.assertEqual(val, "Amazon.com")
        self.assertEqual(sel, "#second")

    def test_a_chain_that_matched_nothing_names_no_selector(self):
        # Not ("", "") — a caller keying off the selector has to be able to tell
        # "nothing matched" from "the first one did".
        self.assertEqual(browser.text_from(self.PAGE, "#missing", "#first"), (None, None))

    def test_text_still_returns_just_the_value(self):
        self.assertEqual(text(self.PAGE, "#missing", "#second"), "Amazon.com")


class CleanTextTest(unittest.TestCase):
    # Verbatim from #availability_feature_div on a live product page. Playwright
    # hands back the inlined <style> block as though it were copy.
    AVAILABILITY = (
        "Only 4 left in stock - order soon.                    \n"
        "    .availabilityMoreDetailsIcon {\n"
        "        width: 12px;\n"
        "        vertical-align: baseline;\n"
        "        fill: #969696;\n"
        "    }"
    )

    def test_an_inlined_style_block_is_dropped(self):
        self.assertEqual(clean_text(self.AVAILABILITY), "Only 4 left in stock - order soon.")

    def test_whitespace_is_collapsed(self):
        self.assertEqual(clean_text("  In\n  Stock \t"), "In Stock")

    def test_ordinary_copy_is_untouched(self):
        # Braces and #hashes appear in real titles. What actually distinguishes
        # a rule from copy here is not "selector plus braced body" — that was
        # this comment's earlier claim and the regex never implemented it, which
        # is how `Includes 3.5mm cable {black} and case` came back as
        # `Includes 3 and case`. The rule is narrower: a rule has to *begin its
        # own line*, and its selector has to stay on the same line as its brace.
        # Every case below carries a dot-word, a brace, or both, mid-line.
        for raw in (
            "Sold by Amazon.com",
            "Set of 4 {assorted} colors",
            "Filament #3 refill",
            "Includes 3.5mm cable {black} and case",
            "Cable is 3.5mm; connector {TRRS} included",
        ):
            self.assertEqual(clean_text(raw), raw)

    def test_a_rule_that_does_not_start_its_own_line_is_left_alone(self):
        # The other side of that bargain, stated so it isn't mistaken for a bug
        # later: the anchor buys "never eat prose" at the price of "may miss a
        # rule". Missing one prints visible junk; the alternative silently
        # deletes real copy, and only one of those a user can see and report.
        raw = "In Stock. .avail { color: red; }"
        self.assertEqual(clean_text(raw), raw)

    def test_copy_is_untouched_even_with_a_style_block_below_it(self):
        # The case the test above cannot reach. "Amazon.com" contains a token
        # that looks exactly like a class selector, and it only costs anything
        # when there is a real rule further down for it to reach forward to —
        # which is the arrangement every one of these containers ships.
        raw = (
            "Ships from Amazon.com\n"
            "Sold by ELEGOO Official US\n"
            "    .offer-display-feature-text { font-weight: 400; }"
        )
        self.assertEqual(clean_text(raw), "Ships from Amazon.com Sold by ELEGOO Official US")

    def test_a_rule_does_not_reach_backwards_past_a_line_break(self):
        # Same shape, minimal: whatever a match consumes before the brace must
        # stay on the brace's own line.
        raw = "In Stock.\n#availability { color: green; }"
        self.assertEqual(clean_text(raw), "In Stock.")

    def test_empty(self):
        self.assertEqual(clean_text(None), "")
        self.assertEqual(clean_text(""), "")

    def test_text_applies_the_cleaning(self):
        page = FakeTextPage({"#availability": self.AVAILABILITY})
        self.assertEqual(text(page, "#availability"), "Only 4 left in stock - order soon.")


class SellerSelectorsTest(unittest.TestCase):
    """Regression: B0GJ5S4V78 is new, $599, sold by Amazon.com — and was reported
    as "Sold by Amazon Resale" because the unscoped `#merchant-info` matched the
    used-offer accordion instead of the buybox."""

    # Literals, not `SELLER_SELECTORS[0]`. Deriving the fixture key from the
    # production constant makes the fixture rewrite itself to match whatever
    # production says, and the assertion degrades to `d["k"] == d["k"]` — it
    # passes just as happily for a misspelled selector as for a working one.
    BUYBOX = (
        "#buybox [offer-display-feature-name=desktop-merchant-info] "
        ".offer-display-feature-text-message"
    )
    USED_OFFER = "#merchant-info"

    def test_the_buybox_seller_wins_over_a_used_offer_block(self):
        page = FakeTextPage({
            self.BUYBOX: "Amazon.com",
            self.USED_OFFER: "Sold by Amazon Resale and Fulfilled by Amazon.",
        })
        self.assertEqual(text(page, *SELLER_SELECTORS), "Amazon.com")

    def test_a_listing_with_only_a_used_offer_reports_nothing_rather_than_it(self):
        # An unscoped `#merchant-info` here would attribute the used offer's
        # seller to the new-offer price sitting next to it in the output.
        page = FakeTextPage({self.USED_OFFER: "Sold by Amazon Resale and Fulfilled by Amazon."})
        self.assertIsNone(text(page, *SELLER_SELECTORS))

    def test_the_seller_profile_link_is_not_in_the_chain(self):
        # Its text is "Learn more about the seller", not a seller name — it was
        # winning the chain on listings that had no used offer to mis-match.
        # Confirmed live: on B0DT8PV51T the element exists and reads exactly
        # that, so restoring it to the chain would resurrect the bug.
        self.assertNotIn("#sellerProfileTriggerId", " ".join(SELLER_SELECTORS))


# --- Selector tests against real captured markup -----------------------------
#
# Everything above this line drives a dict keyed by selector string, which can
# answer "what text is at this selector?" but not "does this selector match?".
# The distinction is the whole ballgame for a selector chain: a mutation run
# that replaced all three SELLER_SELECTORS with plausible nonsense left the
# suite green, because the fixture keys were derived from the constant under
# test. Below, selectors run against HTML captured from real product pages
# through a real CSS engine, so a selector that matches nothing returns nothing.

FIXTURES = Path(__file__).with_name("fixtures")

try:
    from bs4 import BeautifulSoup

    HAVE_BS4 = True
except ImportError:  # pragma: no cover - exercised by the bare-interpreter CI job
    HAVE_BS4 = False


# Amazon's own display:none utilities. Modelled by name because that is what
# the markup carries — bs4 has no cascade, so a class list and an inline style
# are the only hiding this fake can honestly see, and inventing more would be
# the fake agreeing with us again.
#
# `a-offscreen` does NOT belong here, and it is the most plausible wrong
# addition: it is an Amazon utility class, it is invisible to a sighted user,
# and it reads as `aok-hidden`'s sibling. It is `position: absolute` with a 1px
# clip, so it *is* rendered — measured, `getClientRects().length == 1` and
# `innerText` returns its text, both directly and as a child of a rendered
# node. Every price selector in `live.py` terminates in `.a-offscreen`, so
# adding it here would return "" for every price in the fixture suite, and it
# would present as the price selectors having rotted rather than as the fake
# having changed.
# A skip reason a human reads only when confused about why a test did not
# run, so it says how to make it run rather than asserting where it is.
# "this is CI" was wrong the moment someone ran `uv run` from the repo
# root: there is no pyproject.toml there, so uv builds an empty
# environment and every one of these skips while the run reports OK.
NO_DEPS = (
    "{pkg} is not installed. The bare-interpreter CI job skips these by design; "
    "to run them use pyworker/.venv/bin/python, or `uv run` from pyworker/ — "
    "not from the repo root, which builds an empty env and skips silently."
)


HIDING_CLASSES = ("aok-hidden", "a-hidden")


def _hidden(node):
    """True if this node alone is display:none — by class, inline style, or attr.

    The `hidden` attribute is `display: none` in the UA stylesheet; measured,
    a `[hidden]` node has no layout box and a rendered parent excludes its text.
    """
    if any(c in HIDING_CLASSES for c in (node.get("class") or [])):
        return True
    if node.has_attr("hidden"):
        return True
    return "display:none" in (node.get("style") or "").replace(" ", "").lower()


def _invisible(node):
    """True if `visibility: hidden` applies here, by inline style, inherited.

    Kept apart from `_hidden` because Chrome treats the two differently and
    conflating them gets one of the cases exactly backwards. Measured:

        <div style="visibility:hidden">VIS</div>   rects=1  innerText=''
        <div class="aok-hidden">HID</div>          rects=0  innerText='HID'

    `visibility: hidden` still generates a layout box, so the node is *being
    rendered* and never reaches the textContent fallback — it contributes no
    text of its own in either position. Routing it through `_hidden` would make
    the direct case return the full text instead of "".

    `visibility` inherits and a descendant may set it back to `visible`, so the
    nearest inline declaration wins rather than the presence of any hidden
    ancestor.
    """
    for a in [node, *node.parents]:
        if not hasattr(a, "get"):
            continue
        style = (a.get("style") or "").replace(" ", "").lower()
        if "visibility:hidden" in style:
            return True
        if "visibility:visible" in style:
            return False
    return False


def _rendered(node):
    return not any(_hidden(a) for a in [node, *node.parents] if hasattr(a, "get"))


def _text_of(node):
    """Every descendant string, including <style> and <script> source.

    Not `get_text()`. bs4 sorts stylesheet and script contents into their own
    NavigableString subclasses and `get_text()` skips them by default, so the
    fixture's `<style>` block was invisible to the fake — which meant
    `without_style_nodes` had nothing to subtract and every assertion about
    CSS being stripped passed without any CSS ever being present. The test
    named for the leak could not have failed if the fix were removed.
    """
    return "".join(node.find_all(string=True))


def _rendered_text(node):
    """What a rendered node contributes: the strings that are rendered themselves.

    Walks the original tree rather than a pruned copy, because `visibility`
    inherits and a copy rooted at `node` loses the ancestors it inherits
    through. Pruning by subtree would also be wrong for visibility in a way it
    is not for `display: none` — measured, a `visibility: hidden` container
    holding a `visibility: visible` child yields that child's text and swallows
    its own, so the unit that survives is the string, not the element.
    """
    return "".join(
        t
        for t in node.find_all(string=True)
        if not any(_hidden(a) for a in t.parents if hasattr(a, "get")) and not _invisible(t)
    )


class DomLocator:
    """A Playwright-shaped locator backed by parsed HTML.

    Implements only what `browser.text()` and `browser.attr()` actually call.

    `inner_text` follows the two branches real `innerText` has, both measured
    against Chrome rather than reasoned from the spec:

      * A node that is **not being rendered** returns its full descendant text.
        That is the branch that put CSS in the output — `#availability_feature_div`
        has no layout box, so its `<style>` children came through verbatim — and
        a fake that dropped style text would make that bug untestable here.
      * A node that **is** being rendered excludes descendants that aren't. A
        hidden `<span>` inside a visible container contributes nothing.

    The distinction matters in the direction that bites: on the amazon-sold
    fixture the merchant selector matches twice, and the second is an
    `aok-hidden` popover twin. bs4's `get_text()` alone models neither branch —
    it would have reported that twin's text out of a visible container.

    Two things it deliberately does not model, both for the same reason —
    whether an element has a layout box is a live-rendering fact bs4 cannot
    know, so the fake states what the markup states and guesses in the
    direction that can only cause false *failures*:

      * A node hidden only by the cascade reads as rendered here. Parsing the
        fixtures' own `<style>` blocks for `display: none` was considered and
        measured first: between them they carry four rules, all four
        `.availabilityMoreDetailsIcon { width / vertical-align / fill }`, and
        none hides anything. It would be code no test could distinguish from
        its absence — which is the exact shape of the three inert guards this
        suite has already turned up. The rules that would matter, the accordion
        ones, live in a stylesheet the captured subtrees do not carry, so
        parsing what is here cannot reach them either.

        What that gap costs was measured rather than assumed: modelling the
        collapse pessimistically — `.a-accordion-inner` outside
        `.a-accordion-active` treated as hidden — moves exactly one assertion,
        and it did so by exposing a real defect in the unrendered branch rather
        than by disagreeing with Chrome. See
        `test_the_unrendered_branch_carries_style_text_too`. Note also that the
        prices these tests read sit in each row's `accordion-header`, which
        stays rendered in both rows; it is the row *bodies* that collapse.
      * `<style>`/`<script>` text is included in both branches, though a real
        rendered container would exclude it. `#availability_feature_div` had
        no layout box on the live page, which is why the CSS leaked at all,
        and nothing in the captured markup records that. Including it always
        keeps `without_style_nodes` under test; excluding it would restore the
        exact false pass this fake was built to end.
    """

    def __init__(self, nodes):
        self._nodes = list(nodes)

    @property
    def first(self):
        return DomLocator(self._nodes[:1])

    def nth(self, i):
        return DomLocator(self._nodes[i : i + 1])

    def count(self):
        return len(self._nodes)

    def locator(self, sel):
        return DomLocator([m for n in self._nodes for m in n.select(sel)])

    def inner_text(self):
        if not self._nodes:
            return ""
        node = self._nodes[0]
        if not _rendered(node):
            # Unrendered: innerText is specified to fall back to textContent,
            # and Chrome does — measured, including nested and <style> text:
            #
            #   <div class="aok-hidden">copy <style>.x { }</style></div>
            #   -> 'copy .x { }'
            #
            # `_text_of`, not `get_text()`, for the same reason the rendered
            # branch needs it — and it matters more here, because this branch
            # *is* the leak's mechanism. `#availability_feature_div` had no
            # layout box on the live page; that is why the CSS reached the
            # user. Using `get_text()` here would have made the one branch the
            # leak actually travels through the one branch that cannot show it.
            return _text_of(node)
        return _rendered_text(node)

    def all_text_contents(self):
        return [_text_of(n) for n in self._nodes]

    def get_attribute(self, name):
        if not self._nodes:
            return None
        value = self._nodes[0].get(name)
        # bs4 hands back a list for space-separated attributes (class, rel);
        # Playwright hands back the raw string. Code that regexes `class` to
        # find `t-action-type-CANCEL` works against Chrome and blows up against
        # a list, so the fake has to return what the browser returns.
        if isinstance(value, list):
            return " ".join(value)
        return value


class DomPage:
    """Root scope over a captured fixture."""

    def __init__(self, html):
        self._soup = BeautifulSoup(html, "html.parser")

    @classmethod
    def from_fixture(cls, name):
        return cls((FIXTURES / name).read_text(encoding="utf-8"))

    def locator(self, sel):
        return DomLocator(self._soup.select(sel))


class RealMarkupSellerTest(unittest.TestCase):
    """The seller chain, against markup captured from live product pages.

    Fixtures are pruned to the containers under test and scrubbed of the
    signed-in delivery address, but the structure — which node sits inside
    which — is exactly as Amazon served it. That structure is the claim the
    hand-written fakes could not check.
    """

    def setUp(self):
        if not HAVE_BS4:
            self.skipTest(NO_DEPS.format(pkg="beautifulsoup4"))

    def test_an_amazon_sold_listing_reports_amazon(self):
        page = DomPage.from_fixture("buybox_amazon_sold.html")
        self.assertEqual(text(page, *SELLER_SELECTORS), "Amazon.com")

    def test_a_third_party_listing_reports_the_third_party(self):
        # B0DT8PV51T. The used-offer block on this same page says "Amazon
        # Resale"; reporting that would be the original bug.
        page = DomPage.from_fixture("buybox_third_party.html")
        self.assertEqual(text(page, *SELLER_SELECTORS), "ELEGOO Official US")

    def test_normalization_is_a_no_op_on_both_captured_layouts(self):
        # The claim the SELLER_PREFIX_RE comment makes, kept honest: on the
        # markup Amazon actually serves through these two selectors the cell is
        # already a bare name, so normalize_seller is a guard against a shape no
        # current path produces. If this ever starts failing, the guard has
        # become load-bearing and the comment above it is out of date.
        for name in ("buybox_amazon_sold.html", "buybox_third_party.html"):
            raw = text(DomPage.from_fixture(name), *SELLER_SELECTORS)
            self.assertEqual(normalize_seller(raw), raw, name)

    def test_the_used_offer_block_lives_inside_the_buybox(self):
        # The fact that motivates every selector below the first, and the one
        # the PR's original comment got wrong: scoping to #buybox does NOT
        # exclude the used offer. `#merchant-info` is inside #usedAccordionRow,
        # which is inside #buybox, on both captured pages.
        for name in ("buybox_amazon_sold.html", "buybox_third_party.html"):
            page = DomPage.from_fixture(name)
            self.assertEqual(page.locator("#buybox #merchant-info").count(), 1, name)
            self.assertEqual(page.locator("#usedAccordionRow #merchant-info").count(), 1, name)
            self.assertIn(
                "Amazon Resale",
                page.locator("#buybox #merchant-info").first.inner_text(),
                name,
            )

    def test_no_selector_in_the_chain_matches_the_used_offer_block(self):
        # The guarantee that replaces "it's scoped to #buybox, so it's fine".
        for name in ("buybox_amazon_sold.html", "buybox_third_party.html"):
            page = DomPage.from_fixture(name)
            for sel in SELLER_SELECTORS:
                for matched in page.locator(sel).all_text_contents():
                    self.assertNotIn(
                        "Amazon Resale",
                        matched,
                        f"{name}: {sel} reaches the used offer",
                    )

    def test_a_bogus_selector_chain_finds_nothing(self):
        # The mutation the old suite could not survive. If this passes while
        # `test_an_amazon_sold_listing_reports_amazon` also passes, the fixture
        # is answering questions rather than echoing them.
        page = DomPage.from_fixture("buybox_amazon_sold.html")
        bogus = (
            "#buybox [offer-display-feature-name=totally-bogus-name] .not-a-real-class",
            "#buybox .tabular-buybox-text[tabular-attribute-name='Nope']",
            "#buybox #no-such-merchant-info",
        )
        self.assertIsNone(text(page, *bogus))

    def test_the_pre_fix_chain_still_gets_this_page_wrong(self):
        # Guards the regression from the other side: the chain this PR replaced
        # still returns a wrong answer against the real markup, so the tests
        # above are measuring the fix rather than the fixture.
        #
        # The wrong answer it gives is the seller-profile link boilerplate, not
        # the used-offer seller — `#sellerProfileTriggerId` comes first and wins
        # before `#merchant-info` is ever consulted. Both are wrong; asserting
        # the specific one keeps this honest about which failure it reproduces.
        page = DomPage.from_fixture("buybox_third_party.html")
        got = text(page, "#sellerProfileTriggerId", "#merchant-info", "#tabular-buybox")
        self.assertEqual(got, "Learn more about the seller")
        self.assertNotEqual(got, "ELEGOO Official US")

    def test_the_used_offer_is_what_the_pre_fix_chain_falls_back_to(self):
        # And with the boilerplate link removed, the next one down is the used
        # offer — the failure the PR is named for.
        page = DomPage.from_fixture("buybox_third_party.html")
        got = text(page, "#merchant-info", "#tabular-buybox")
        self.assertIn("Amazon Resale", got or "")


class RealMarkupReviewListingTest(unittest.TestCase):
    """The review card chain and the pagination control, against markup
    captured from /product-reviews/B09BJMY8HL.

    Two cards and the pagination bar, pruned and scrubbed of account ids; the
    nesting is exactly as Amazon served it. That nesting is the whole claim
    here — both defects this fixture pins are defects of structure, and the
    hand-written fakes match selector strings rather than resolve them, so
    neither could have caught either one.
    """

    def setUp(self):
        if not HAVE_BS4:
            self.skipTest(NO_DEPS.format(pkg="beautifulsoup4"))
        self.page = DomPage.from_fixture("review_listing.html")

    def test_titles_come_back_as_titles_and_not_as_star_ratings(self):
        cards = scrape_review_cards(self.page)
        self.assertEqual(len(cards), 2)
        self.assertEqual(
            cards[0]["title"], "Great machine, strong airflow, good looking, has digital monitor"
        )
        for c in cards:
            self.assertNotIn("out of 5 stars", c["title"] or "")

    def test_the_pre_fix_selector_reads_the_hidden_star_span_instead(self):
        # The regression from the other side. `.a-icon-alt` is the last child of
        # the `<i>` that opens the title anchor, so the descendant form matches
        # it and `text()` takes the first match in document order. Every title
        # became "5.0 out of 5 stars", which `strip_star_prefix` then emptied —
        # the field read as absent, so nothing downstream complained.
        card = self.page.locator(REVIEW_CARDS).first
        self.assertEqual(
            text(card, "[data-hook=review-title] span:last-child"), "5.0 out of 5 stars"
        )
        self.assertIsNone(
            strip_star_prefix(text(card, "[data-hook=review-title] span:last-child"))
        )

    def test_the_rest_of_the_card_reads_off_the_real_markup(self):
        first = scrape_review_cards(self.page)[0]
        self.assertEqual(first["id"], "R345KXW6QR4S6U")
        self.assertEqual(first["rating"], 5.0)
        self.assertEqual(first["date"], "2026-07-18")
        self.assertEqual(first["author"], "Mike M")
        self.assertTrue(first["verified"])
        self.assertIn("right out of the box", first["body"] or "")

    def test_the_offset_skips_the_cards_already_read(self):
        self.assertEqual(len(scrape_review_cards(self.page, start=1)), 1)
        self.assertEqual(len(scrape_review_cards(self.page, start=99)), 0)

    def test_the_show_more_button_is_the_only_pagination_the_page_offers(self):
        # The fact the URL walk was built on the absence of: this listing ships
        # no numbered pager at all, so there was never a page 2 link to follow.
        self.assertEqual(self.page.locator(SHOW_MORE_BUTTON).count(), 1)
        self.assertEqual(self.page.locator(".a-pagination").count(), 0)
        self.assertEqual(self.page.locator("li.a-last a").count(), 0)


class DomFakeFidelityTest(unittest.TestCase):
    """The fake's own tests. If it drifts from Playwright, every test built on
    it starts asserting something Amazon never does.

    Each expectation below was measured against real Chrome through Playwright
    on the equivalent markup, not derived from the spec — the two disagree in
    the case that matters most here, and it is the case with no layout box.
    """

    HTML = (
        '<div id="direct_hidden" class="aok-hidden">HIDDEN TWIN TEXT</div>'
        '<div id="visible_parent">VISIBLE TEXT'
        '  <span class="aok-hidden">HIDDEN CHILD TEXT</span></div>'
        '<div id="hidden_parent" class="aok-hidden">OUTER<span>INNER</span></div>'
        '<div id="inline" style="display: none">INLINE HIDDEN</div>'
        '<div id="offscreen_parent">SHOWN'
        '  <span class="a-offscreen">$599.00</span></div>'
        '<div id="attr_hidden" hidden>ATTR HIDDEN</div>'
        '<div id="attr_parent">SHOWN<span hidden>ATTR CHILD</span></div>'
        '<div id="vis_hidden" style="visibility: hidden">VIS HIDDEN</div>'
        '<div id="vis_parent">SHOWN'
        '  <span style="visibility: hidden">VIS CHILD</span></div>'
        '<div id="vis_restored" style="visibility: hidden">SWALLOWED'
        '  <span style="visibility: visible">RESTORED</span></div>'
        '<div id="unrendered_style" class="aok-hidden">Only 4 left in stock.'
        "  <style>.availabilityMoreDetailsIcon { width: 12px; }</style></div>"
    )

    def setUp(self):
        if not HAVE_BS4:
            self.skipTest(NO_DEPS.format(pkg="beautifulsoup4"))
        self.page = DomPage(self.HTML)

    def test_a_hidden_node_still_yields_its_own_text(self):
        # Chrome: inner_text == 'HIDDEN TWIN TEXT', NOT ''. An element with no
        # layout box is "not being rendered", and innerText then falls back to
        # textContent. Getting this backwards would make a hidden match look
        # like a dead selector, which is the opposite of what production does.
        self.assertEqual(self.page.locator("#direct_hidden").inner_text(), "HIDDEN TWIN TEXT")
        self.assertEqual(self.page.locator("#inline").inner_text(), "INLINE HIDDEN")

    def test_a_hidden_node_yields_its_descendants_too(self):
        # Same branch: the fallback is textContent, so nesting is included.
        got = self.page.locator("#hidden_parent").inner_text()
        self.assertIn("OUTER", got)
        self.assertIn("INNER", got)

    def test_a_rendered_node_drops_its_hidden_children(self):
        # The branch bs4 gets wrong on its own: get_text() would return both.
        got = self.page.locator("#visible_parent").inner_text()
        self.assertIn("VISIBLE TEXT", got)
        self.assertNotIn("HIDDEN CHILD TEXT", got)

    def test_the_style_leak_still_reproduces(self):
        # The guard on the above. `#availability_feature_div` is hidden by
        # layout, not by markup, so it reads as rendered here — which means
        # modelling hiding must not quietly start dropping <style> text and
        # take RealMarkupCleanTextTest's subject with it.
        page = DomPage.from_fixture("buybox_amazon_sold.html")
        self.assertIn("{", page.locator("#availability_feature_div").inner_text())

    def test_the_unrendered_branch_carries_style_text_too(self):
        # The branch the leak actually travels through. On the live page
        # `#availability_feature_div` had no layout box — in the captured
        # markup it sits inside a collapsed `.a-accordion-inner` — so the
        # container Amazon leaked CSS from was reached this way, not through
        # the rendered branch above. Chrome, measured:
        #
        #   inner_text == 'Only 4 left in stock. .availabilityMoreDetailsIcon { width: 12px; }'
        #
        # bs4's `get_text()` returns the copy without the rule, because it
        # skips Stylesheet strings. That would leave the leak reproducible on
        # exactly one of the two branches, and not the one it came from.
        got = self.page.locator("#unrendered_style").inner_text()
        self.assertIn("Only 4 left in stock.", got)
        self.assertIn("availabilityMoreDetailsIcon", got)

    def test_an_offscreen_price_is_rendered_text(self):
        # `.a-offscreen` is clipped, not hidden — every price selector in
        # live.py ends in it, so treating it as hidden would zero the price on
        # every fixture and read as selector rot. Chrome: rects=1 both here and
        # standalone.
        self.assertIn("$599.00", self.page.locator("#offscreen_parent").inner_text())

    def test_the_hidden_attribute_hides(self):
        # display:none from the UA stylesheet, so both branches apply: no
        # layout box of its own, and excluded from a rendered parent.
        self.assertEqual(self.page.locator("#attr_hidden").inner_text(), "ATTR HIDDEN")
        got = self.page.locator("#attr_parent").inner_text()
        self.assertIn("SHOWN", got)
        self.assertNotIn("ATTR CHILD", got)

    def test_visibility_hidden_is_not_the_same_branch_as_display_none(self):
        # The case that punishes conflating the two. It keeps its layout box,
        # so it never reaches the textContent fallback — measured as '', where
        # `display: none` on the same markup yields the full text.
        self.assertEqual(self.page.locator("#vis_hidden").inner_text(), "")
        got = self.page.locator("#vis_parent").inner_text()
        self.assertIn("SHOWN", got)
        self.assertNotIn("VIS CHILD", got)

    def test_visibility_visible_wins_back_a_subtree(self):
        # `visibility` inherits and is overridable, unlike `display: none` —
        # so the thing that survives is the string, not the element. Chrome on
        # this exact markup returns 'RESTORED': the container's own text is
        # swallowed while its visible child's comes through, which no
        # prune-the-subtree model can produce.
        got = self.page.locator("#vis_restored").inner_text()
        self.assertIn("RESTORED", got)
        self.assertNotIn("SWALLOWED", got)


class RealMarkupHiddenTwinTest(unittest.TestCase):
    """Why `.first` is the right pick for the seller, stated as evidence."""

    def setUp(self):
        if not HAVE_BS4:
            self.skipTest(NO_DEPS.format(pkg="beautifulsoup4"))

    def test_the_second_merchant_match_is_a_hidden_popover_twin(self):
        # The multi-match the old fake could not express. Both matches carry
        # the same text, and the second sits inside an aok-hidden popover
        # trigger — so `.first` is correct, and now for a checkable reason
        # rather than because the fake only ever had one node to give.
        page = DomPage.from_fixture("buybox_amazon_sold.html")
        matches = page.locator(SELLER_SELECTORS[0])
        self.assertEqual(matches.count(), 2)
        self.assertEqual(clean_text(matches.first.inner_text()), "Amazon.com")
        self.assertEqual(clean_text(matches.nth(1).inner_text()), "Amazon.com")
        self.assertTrue(_rendered(matches.first._nodes[0]))
        self.assertFalse(_rendered(matches.nth(1)._nodes[0]))


class RealMarkupCleanTextTest(unittest.TestCase):
    """The CSS leak, against the container it was actually observed in."""

    def setUp(self):
        if not HAVE_BS4:
            self.skipTest(NO_DEPS.format(pkg="beautifulsoup4"))

    def test_the_availability_container_carries_a_style_block(self):
        # If this fails the fixture has been re-captured from a page that no
        # longer inlines CSS, and the test below stops proving anything.
        page = DomPage.from_fixture("buybox_amazon_sold.html")
        styles = page.locator("#availability_feature_div style")
        self.assertGreaterEqual(styles.count(), 1)
        self.assertIn("{", styles.first.inner_text())

    def test_availability_comes_back_without_the_stylesheet(self):
        page = DomPage.from_fixture("buybox_amazon_sold.html")
        got = text(page, "#availability_feature_div")
        self.assertIsNotNone(got)
        self.assertNotIn("{", got)
        self.assertIn("left in stock", got)


class RealMarkupPriceTest(unittest.TestCase):
    """The price half of the same offer-mixing hazard.

    The seller was being read off one offer and the price off another. Fixing
    the seller left the price side reading `#corePrice_feature_div`, which on an
    accordion listing exists once per offer row.
    """

    def setUp(self):
        if not HAVE_BS4:
            self.skipTest(NO_DEPS.format(pkg="beautifulsoup4"))

    # (fixture, featured price, used-offer price)
    PAGES = (
        ("buybox_amazon_sold.html", "$599.00", "$563.36"),
        ("buybox_third_party.html", "$519.99", "$451.73"),
    )

    def test_the_unscoped_selector_really_does_reach_the_used_offer(self):
        # Establishes the hazard is real before asserting it's handled — without
        # this, the test below passes on a page where there is only one price
        # and proves nothing.
        for name, _featured, used in self.PAGES:
            page = DomPage.from_fixture(name)
            prices = [
                t.strip()
                for t in page.locator("#corePrice_feature_div .a-price .a-offscreen").all_text_contents()
            ]
            self.assertIn(used, prices, name)

    def test_the_featured_offers_price_is_the_one_reported(self):
        for name, featured, used in self.PAGES:
            page = DomPage.from_fixture(name)
            got = text(page, "[id^=newAccordionRow] .a-price .a-offscreen")
            self.assertEqual(got, featured, name)
            self.assertNotEqual(got, used, name)

    def test_price_and_seller_come_from_the_same_offer(self):
        # The invariant the whole PR is about: never pair one offer's price with
        # another's seller. Spelled out as a literal rather than built from
        # SELLER_SELECTORS, so it stays an independent statement about the page.
        seller_in_featured_row = (
            "[id^=newAccordionRow] [offer-display-feature-name=desktop-merchant-info] "
            ".offer-display-feature-text-message"
        )
        for name, _featured, _used in self.PAGES:
            page = DomPage.from_fixture(name)
            self.assertGreaterEqual(
                page.locator(seller_in_featured_row).count(),
                1,
                f"{name}: the seller is not inside the row the price is read from",
            )
