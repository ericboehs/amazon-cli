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
    clean_text,
    guard,
    is_signin_page,
    parse_money,
    session_rejected,
    text,
)
from live import (
    SELLER_SELECTORS,
    extract_asin,
    parse_delivery_date,
    parse_helpful_votes,
    parse_histogram_label,
    parse_review_country,
    parse_review_date,
    reviews_url,
    scrape_histogram,
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
        data = dict(SelectorRotTest.FULL, seller=None, rating=None, image=None)
        announced = emitted(lambda: _warn_selector_rot(dict(data)))
        self.assertEqual(degradations(data), [announced[0]["msg"]])

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
    def test_defaults_to_helpful_page_one(self):
        url = reviews_url("B0747R1M51")
        self.assertIn("/product-reviews/B0747R1M51", url)
        self.assertIn("pageNumber=1", url)
        self.assertIn("sortBy=helpful", url)

    def test_recent_sort_and_page(self):
        url = reviews_url("B0747R1M51", 3, "recent")
        self.assertIn("pageNumber=3", url)
        self.assertIn("sortBy=recent", url)

    def test_unknown_sort_falls_back_rather_than_injecting_it(self):
        self.assertIn("sortBy=helpful", reviews_url("B1", 1, "bogus"))


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
            "[data-hook=review-title] span:last-child": FakeTextLocator(text="Works great"),
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
                "[data-hook=review-title] span:last-child": FakeTextLocator(text="Old layout"),
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


class ScrapeReviewsDepthTest(unittest.TestCase):
    """Whether the walk got everything it asked Amazon for."""

    class Page:
        """Serves `pages_available` distinct review pages, then repeats.

        Amazon returns the same page over again past the end rather than
        404ing, which is the behaviour being modelled here.
        """

        def __init__(self, pages_available):
            self._pages_available = pages_available
            self._n = 0

        def locator(self, sel):
            if sel == "[data-hook=review], [data-hook=cmps-review]":
                idx = min(self._n, self._pages_available)
                return FakeCardList([
                    FakeScope(
                        {"[data-hook=reviewTitle]": FakeTextLocator(text=f"review {idx}")},
                        attrs={"id": f"customer_review-R{idx}"},
                    )
                ])
            return FakeTextLocator(count=0)

        def goto(self, *_a, **_kw):
            self._n += 1

        def wait_for_timeout(self, _ms):
            pass

    def test_a_walk_that_runs_out_early_is_reported_as_incomplete(self):
        # The real case: a 3,706-rating listing that stopped yielding new
        # reviews after page 1 of the 3 requested.
        _, walk = scrape_reviews(self.Page(pages_available=1), "B0TEST00001", pages=3)
        self.assertEqual(walk, "exhausted")

    def test_a_full_walk_is_reported_as_complete(self):
        got, walk = scrape_reviews(self.Page(pages_available=5), "B0TEST00001", pages=3)
        self.assertEqual(walk, "complete")
        self.assertEqual(len(got), 4)  # product page + 3 walked pages

    def test_asking_for_no_pages_is_a_complete_walk(self):
        # `--pages 0` got exactly the depth it requested; nothing was refused.
        _, walk = scrape_reviews(self.Page(pages_available=0), "B0TEST00001", pages=0)
        self.assertEqual(walk, "complete")


class ScrapeReviewsIdlessDedupeTest(unittest.TestCase):
    """Cards without a container id must still deduplicate.

    Dedup keyed on the id alone, and a card with no id was kept unconditionally.
    Amazon serves the same page over again past the end of the listing, so the
    same review came back once per requested page: the sample inflated, the
    "no new reviews" end-of-walk signal never fired, and the duplicate-wording
    check — which scores reviews that share phrasing as bought — was handed a
    listing's own reviews repeated verbatim. Selector drift on one attribute
    would have manufactured a maximum-confidence accusation.
    """

    class Page:
        """Every card is id-less; the same page is served every time."""

        def locator(self, sel):
            if sel == "[data-hook=review], [data-hook=cmps-review]":
                return FakeCardList([
                    FakeScope({
                        "[data-hook=reviewTitle]": FakeTextLocator(text="Works great"),
                        "[data-hook=review-date]": FakeTextLocator(
                            text="Reviewed in the United States on March 2, 2024"
                        ),
                        "[data-hook=reviewRichContentContainer]": FakeTextLocator(
                            text="Held up to a full season of use with no complaints."
                        ),
                        ".a-profile-name": FakeTextLocator(text="Dana"),
                    })
                ])
            return FakeTextLocator(count=0)

        def goto(self, *_a, **_kw):
            pass

        def wait_for_timeout(self, _ms):
            pass

    def test_the_same_id_less_review_is_not_collected_once_per_page(self):
        got, walk = scrape_reviews(self.Page(), "B0TEST00001", pages=3)
        self.assertEqual(len(got), 1)
        self.assertIsNone(got[0]["id"])
        # And with nothing new on page 1, the walk knows it has run dry rather
        # than marching through all three pages re-reading the same review.
        self.assertEqual(walk, "exhausted")

    def test_distinct_id_less_reviews_are_all_kept(self):
        # The fallback keys on content, so it must not collapse two people who
        # happened to be handed the same product.
        class Page(self.Page):
            def __init__(self):
                self._n = 0

            def locator(self, sel):
                if sel != "[data-hook=review], [data-hook=cmps-review]":
                    return FakeTextLocator(count=0)
                return FakeCardList([
                    FakeScope({
                        "[data-hook=reviewTitle]": FakeTextLocator(text="Works great"),
                        "[data-hook=review-date]": FakeTextLocator(
                            text="Reviewed in the United States on March 2, 2024"
                        ),
                        "[data-hook=reviewRichContentContainer]": FakeTextLocator(
                            text=f"Reviewer number {self._n} had a fine time with it."
                        ),
                        ".a-profile-name": FakeTextLocator(text=f"Dana {self._n}"),
                    })
                ])

            def goto(self, *_a, **_kw):
                self._n += 1

        got, walk = scrape_reviews(Page(), "B0TEST00001", pages=3)
        self.assertEqual(len(got), 4)
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
        # Braces and #hashes appear in real titles; only a selector *plus* a
        # braced body is CSS, and neither of these is that.
        for raw in ("Sold by Amazon.com", "Set of 4 {assorted} colors", "Filament #3 refill"):
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

    BUYBOX = SELLER_SELECTORS[0]
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

    def test_every_selector_is_scoped_to_the_buybox(self):
        for sel in SELLER_SELECTORS:
            self.assertTrue(sel.startswith("#buybox "), sel)

    def test_the_seller_profile_link_is_not_in_the_chain(self):
        # Its text is "Learn more about the seller", not a seller name — it was
        # winning the chain on listings that had no used offer to mis-match.
        self.assertNotIn("#sellerProfileTriggerId", " ".join(SELLER_SELECTORS))

    def test_the_tabular_layout_still_resolves(self):
        page = FakeTextPage({SELLER_SELECTORS[1]: "ELEGOO Official US"})
        self.assertEqual(text(page, *SELLER_SELECTORS), "ELEGOO Official US")
