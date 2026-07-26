"""Unit tests for the pure parsing helpers in live.py / browser.py.

Run with: python -m unittest discover -s pyworker
No Playwright needed — these functions never touch a browser.
"""

import io
import json
import unittest
from contextlib import redirect_stdout
from datetime import date

import browser
from browser import (
    Blocked,
    NotLoggedIn,
    guard,
    is_signin_page,
    parse_money,
    session_rejected,
)
from live import (
    extract_asin,
    parse_delivery_date,
    _first_float,
    _first_int,
    _is_sponsored,
    _review_count,
    _warn_selector_rot,
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
        data = dict(self.FULL, seller=None, rating=None)
        self.assertEqual(emitted(lambda: _warn_selector_rot(data)), [])

    def test_three_missing_fields_warns(self):
        data = dict(self.FULL, seller=None, rating=None, image=None)
        events = emitted(lambda: _warn_selector_rot(data))
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["level"], "warn")
        self.assertIn("markup may have changed", events[0]["msg"])
        for field in ("seller", "rating", "image"):
            self.assertIn(field, events[0]["msg"])

    def test_empty_scrape_warns(self):
        events = emitted(lambda: _warn_selector_rot({}))
        self.assertEqual(len(events), 1)
        self.assertIn("6/6", events[0]["msg"])


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
