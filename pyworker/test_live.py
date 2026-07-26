"""Unit tests for the pure parsing helpers in live.py / browser.py.

Run with: python -m unittest discover -s pyworker
No Playwright needed — these functions never touch a browser.
"""

import unittest
from datetime import date

from browser import parse_money
from live import extract_asin, parse_delivery_date, _first_float, _first_int


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


if __name__ == "__main__":
    unittest.main()
