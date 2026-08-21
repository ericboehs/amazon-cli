#!/usr/bin/env python3
"""Tests for the Subscribe & Save worker.

Run with: pyworker/.venv/bin/python -m unittest test_subscriptions -v
      or: cd pyworker && uv run python -m unittest test_subscriptions

The parsing tests run against markup captured from the signed-in
`/auto-deliveries/` pages and scrubbed of account data. Structure — which node
sits inside which — is exactly as Amazon served it, which is the part a
hand-written fake cannot check. See `DomPage` in test_live.py for why a
selector-keyed dict is not good enough here.
"""

from __future__ import annotations

import json
import unittest
from datetime import date

from browser import text
from subscriptions import (
    CLICK_TIMEOUT_MS,
    DELIVERY_CARD,
    DELIVERY_SUBSCRIPTION_CARD,
    FUTURE_DELIVERIES_KEY,
    MAX_PAGES,
    NAVIGATION_KEY,
    NEXT_DELIVERY_SELECTOR,
    PAGINATION_KEY,
    CANCEL_CONFIRM,
    CANCEL_CONSEQUENCES,
    CANCEL_DIALOG,
    CANCEL_HEADING,
    CANCEL_REASON_SELECT,
    CANCEL_SAVINGS,
    SCHEDULE_SELECTOR,
    SKIP_BUTTON,
    SUBSCRIPTION_CARD,
    SUBSCRIPTION_LIST_URL,
    CancelReasonUnknown,
    NoSuchSubscription,
    NotCancellable,
    NotSkippable,
    _cards,
    _card_by_query,
    _clickable,
    _copa_links,
    _has,
    _percent,
    _warn_selector_rot,
    available_actions,
    delivery_index,
    edit_modal_url,
    first_money,
    join_delivery_facts,
    load_all_pages,
    page_state,
    parse_epoch_date,
    parse_label_date,
    parse_schedule,
    product_image,
    _texts,
    cancel_reasons,
    cancel_subscription,
    choose_reason,
    savings_text,
    open_deliveries_tab,
    skip_delivery_item,
    verify_cancelled,
    verify_skipped,
    scrape_delivery_card,
    scrape_delivery_item,
    scrape_subscription_card,
    scrape_subscription_detail,
    sort_by_next_delivery,
)
from test_live import FIXTURES, HAVE_BS4, NO_DEPS, DomLocator, DomPage, emitted


class ParseScheduleTest(unittest.TestCase):
    def test_singular_unit_and_month(self):
        self.assertEqual(
            parse_schedule("1 unit every 1 month"),
            {
                "schedule_raw": "1 unit every 1 month",
                "quantity": 1,
                "interval_count": 1,
                "interval_unit": "month",
            },
        )

    def test_plural_units_and_weeks(self):
        parsed = parse_schedule("3 units every 2 weeks")
        self.assertEqual(parsed["quantity"], 3)
        self.assertEqual(parsed["interval_count"], 2)
        self.assertEqual(parsed["interval_unit"], "week")

    def test_six_months_is_not_read_as_six_units(self):
        # The two numbers are interchangeable to a regex that isn't anchored on
        # "every", and every subscription in the captured account is quantity 1
        # — so this is the transposition the fixtures cannot catch.
        parsed = parse_schedule("1 unit every 6 months")
        self.assertEqual(parsed["quantity"], 1)
        self.assertEqual(parsed["interval_count"], 6)

    def test_an_unparsed_phrase_keeps_the_words_and_nulls_the_numbers(self):
        parsed = parse_schedule("every so often")
        self.assertEqual(parsed["schedule_raw"], "every so often")
        self.assertIsNone(parsed["quantity"])
        self.assertIsNone(parsed["interval_count"])
        self.assertIsNone(parsed["interval_unit"])

    def test_nothing_at_all_stays_none_rather_than_empty_string(self):
        self.assertIsNone(parse_schedule(None)["schedule_raw"])
        self.assertIsNone(parse_schedule("")["schedule_raw"])


class ParseEpochDateTest(unittest.TestCase):
    def test_a_millisecond_epoch_becomes_an_iso_date(self):
        self.assertEqual(parse_epoch_date("1788332400000"), "2026-09-02")

    def test_junk_and_absence_both_yield_none(self):
        self.assertIsNone(parse_epoch_date(None))
        self.assertIsNone(parse_epoch_date(""))
        self.assertIsNone(parse_epoch_date("not-a-number"))

    def test_an_out_of_range_epoch_does_not_raise(self):
        self.assertIsNone(parse_epoch_date("9" * 30))


class HasTest(unittest.TestCase):
    def test_an_unprobeable_scope_answers_none_not_false(self):
        class Exploding:
            def locator(self, _sel):
                raise RuntimeError("execution context was destroyed")

        self.assertIsNone(_has(Exploding(), ".skip-subscription-button"))


class FixtureTest(unittest.TestCase):
    def setUp(self):
        if not HAVE_BS4:
            self.skipTest(NO_DEPS.format(pkg="beautifulsoup4"))


class SubscriptionListMarkupTest(FixtureTest):
    def setUp(self):
        super().setUp()
        self.page = DomPage.from_fixture("subscriptions_list.html")
        self.cards = _cards(self.page, SUBSCRIPTION_CARD)

    def test_every_card_in_the_list_container_is_found(self):
        self.assertEqual(len(self.cards), 3)

    def test_a_card_yields_id_title_date_and_schedule(self):
        record = scrape_subscription_card(self.cards[0])
        self.assertEqual(record["subscription_id"], "SNSD0_FIXTURESUB0000000001")
        self.assertEqual(record["title"], "Example Dishwasher Detergent Gel, Lemon, 75oz")
        self.assertEqual(record["next_delivery_label"], "September 30")
        self.assertEqual(record["schedule_raw"], "1 unit every 1 month")
        self.assertEqual(record["quantity"], 1)
        self.assertEqual(record["interval_count"], 1)
        self.assertEqual(record["interval_unit"], "month")

    def test_the_full_title_is_read_not_the_ellipsised_one(self):
        # `.a-truncate-cut` sits beside `.a-truncate-full` in the same node and
        # holds "Example Dishwasher Detergent…". Reading it would store an
        # ellipsis as part of the product's name.
        record = scrape_subscription_card(self.cards[0])
        self.assertNotIn("…", record["title"])

    def test_a_six_month_subscription_is_read_whole(self):
        record = scrape_subscription_card(self.cards[1])
        self.assertEqual(record["interval_count"], 6)
        self.assertEqual(record["interval_unit"], "month")
        self.assertEqual(record["quantity"], 1)

    def test_a_next_delivery_in_another_year_keeps_the_year(self):
        record = scrape_subscription_card(self.cards[2])
        self.assertEqual(record["next_delivery_label"], "February 3, 2027")

    def test_each_card_reports_its_own_id(self):
        ids = [scrape_subscription_card(c)["subscription_id"] for c in self.cards]
        self.assertEqual(len(set(ids)), 3)

    def test_the_pagination_cursor_is_read_from_page_state(self):
        state = page_state(self.page, PAGINATION_KEY)
        self.assertEqual(state["loadedItemCount"], 3)
        self.assertEqual(state["totalItemCount"], 7)
        self.assertIn("getSubscriptionList/page", state["url"])

    def test_an_absent_state_key_is_none_rather_than_an_error(self):
        self.assertIsNone(page_state(self.page, "no-such-key"))

    def test_the_deliveries_tab_url_is_published_by_the_list_page(self):
        # `scrape_deliveries` navigates to this rather than building a URL from
        # a scraped shipId, so its presence is load-bearing.
        nav = page_state(self.page, NAVIGATION_KEY)
        self.assertIn("auto-deliveries/ajax/", nav["mydTabUpdateAjaxData"]["ajaxUrl"])


class CopaFallbackTest(FixtureTest):
    """The label-keyed fallback for when Amazon drops its `data-cypress` hooks.

    Checked by agreement with the primary selectors on real markup: a fallback
    nothing exercises is a fallback nobody knows is broken, and this one has to
    tell two visually identical links apart.
    """

    def test_the_fallback_agrees_with_the_cypress_hooks_on_every_card(self):
        page = DomPage.from_fixture("subscriptions_list.html")
        for card in _cards(page, SUBSCRIPTION_CARD):
            primary = (text(card, NEXT_DELIVERY_SELECTOR), text(card, SCHEDULE_SELECTOR))
            self.assertEqual(_copa_links(card), primary)

    def test_it_does_not_classify_by_document_order(self):
        # The claim the comment in `_copa_links` makes: swap the two rows and
        # the answer must not swap with them. Hand-built markup, because the
        # captured page only ever renders them one way round.
        page = DomPage(
            """
            <div class="subscription-card" data-subscription-id="SNSD0_X">
              <div class="copa-ingress-container">
                <span></span>
                <a class="consumption-pattern-ingress-text">1 unit every 2 weeks</a>
              </div>
              <div class="copa-ingress-container">
                <span>Next delivery by</span>
                <a class="consumption-pattern-ingress-text">October 4</a>
              </div>
            </div>
            """
        )
        card = _cards(page, ".subscription-card")[0]
        self.assertEqual(_copa_links(card), ("October 4", "1 unit every 2 weeks"))

    def test_a_card_with_no_ingress_links_yields_two_nones(self):
        page = DomPage('<div class="subscription-card" data-subscription-id="SNSD0_X"></div>')
        card = _cards(page, ".subscription-card")[0]
        self.assertEqual(_copa_links(card), (None, None))


class RecommendationCardsAreNotSubscriptionsTest(FixtureTest):
    """`.subscription-card` is reused by the "recommended for you" carousels.

    Hand-built, and deliberately so: the captured fixture is pruned to the list
    container, so it cannot show what the selector *rejects*. This is the
    negative half of that claim.
    """

    MARKUP = """
    <div id="mysContainer">
      <div class="subscription-list-container">
        <div class="subscription-card" data-subscription-id="SNSD0_REAL">
          <span class="subscription-product-title"><span class="a-truncate-full">Real</span></span>
        </div>
      </div>
      <div class="recommendations-container">
        <div class="subscription-card">
          <span class="subscription-product-title"><span class="a-truncate-full">Suggested</span></span>
        </div>
      </div>
    </div>
    """

    def test_only_the_card_inside_the_list_container_is_collected(self):
        page = DomPage(self.MARKUP)
        rows = [scrape_subscription_card(c) for c in _cards(page, SUBSCRIPTION_CARD)]
        self.assertEqual([r["title"] for r in rows], ["Real"])

    def test_a_card_without_an_id_is_skipped_even_inside_the_container(self):
        page = DomPage(
            '<div class="subscription-list-container">'
            '<div class="subscription-card">no id</div></div>'
        )
        self.assertIsNone(scrape_subscription_card(_cards(page, ".subscription-card")[0]))


class DeliveriesMarkupTest(FixtureTest):
    def setUp(self):
        super().setUp()
        page = DomPage.from_fixture("deliveries.html")
        self.cards = [scrape_delivery_card(c) for c in _cards(page, DELIVERY_CARD)]
        self.current, self.future = self.cards

    def test_both_delivery_cards_are_found(self):
        self.assertEqual(len(self.cards), 2)

    def test_the_epoch_agrees_with_the_header_amazon_printed_beside_it(self):
        # The whole justification for reading the timestamp as UTC. If the
        # timezone assumption is wrong these two disagree by a day.
        self.assertEqual(self.current["date"], "2026-09-02")
        self.assertEqual(self.current["date_label"], "Sep 2")
        self.assertEqual(self.future["date"], "2026-09-30")
        self.assertEqual(self.future["date_label"], "September 30")

    def test_current_and_future_are_distinguished(self):
        self.assertEqual(self.current["kind"], "current")
        self.assertEqual(self.future["kind"], "future")

    def test_the_edit_deadline_is_read_from_the_current_delivery(self):
        self.assertEqual(self.current["editable_until"], "Thursday, August 27")
        self.assertEqual(self.current["editable_until_label"], "Last day to edit delivery:")

    def test_the_savings_amount_travels_with_the_label_that_explains_it(self):
        # "$1.95" on its own reads as a price. Amazon's own label is the only
        # thing on the card that says it is a saving.
        self.assertEqual(self.current["savings"], "$1.95")
        self.assertEqual(
            self.current["savings_label"], "Estimated savings for this delivery:"
        )

    def test_items_carry_prices_and_discounts(self):
        prices = [i["price"] for i in self.current["items"]]
        self.assertEqual(prices, [14.22, 11.99])
        self.assertEqual(self.current["items"][0]["discount"], "Saving 5%")

    def test_the_subtotal_is_the_sum_of_the_priced_items(self):
        self.assertEqual(self.current["subtotal"], 26.21)

    def test_a_future_delivery_reports_no_subtotal_rather_than_zero(self):
        # Amazon renders no prices on a future delivery. Summing to 0.0 would
        # present it as free.
        self.assertIsNone(self.future["subtotal"])
        self.assertTrue(self.future["items"])

    def test_only_the_current_delivery_is_skippable(self):
        self.assertTrue(all(i["skippable"] for i in self.current["items"]))
        self.assertTrue(all(i["skippable"] is False for i in self.future["items"]))

    def test_items_keep_the_subscription_id_a_later_skip_will_need(self):
        for item in self.current["items"]:
            self.assertRegex(item["subscription_id"], r"^SNS[DT]0_")

    def test_the_tiering_nudge_is_captured(self):
        self.assertIn("Add 2 more subscriptions", self.current["tiering"])

    def test_the_future_deliveries_url_is_published_by_the_deliveries_fragment(self):
        # Only the live fragment carries it; the fixture is pruned to the
        # cards, so this asserts on the constant the scraper looks for rather
        # than pretending the fixture has it.
        self.assertEqual(FUTURE_DELIVERIES_KEY, "future-delivery-list")


class ConfirmSkipMarkupTest(FixtureTest):
    """Phase 2 groundwork: the skip modal's shape, pinned before anything uses it."""

    def test_the_modal_carries_a_csrf_field_and_an_approve_button(self):
        page = DomPage.from_fixture("confirm_skip.html")
        self.assertEqual(page.locator("input[name='skip-workflow-csrf']").count(), 1)
        self.assertEqual(page.locator("#confirmSkipApprove").count(), 1)


class SelectorRotWarningTest(unittest.TestCase):
    def test_a_field_missing_from_every_row_is_reported(self):
        rows = [{"title": None, "next_delivery_label": "Sep 2", "schedule_raw": "x"}] * 3
        events = emitted(lambda: _warn_selector_rot(rows))
        self.assertEqual(len(events), 1)
        self.assertIn("no title", events[0]["msg"])
        self.assertEqual(events[0]["level"], "warn")

    def test_a_field_missing_from_only_some_rows_is_not_reported(self):
        # Amazon really does leave fields off individual cards; only a clean
        # sweep is evidence of a rotted selector.
        rows = [
            {"title": "a", "next_delivery_label": "Sep 2", "schedule_raw": "x"},
            {"title": None, "next_delivery_label": "Sep 2", "schedule_raw": "x"},
        ]
        self.assertEqual(emitted(lambda: _warn_selector_rot(rows)), [])

    def test_an_empty_list_says_nothing(self):
        self.assertEqual(emitted(lambda: _warn_selector_rot([])), [])


class FakeTrigger:
    def __init__(self, page):
        self._page = page

    @property
    def first(self):
        return self

    def count(self):
        return 1

    def is_visible(self):
        # Amazon leaves the trigger in the DOM and hides it once the list is
        # whole, which is why `_clickable` asks rather than counting.
        return self._page.has_trigger and self._page.loaded < self._page.total

    def click(self, timeout=None):
        self._page.click_timeouts.append(timeout)
        if self._page.click_raises:
            raise TimeoutError("element is not visible")
        self._page.clicks += 1
        self._page.advance()


class FakeCardList:
    def __init__(self, n, node=None):
        self._n = n
        self._node = node

    def count(self):
        return self._n

    def nth(self, i):
        return self._node if self._node is not None else i


class FakePaginatingPage:
    """A subscription list that grows by `step` cards per "show more" click.

    The state block deliberately does *not* move with it. That is what Amazon
    does — measured on the live list, one click took the DOM from 30 cards to
    59 while `loadedItemCount` still read 30 — and a fake that helpfully
    updated it is what let the first version of `load_all_pages` ship a loop
    that could never terminate.
    """

    def __init__(self, total=9, step=3, has_trigger=True, stuck=False, click_raises=False):
        self.total = total
        self.step = step
        self.loaded = step
        self.initial_loaded = step
        self.has_trigger = has_trigger
        self.stuck = stuck
        self.click_raises = click_raises
        self.clicks = 0
        self.click_timeouts = []
        self.waits = 0

    def advance(self):
        if not self.stuck:
            self.loaded = min(self.loaded + self.step, self.total)

    def locator(self, sel):
        if sel == SUBSCRIPTION_CARD:
            return FakeCardList(self.loaded)
        if sel == ".subscription-pagination-trigger":
            return FakeTrigger(self)
        if sel == 'script[type="a-state"]':
            return FakeStateScripts(self)
        raise AssertionError(f"unexpected selector {sel!r}")

    def wait_for_timeout(self, _ms):
        self.waits += 1


class FakeStateScripts:
    def __init__(self, page):
        self._page = page

    def count(self):
        return 1

    def nth(self, _i):
        return self

    def get_attribute(self, _name):
        return '{"key":"subscription-list-pagination"}'

    def all_text_contents(self):
        import json as _json

        return [
            _json.dumps(
                {
                    "loadedItemCount": self._page.initial_loaded,
                    "totalItemCount": self._page.total,
                }
            )
        ]


class LoadAllPagesTest(unittest.TestCase):
    def test_it_clicks_until_the_cards_reach_the_total(self):
        page = FakePaginatingPage(total=9, step=3)
        events = emitted(lambda: load_all_pages(page))
        self.assertEqual(page.loaded, 9)
        self.assertEqual(page.clicks, 2)
        self.assertEqual(events, [])

    def test_progress_is_counted_from_cards_not_from_the_stale_cursor(self):
        # One click loads everything, the cursor still says 3. Reading the
        # cursor here means clicking a hidden trigger until it times out.
        page = FakePaginatingPage(total=9, step=9)
        events = emitted(lambda: load_all_pages(page))
        self.assertEqual(page.clicks, 0)
        self.assertEqual(events, [])

    def test_every_click_is_bounded_by_its_own_timeout(self):
        page = FakePaginatingPage(total=9, step=3)
        load_all_pages(page)
        self.assertEqual(page.click_timeouts, [CLICK_TIMEOUT_MS, CLICK_TIMEOUT_MS])

    def test_it_does_not_click_when_everything_is_already_loaded(self):
        page = FakePaginatingPage(total=3, step=3)
        load_all_pages(page)
        self.assertEqual(page.clicks, 0)

    def test_a_hidden_trigger_is_reported_rather_than_silently_truncating(self):
        page = FakePaginatingPage(total=9, step=3, has_trigger=False)
        events = emitted(lambda: load_all_pages(page))
        self.assertEqual(page.clicks, 0)
        self.assertIn("partial list", events[0]["msg"])
        self.assertIn("3 of 9", events[0]["msg"])

    def test_a_click_that_times_out_is_reported_not_raised(self):
        page = FakePaginatingPage(total=9, step=3, click_raises=True)
        events = emitted(lambda: load_all_pages(page))
        self.assertEqual(page.clicks, 0)
        self.assertIn("would not accept a click", events[0]["msg"])

    def test_a_trigger_that_adds_nothing_stops_instead_of_spinning(self):
        page = FakePaginatingPage(total=9, step=3, stuck=True)
        events = emitted(lambda: load_all_pages(page))
        self.assertEqual(page.clicks, 1)
        self.assertIn("added no subscriptions", events[0]["msg"])

    def test_an_endless_list_stops_at_the_page_cap(self):
        # `total` never reached because the page grows by one less than it
        # claims — the shape a cursor bug would take on Amazon's side.
        page = FakePaginatingPage(total=10_000, step=1)
        events = emitted(lambda: load_all_pages(page))
        self.assertEqual(page.clicks, MAX_PAGES)
        self.assertIn(f"{MAX_PAGES} pages", events[-1]["msg"])

    def test_no_cursor_at_all_means_no_clicking(self):
        class NoState(FakePaginatingPage):
            def locator(self, sel):
                if sel == 'script[type="a-state"]':
                    return FakeCardList(0)
                return super().locator(sel)

        page = NoState(total=9, step=3)
        load_all_pages(page)
        self.assertEqual(page.clicks, 0)

    def test_a_non_numeric_total_is_treated_as_no_cursor(self):
        class JunkTotal(FakePaginatingPage):
            def locator(self, sel):
                if sel == 'script[type="a-state"]':
                    return JunkStateScripts()
                return super().locator(sel)

        page = JunkTotal(total=9, step=3)
        load_all_pages(page)
        self.assertEqual(page.clicks, 0)


class JunkStateScripts(FakeStateScripts):
    def __init__(self):  # noqa: D107
        pass

    def all_text_contents(self):
        return ['{"totalItemCount": "lots"}']


class ClickableTest(unittest.TestCase):
    def test_an_unprobeable_trigger_is_not_clickable(self):
        class Exploding:
            def count(self):
                raise RuntimeError("execution context was destroyed")

        self.assertFalse(_clickable(Exploding()))


class PageStateFailureTest(unittest.TestCase):
    def test_a_scope_that_cannot_be_probed_yields_none(self):
        class Exploding:
            def locator(self, _sel):
                raise RuntimeError("execution context was destroyed")

        self.assertIsNone(page_state(Exploding(), PAGINATION_KEY))

    def test_unparseable_state_is_skipped_not_raised(self):
        page = DomPage(
            '<script type="a-state" data-a-state=\'{"key":"k"}\'>not json</script>'
        ) if HAVE_BS4 else None
        if page is None:
            self.skipTest(NO_DEPS.format(pkg="beautifulsoup4"))
        self.assertIsNone(page_state(page, "k"))

    def test_state_that_is_not_an_object_is_skipped(self):
        if not HAVE_BS4:
            self.skipTest(NO_DEPS.format(pkg="beautifulsoup4"))
        page = DomPage('<script type="a-state" data-a-state=\'{"key":"k"}\'>[1,2]</script>')
        self.assertIsNone(page_state(page, "k"))


if __name__ == "__main__":
    unittest.main()


class ParseLabelDateTest(unittest.TestCase):
    TODAY = date(2026, 8, 21)

    def test_a_bare_month_and_day_infer_the_year(self):
        self.assertEqual(parse_label_date("September 30", self.TODAY), "2026-09-30")

    def test_a_month_already_past_rolls_into_next_year(self):
        self.assertEqual(parse_label_date("January 5", self.TODAY), "2027-01-05")

    # The reason this function exists rather than calling live's parser
    # directly: inference caps out at twelve months, and the list prints a year
    # exactly when the date is further out than that.
    def test_an_explicit_year_beats_inference(self):
        self.assertEqual(parse_label_date("March 3, 2029", self.TODAY), "2029-03-03")

    def test_an_explicit_year_that_agrees_with_inference_still_parses(self):
        self.assertEqual(parse_label_date("March 3, 2027", self.TODAY), "2027-03-03")

    def test_a_weekday_prefix_is_ignored(self):
        self.assertEqual(parse_label_date("Wednesday, September 30", self.TODAY), "2026-09-30")

    def test_an_impossible_date_is_none_not_a_crash(self):
        self.assertIsNone(parse_label_date("February 31, 2027", self.TODAY))

    def test_nothing_in_nothing_out(self):
        self.assertIsNone(parse_label_date(None, self.TODAY))
        self.assertIsNone(parse_label_date("sometime soon", self.TODAY))


class FirstMoneyTest(unittest.TestCase):
    # Amazon renders the amount twice inside `.a-price` — once for screen
    # readers — so the element's text is "$12.34$12.34" and a straight
    # parse_money returns None.
    def test_a_doubled_amount_yields_one_number(self):
        self.assertEqual(first_money("You have saved $12.34$12.34 on this!"), 12.34)

    def test_thousands_separators_survive(self):
        self.assertEqual(first_money("$1,234.56"), 1234.56)

    def test_no_money_is_none(self):
        self.assertIsNone(first_money("free"))
        self.assertIsNone(first_money(None))


class PercentTest(unittest.TestCase):
    def test_it_reads_the_discount_out_of_the_sentence(self):
        self.assertEqual(_percent("Get it now with 15% off"), 15)

    def test_no_percent_is_none(self):
        self.assertIsNone(_percent("Get it now"))
        self.assertIsNone(_percent(None))


class DeliveryJoinTest(unittest.TestCase):
    def cards(self):
        return [
            {
                "date": "2026-09-02",
                "items": [
                    {"subscription_id": "A", "price": 14.22, "price_raw": "$14.22",
                     "discount": "Saving 5%"},
                ],
            },
            {
                "date": "2026-09-30",
                "items": [
                    # A recurs later; the earlier card is the one that answers
                    # "what happens next".
                    {"subscription_id": "A", "price": None, "price_raw": None,
                     "discount": "Saving 15%"},
                    {"subscription_id": "B", "price": None, "price_raw": None,
                     "discount": "Saving 10%"},
                ],
            },
        ]

    def test_the_index_keeps_the_earliest_delivery_for_each_subscription(self):
        index = delivery_index(self.cards())
        self.assertEqual(index["A"]["next_delivery_date"], "2026-09-02")
        self.assertEqual(index["A"]["price"], 14.22)
        self.assertEqual(index["B"]["next_delivery_date"], "2026-09-30")

    def test_items_without_an_id_are_skipped(self):
        index = delivery_index([{"date": "2026-09-02", "items": [{"price": 1.0}]}])
        self.assertEqual(index, {})

    def test_a_card_with_no_items_key_does_not_explode(self):
        self.assertEqual(delivery_index([{"date": "2026-09-02"}]), {})

    def test_the_join_attaches_price_discount_and_a_real_date(self):
        rows = [{"subscription_id": "A", "next_delivery_label": "September 2"}]
        join_delivery_facts(rows, self.cards())
        self.assertEqual(rows[0]["price"], 14.22)
        self.assertEqual(rows[0]["discount"], "Saving 5%")
        self.assertEqual(rows[0]["next_delivery_date"], "2026-09-02")

    # The card's own label has no year. Preferring the delivery's timestamp is
    # what makes "September 30" sortable against "March 3, 2027".
    def test_the_delivery_date_wins_over_the_parsed_label(self):
        rows = [{"subscription_id": "A", "next_delivery_label": "September 30"}]
        join_delivery_facts(rows, self.cards())
        self.assertEqual(rows[0]["next_delivery_date"], "2026-09-02")

    # A subscription that is not in any upcoming delivery still has to sort.
    def test_an_unmatched_row_falls_back_to_its_label(self):
        rows = [{"subscription_id": "ZZZ", "next_delivery_label": "March 3, 2029"}]
        join_delivery_facts(rows, self.cards())
        self.assertIsNone(rows[0]["price"])
        self.assertIsNone(rows[0]["discount"])
        self.assertEqual(rows[0]["next_delivery_date"], "2029-03-03")

    def test_an_unmatched_row_with_an_unreadable_label_gets_no_date(self):
        rows = [{"subscription_id": "ZZZ", "next_delivery_label": None}]
        join_delivery_facts(rows, [])
        self.assertIsNone(rows[0]["next_delivery_date"])


class SortByNextDeliveryTest(unittest.TestCase):
    def test_soonest_first(self):
        rows = [
            {"next_delivery_date": "2027-03-03", "title": "c"},
            {"next_delivery_date": "2026-09-02", "title": "a"},
            {"next_delivery_date": "2026-09-30", "title": "b"},
        ]
        sort_by_next_delivery(rows)
        self.assertEqual([r["title"] for r in rows], ["a", "b", "c"])

    def test_same_day_ties_break_on_title(self):
        rows = [
            {"next_delivery_date": "2026-09-02", "title": "Zinc"},
            {"next_delivery_date": "2026-09-02", "title": "apples"},
        ]
        sort_by_next_delivery(rows)
        self.assertEqual([r["title"] for r in rows], ["apples", "Zinc"])

    # An unreadable date is a scraping failure, not a delivery in 1970.
    def test_undated_rows_sort_last(self):
        rows = [
            {"next_delivery_date": None, "title": "unknown"},
            {"next_delivery_date": "2027-03-03", "title": "later"},
        ]
        sort_by_next_delivery(rows)
        self.assertEqual([r["title"] for r in rows], ["later", "unknown"])

    def test_a_row_with_no_title_still_sorts(self):
        rows = [{"next_delivery_date": "2026-09-02"}, {"next_delivery_date": "2026-09-01"}]
        sort_by_next_delivery(rows)
        self.assertEqual(rows[0]["next_delivery_date"], "2026-09-01")


@unittest.skipUnless(HAVE_BS4, NO_DEPS.format(pkg="beautifulsoup4"))
class SubscriptionDetailFixtureTest(unittest.TestCase):
    """The edit modal, against markup captured from a real one."""

    def setUp(self):
        self.page = DomPage.from_fixture("subscription_detail.html")
        self.detail = scrape_subscription_detail(self.page)

    def test_the_product_and_its_asin(self):
        self.assertEqual(self.detail["title"], "Example Dishwasher Detergent Gel, Lemon, 75oz")
        self.assertEqual(self.detail["asin"], "B000FIXTUR")
        self.assertIn("00FIXTUREIMG", self.detail["image"])

    # The href is `/dp/…` in lower case. Upper-casing the URL before matching
    # breaks the needle, not just the ASIN, and the pattern still looks right.
    def test_the_asin_survives_a_lower_case_dp_path(self):
        self.assertEqual(self.detail["asin"], "B000FIXTUR")

    def test_the_seller_drops_amazons_own_label(self):
        self.assertEqual(self.detail["merchant"], "Amazon.com and top rated sellers")

    def test_the_next_delivery_keeps_its_weekday_and_gains_a_date(self):
        self.assertEqual(self.detail["next_delivery_label"], "Wednesday, September 30")
        self.assertEqual(self.detail["next_delivery_date"][5:], "09-30")
        self.assertIn("arrive by", self.detail["next_delivery_prefix"])

    def test_the_discount_is_kept_as_words_and_as_a_number(self):
        self.assertEqual(self.detail["discount_now"], "Get it now with 5% off")
        self.assertEqual(self.detail["discount_percent"], 5)

    def test_the_schedule_parses(self):
        self.assertEqual(self.detail["schedule_raw"], "1 unit every 1 month")
        self.assertEqual(self.detail["quantity"], 1)
        self.assertEqual(self.detail["interval_count"], 1)
        self.assertEqual(self.detail["interval_unit"], "month")

    # "$12.34" here is what the subscription has saved since it started. The
    # modal has no price at all, and this is the number most likely to be
    # mistaken for one.
    def test_the_dollar_figure_is_lifetime_savings(self):
        self.assertEqual(self.detail["lifetime_savings"], 12.34)
        self.assertIn("You have saved", self.detail["lifetime_savings_text"])

    # Amazon prints its placeholder in the same slot as a real backup product.
    def test_no_backup_item_reports_none_not_the_placeholder(self):
        self.assertIsNone(self.detail["backup_item"])

    def test_the_offered_actions_are_recorded(self):
        self.assertIn("CANCEL", self.detail["actions"])
        self.assertIn("CHANGE_QUANTITY_FREQUENCY", self.detail["actions"])

    def test_the_tier_level_comes_through(self):
        self.assertEqual(self.detail["tier_level"], "BASE")

    # Both render in this modal. Neither belongs in the output.
    def test_no_address_or_payment_method_leaks_into_the_record(self):
        blob = json.dumps(self.detail).lower()
        for leak in ("example st", "exampletown", "store card", "ending in"):
            self.assertNotIn(leak, blob)


@unittest.skipUnless(HAVE_BS4, NO_DEPS.format(pkg="beautifulsoup4"))
class EditModalUrlTest(unittest.TestCase):
    def card(self):
        page = DomPage.from_fixture("subscriptions_list.html")
        return _cards(page, SUBSCRIPTION_CARD)[0]

    def test_it_reads_the_url_the_card_publishes(self):
        url = edit_modal_url(self.card())
        self.assertIn("ajax/subscription?", url)
        self.assertIn("subscriptionId=", url)

    # The same card publishes a consumptionPattern modal too; picking by
    # position instead of by name opens the schedule editor.
    def test_it_picks_the_edit_modal_and_not_the_first_modal_on_the_card(self):
        self.assertNotIn("consumptionPattern", edit_modal_url(self.card()))

    def test_a_card_with_no_modal_payload_yields_none(self):
        page = DomPage('<div class="subscription-card" data-subscription-id="A"></div>')
        self.assertIsNone(edit_modal_url(page))

    def test_junk_in_the_payload_is_skipped_not_raised(self):
        page = DomPage("<div data-a-modal='not json'></div>")
        self.assertIsNone(edit_modal_url(page))


@unittest.skipUnless(HAVE_BS4, NO_DEPS.format(pkg="beautifulsoup4"))
class FindByQueryTest(unittest.TestCase):
    def page(self):
        return DomPage.from_fixture("subscriptions_list.html")

    def test_a_unique_word_finds_one_card(self):
        card = _card_by_query(self.page(), "dishwasher")
        self.assertEqual(card.get_attribute("data-subscription-id"), "SNSD0_FIXTURESUB0000000001")

    def test_matching_is_case_insensitive(self):
        self.assertIsNotNone(_card_by_query(self.page(), "DISHWASHER"))

    def test_nothing_matching_is_none(self):
        self.assertIsNone(_card_by_query(self.page(), "helicopter"))

    def test_an_empty_query_matches_nothing_rather_than_everything(self):
        self.assertIsNone(_card_by_query(self.page(), "   "))

    # Picking the first of several is the failure that survives longest: you
    # read one subscription's details and cancel a different one.
    def test_an_ambiguous_query_raises_and_names_the_candidates(self):
        with self.assertRaises(NoSuchSubscription) as ctx:
            _card_by_query(self.page(), "example")
        msg = str(ctx.exception)
        self.assertIn("subscriptions match", msg)
        self.assertIn("pass the subscription id", msg)


class AvailableActionsTest(unittest.TestCase):
    def test_action_types_are_read_off_the_class_names(self):
        if not HAVE_BS4:
            self.skipTest(NO_DEPS.format(pkg="beautifulsoup4"))
        page = DomPage(
            '<a class="actionLink t-action-type-CANCEL"></a>'
            '<a class="actionLink t-action-type-SWITCH_PRODUCT"></a>'
            '<a class="actionLink t-action-type-CANCEL"></a>'
        )
        self.assertEqual(available_actions(page), ["CANCEL", "SWITCH_PRODUCT"])

    def test_a_node_that_cannot_be_read_is_skipped(self):
        class Exploding:
            def get_attribute(self, _name):
                raise RuntimeError("detached")

        class Page:
            def locator(self, _sel):
                return FakeCardList(1, node=Exploding())

        self.assertEqual(available_actions(Page()), [])


class ProductImageTest(FixtureTest):
    """The lazy-load trap, against markup that carries it.

    Amazon defers everything below the fold: `src` holds a 35-byte grey pixel
    and the photograph waits in data-a-hires. Both are strings ending in a
    plausible image filename, so reading `src` produces JSON that looks
    complete and renders a row of grey smudges.
    """

    def test_a_lazy_loaded_card_yields_the_photo_not_the_grey_pixel(self):
        page = DomPage.from_fixture("deliveries.html")
        node = _cards(page, DELIVERY_CARD)[0].locator(DELIVERY_SUBSCRIPTION_CARD).nth(0)
        # The captured markup has to still contain the trap, or this test
        # passes by describing markup Amazon no longer serves.
        self.assertIn("grey-pixel", node.locator("img.sns-product-image").get_attribute("src"))

        url = scrape_delivery_item(node)["image"]
        self.assertIsNotNone(url)
        self.assertNotIn("grey-pixel", url)
        self.assertIn("media-amazon.com/images/", url)

    def test_an_eagerly_loaded_card_yields_its_photo(self):
        page = DomPage.from_fixture("subscriptions_list.html")
        record = scrape_subscription_card(_cards(page, SUBSCRIPTION_CARD)[0])
        self.assertIn("00FIXTUREIMG", record["image"])
        self.assertNotIn("grey-pixel", record["image"])

    def test_the_detail_modal_yields_its_photo(self):
        page = DomPage.from_fixture("subscription_detail.html")
        self.assertIn("00FIXTUREIMG", scrape_subscription_detail(page)["image"])


class ProductImageFallbackTest(unittest.TestCase):
    class FakeImg:
        def __init__(self, attrs):
            self.attrs = attrs

        def locator(self, _sel):
            return self

        @property
        def first(self):
            return self

        def count(self):
            return 1 if self.attrs else 0

        def get_attribute(self, name):
            return self.attrs.get(name)

    def image(self, attrs, *selectors):
        return product_image(self.FakeImg(attrs), *(selectors or ("img",)))

    def test_the_hires_copy_wins(self):
        url = self.image({"data-a-hires": "hi.jpg", "data-src": "mid.jpg", "src": "low.jpg"})
        self.assertEqual(url, "hi.jpg")

    def test_it_falls_through_to_data_src_then_src(self):
        self.assertEqual(self.image({"data-src": "mid.jpg", "src": "low.jpg"}), "mid.jpg")
        self.assertEqual(self.image({"src": "low.jpg"}), "low.jpg")

    def test_a_card_with_only_placeholders_reports_nothing(self):
        attrs = {"data-a-hires": "grey-pixel.gif", "src": "transparent-pixel.png"}
        self.assertIsNone(self.image(attrs))

    def test_a_card_with_no_image_at_all_reports_nothing(self):
        self.assertIsNone(self.image({}))

    # Amazon's own "no image available" graphic is an answer, not a loading
    # artifact: it is what the account actually shows for that subscription.
    # Suppressing it here would make a subscription with no photo
    # indistinguishable from a scrape that failed.
    def test_the_no_image_graphic_is_passed_through(self):
        url = self.image({"src": "https://m.media-amazon.com/images/G/01/sns/no-img._CB44_.png"})
        self.assertIn("no-img", url)


if HAVE_BS4:  # pragma: no branch - mirrors test_live's own import guard
    from bs4 import BeautifulSoup


class SkipLocator(DomLocator):
    """A DomLocator that can be clicked, wired to a page that reacts.

    Subclassing rather than hand-writing a selector-keyed dict, for the reason
    the module docstring gives: the skip flow's whole risk is *which node sits
    inside which* — the Skip button belongs to one item card out of three, and
    a dict keyed by selector would answer the same node for all of them and
    prove nothing. Here the click lands on a node from the captured markup, and
    the page decides what that means.
    """

    def __init__(self, nodes, page=None):
        super().__init__(nodes)
        self._page = page

    @property
    def first(self):
        return SkipLocator(self._nodes[:1], self._page)

    def nth(self, i):
        return SkipLocator(self._nodes[i : i + 1], self._page)

    def locator(self, sel):
        return SkipLocator([m for n in self._nodes for m in n.select(sel)], self._page)

    def is_visible(self):
        return bool(self._nodes)

    def click(self, timeout=None):
        if not self._nodes:
            raise AssertionError("clicked an empty locator")
        self._page.clicked(self._nodes[0], timeout)


class SkipPage(DomPage):
    """The deliveries view, as a page that can be clicked through.

    Models three transitions and nothing else: the deliveries tab loads the
    delivery cards, a Skip button opens Amazon's confirmation markup, and
    approving it removes the item from the delivery. The last one is the
    important one — it is what `verify_skipped` re-reads, so a bug that reports
    success without checking has somewhere to show up.
    """

    TAB_HTML = '<a href="/auto-deliveries/?ref_=myd_nav_op_D">DELIVERIES</a>'

    def __init__(self, *, approve_removes=True, tab=True, deliveries=None):
        html = self.TAB_HTML if tab else ""
        super().__init__(f'<div id="root">{html}</div>')
        self._deliveries = deliveries
        self._approve_removes = approve_removes
        self.clicks = []
        self.gotos = []
        self.waits = []
        self.skipped_ids = set()

    # -- page surface -------------------------------------------------
    def locator(self, sel):
        return SkipLocator(self._soup.select(sel), self)

    def goto(self, url, **_kw):
        self.gotos.append(url)

    def wait_for_selector(self, sel, timeout=None):
        self.waits.append(sel)
        if not self._soup.select(sel):
            raise TimeoutError(f"no {sel}")

    def wait_for_timeout(self, _ms):
        pass

    # -- transitions --------------------------------------------------
    def load_deliveries(self):
        html = self._deliveries
        if html is None:
            html = (FIXTURES / "deliveries.html").read_text(encoding="utf-8")
        for card in BeautifulSoup(html, "html.parser").select(DELIVERY_CARD):
            self._soup.select_one("#root").append(card)

    def clicked(self, node, timeout):
        classes = " ".join(node.get("class") or [])
        # Id first: Amazon hangs #confirmSkipApprove on a span that also
        # carries three a-button classes, and recording the classes would make
        # "did we press approve?" unanswerable from the log.
        self.clicks.append((node.name, node.get("id") or classes, timeout))
        if node.name == "a":
            self.load_deliveries()
        elif "skip-subscription-button" in classes:
            self._open_modal(node)
        elif node.get("id") == "confirmSkipApprove":
            self._approve()

    def _open_modal(self, button):
        card = button.find_parent(class_="subscription-card")
        self._pending = card.get("data-subscription-id") if card else None
        modal = (FIXTURES / "confirm_skip.html").read_text(encoding="utf-8")
        self._soup.select_one("#root").append(
            BeautifulSoup(modal, "html.parser").select_one(".confirm-skip-container")
        )

    def _approve(self):
        self._soup.select_one(".confirm-skip-container").decompose()
        self.skipped_ids.add(self._pending)
        if not self._approve_removes:
            return
        for card in self._soup.select(
            f'{DELIVERY_SUBSCRIPTION_CARD}[data-subscription-id="{self._pending}"]'
        ):
            card.decompose()


class OpenDeliveriesTabTest(unittest.TestCase):
    def setUp(self):
        if not HAVE_BS4:
            self.skipTest(NO_DEPS.format(pkg="beautifulsoup4"))

    def test_it_clicks_the_tab_rather_than_following_its_href(self):
        # Measured on the live account: navigating to that href renders the
        # React hub, which contains zero delivery cards. Clicking loads all
        # seven of them; the fixture carries two.
        page = SkipPage()
        open_deliveries_tab(page)
        self.assertEqual(page.locator(DELIVERY_CARD).count(), 2)
        self.assertEqual(page.gotos, [SUBSCRIPTION_LIST_URL])
        self.assertEqual([c[0] for c in page.clicks], ["a"])

    def test_a_missing_tab_is_an_error_and_not_an_empty_list(self):
        with self.assertRaises(RuntimeError) as e:
            open_deliveries_tab(SkipPage(tab=False))
        self.assertIn("deliveries tab", str(e.exception))

    def test_a_tab_that_renders_nothing_is_an_error_too(self):
        page = SkipPage(deliveries="")
        with self.assertRaises(RuntimeError) as e:
            open_deliveries_tab(page)
        self.assertIn("never rendered", str(e.exception))


class SkipDeliveryItemTest(unittest.TestCase):
    """The whole flow, against the captured deliveries and modal markup."""

    def setUp(self):
        if not HAVE_BS4:
            self.skipTest(NO_DEPS.format(pkg="beautifulsoup4"))
        self.page = SkipPage()

    def skip(self, target=None, sub_id=None, confirm=False):
        return skip_delivery_item(self.page, sub_id, target, confirm)

    def test_a_dry_run_opens_the_dialog_and_agrees_to_nothing(self):
        result = self.skip("Dishwasher")
        self.assertFalse(result["confirmed"])
        self.assertIsNone(result["verified"])
        self.assertEqual(result["heading"], "Skip your September 2 delivery")
        # Amazon's warning, carried through verbatim: "skip" sounds free and
        # this is the sentence that says it might not be.
        self.assertIn("lose applied coupons", result["warning"])
        self.assertNotIn("confirmSkipApprove", [c[1] for c in self.page.clicks])
        self.assertEqual(self.page.skipped_ids, set())

    def test_the_dialog_reports_whether_amazon_rendered_the_form_we_know(self):
        self.assertTrue(self.skip("Dishwasher")["has_csrf"])

    def test_confirming_clicks_approve_and_verifies_by_re_reading(self):
        result = self.skip("Dishwasher", confirm=True)
        self.assertTrue(result["confirmed"])
        self.assertTrue(result["verified"])
        self.assertIn("confirmSkipApprove", [c[1] for c in self.page.clicks])
        # Re-read, not remembered: the list was loaded a second time.
        self.assertEqual(self.page.gotos.count(SUBSCRIPTION_LIST_URL), 2)

    def test_an_item_still_in_the_delivery_afterwards_is_reported_as_such(self):
        # Amazon's dialog closes on failure exactly as it does on success, so
        # this is the only signal there is, and it must not read as success.
        self.page = SkipPage(approve_removes=False)
        result = self.skip("Dishwasher", confirm=True)
        self.assertTrue(result["confirmed"])
        self.assertIs(result["verified"], False)

    def test_a_verification_that_cannot_be_made_is_none_and_not_false(self):
        page = SkipPage()
        open_deliveries_tab(page)
        page.load_deliveries = lambda: (_ for _ in ()).throw(RuntimeError("network"))
        self.assertIsNone(verify_skipped(page, "SNSD0_FIXTURESUB0000000001"))

    def test_it_reports_which_delivery_and_which_item(self):
        result = self.skip("Dishwasher")
        self.assertTrue(result["subscription_id"].startswith("SNS"))
        self.assertEqual(result["delivery_date"], "2026-09-02")
        self.assertEqual(result["delivery_label"], "Sep 2")

    def test_an_id_that_is_not_in_the_next_delivery_says_so(self):
        with self.assertRaises(NoSuchSubscription) as e:
            self.skip(sub_id="SNSD0_NOTINTHISBOX00000000")
        self.assertIn("not in the next delivery", str(e.exception))

    def test_an_ambiguous_search_refuses_to_pick_one(self):
        # The stakes here are why: `show` guessing wrong wastes a glance,
        # skipping the wrong item means something you needed doesn't arrive.
        with self.assertRaises(NoSuchSubscription) as e:
            self.skip("Example")
        self.assertIn("match", str(e.exception))
        self.assertEqual(self.page.skipped_ids, set())

    # "Laundry" is a real subscription on this fixture — in the *future*
    # delivery, where there is nothing to skip yet. The nearest miss there is,
    # and the reason the message lists the box's contents rather than saying
    # no such thing exists.
    def test_a_search_that_matches_a_later_delivery_lists_what_is_in_this_one(self):
        with self.assertRaises(NoSuchSubscription) as e:
            self.skip("Laundry")
        self.assertIn("It holds:", str(e.exception))
        self.assertIn("Dishwasher", str(e.exception))

    def test_a_delivery_with_nothing_skippable_is_not_a_failure_of_ours(self):
        html = (FIXTURES / "deliveries.html").read_text(encoding="utf-8")
        soup = BeautifulSoup(html, "html.parser")
        for btn in soup.select(SKIP_BUTTON):
            btn.decompose()
        with self.assertRaises(NotSkippable) as e:
            skip_delivery_item(SkipPage(deliveries=str(soup)), None, "Dishwasher", False)
        self.assertIn("last day to edit", str(e.exception))

    def test_no_current_delivery_at_all_is_the_same_kind_of_refusal(self):
        html = (FIXTURES / "deliveries.html").read_text(encoding="utf-8")
        soup = BeautifulSoup(html, "html.parser")
        for card in soup.select(f"{DELIVERY_CARD}[data-delivery-type='current']"):
            card.decompose()
        with self.assertRaises(NotSkippable) as e:
            skip_delivery_item(SkipPage(deliveries=str(soup)), None, "Dishwasher", False)
        self.assertIn("nothing to skip", str(e.exception))

    def test_an_empty_search_is_refused_before_anything_is_clicked(self):
        with self.assertRaises(NoSuchSubscription):
            self.skip("   ")
        self.assertEqual(self.page.skipped_ids, set())

    def test_only_the_current_delivery_offers_anything_to_skip(self):
        # Future deliveries have no Skip button in the markup Amazon serves —
        # there is nothing to skip until a box is being assembled. Asserted so
        # that a future scraper change that starts finding them is noticed.
        page = SkipPage()
        open_deliveries_tab(page)
        for card in page.locator(DELIVERY_CARD)._nodes:
            buttons = card.select(SKIP_BUTTON)
            if card.get("data-delivery-type") == "current":
                self.assertTrue(buttons)
            else:
                self.assertEqual(buttons, [])


class CancelReasonsTest(unittest.TestCase):
    """The reason dropdown, read off the captured cancellation page."""

    def setUp(self):
        if not HAVE_BS4:
            self.skipTest(NO_DEPS.format(pkg="beautifulsoup4"))
        self.page = DomPage.from_fixture("cancel_subscription.html")
        self.reasons = cancel_reasons(self.page)

    def test_it_reads_every_reason_amazon_offers(self):
        self.assertEqual(len(self.reasons), 8)
        self.assertIn("stopped_using", [r["key"] for r in self.reasons])

    # The prompt option has an empty value and is not a reason; sending it
    # would be sending the string "Select reason for cancellation".
    def test_the_placeholder_is_not_a_reason(self):
        self.assertNotIn("", [r["value"] for r in self.reasons])
        labels = [r["label"] for r in self.reasons]
        self.assertNotIn("Select reason for cancellation", labels)

    # Keys are the memorable tail of a 56-character value. Hard-coding the
    # whole string would also hard-code Amazon's internal naming.
    def test_keys_are_the_tail_of_amazons_value(self):
        r = next(r for r in self.reasons if r["key"] == "accident")
        self.assertTrue(r["value"].startswith("SnS_MYD_SnsCancelReason_"))
        self.assertTrue(r["value"].endswith("accident"))

    def test_no_reason_asked_for_means_none_is_sent(self):
        self.assertIsNone(choose_reason(self.reasons, None))
        self.assertIsNone(choose_reason(self.reasons, ""))

    def test_a_key_resolves_to_the_option_value(self):
        self.assertTrue(choose_reason(self.reasons, "accident").endswith("accident"))

    def test_hyphens_are_forgiven(self):
        self.assertEqual(
            choose_reason(self.reasons, "stopped-using"),
            choose_reason(self.reasons, "stopped_using"),
        )

    def test_the_full_label_works_too(self):
        value = choose_reason(self.reasons, "I no longer use this product")
        self.assertTrue(value.endswith("stopped_using"))

    # Silently sending no reason would be a worse answer than an error: the
    # user asked to say something specific and would never learn it wasn't
    # said.
    def test_an_unknown_reason_is_refused_and_lists_the_real_ones(self):
        with self.assertRaises(CancelReasonUnknown) as e:
            choose_reason(self.reasons, "too_many_cats")
        self.assertIn("no_more_needed", str(e.exception))


class CancelPageTest(unittest.TestCase):
    """What the cancellation page says, before anyone agrees to it."""

    def setUp(self):
        if not HAVE_BS4:
            self.skipTest(NO_DEPS.format(pkg="beautifulsoup4"))
        self.page = DomPage.from_fixture("cancel_subscription.html")

    def test_the_heading_is_amazons_question(self):
        self.assertEqual(text(self.page, CANCEL_HEADING), "Cancel your subscription?")

    # The two consequences are the whole reason the dry run exists. The second
    # is the one that surprises people: cancelling also cancels the order in
    # the box that is being assembled right now.
    def test_it_reads_back_what_cancelling_costs(self):
        said = _texts(self.page, CANCEL_CONSEQUENCES)
        self.assertIn("You will no longer receive your Subscribe & Save discount.", said)
        self.assertTrue(any("haven't yet entered the delivery process" in s for s in said))

    def test_the_savings_banner_is_carried_through(self):
        self.assertIn("$16.92", savings_text(self.page, CANCEL_SAVINGS))

    # The screen-reader copy of the amount is not a second amount. Shown to a
    # user, "You have saved $16.92 $16.92 on this subscription!" reads as a
    # rendering bug, which is what it is.
    def test_the_screen_reader_duplicate_is_not_printed_twice(self):
        said = savings_text(self.page, CANCEL_SAVINGS)
        self.assertEqual(said.count("$16.92"), 1)
        self.assertEqual(said, "You have saved $16.92 on this subscription!")

    def test_the_same_banner_on_the_detail_page_is_deduped_too(self):
        detail = DomPage.from_fixture("subscription_detail.html")
        self.assertEqual(savings_text(detail, CANCEL_SAVINGS).count("$12.34"), 1)

    def test_a_banner_that_is_not_there_stays_none(self):
        self.assertIsNone(savings_text(DomPage("<div></div>"), CANCEL_SAVINGS))

    def test_the_confirm_button_is_where_we_think_it_is(self):
        self.assertEqual(self.page.locator(CANCEL_CONFIRM).count(), 1)


class CancelPage(SkipPage):
    """The cancel flow: a list to resolve the target, then Amazon's own page.

    `select_option` records rather than acts, because what matters is which
    value would have been sent — a fake that "selected" something could not
    tell an unsent reason from a wrong one.
    """

    def __init__(self, *, has_form=True, still_listed=False):
        super().__init__(tab=False)
        self._has_form = has_form
        self._still_listed = still_listed
        self.selected = []
        self.cancelled = False
        self._load_list()

    def _load_list(self):
        html = (FIXTURES / "subscriptions_list.html").read_text(encoding="utf-8")
        root = self._soup.select_one("#root")
        # Inside the container the real selector insists on: cards loose in the
        # page are exactly what a broken scrape sees, and would make this fake
        # disagree with production about what "found it" means.
        box = BeautifulSoup(
            '<div class="subscription-list-container"></div>', "html.parser"
        ).div
        for card in BeautifulSoup(html, "html.parser").select(SUBSCRIPTION_CARD):
            box.append(card)
        root.append(box)

    def goto(self, url, **_kw):
        self.gotos.append(url)
        root = self._soup.select_one("#root")
        if "cancelSubscription" in url:
            root.clear()
            if self._has_form:
                page = (FIXTURES / "cancel_subscription.html").read_text(encoding="utf-8")
                root.append(BeautifulSoup(page, "html.parser").select_one(CANCEL_DIALOG))
        else:
            root.clear()
            if not self.cancelled or self._still_listed:
                self._load_list()

    def select_option(self, selector, value):
        self.selected.append((selector, value))

    def clicked(self, node, timeout):
        super().clicked(node, timeout)
        if node.get("id") == "confirmCancelLink":
            self.cancelled = True


class CancelSubscriptionTest(unittest.TestCase):
    def setUp(self):
        if not HAVE_BS4:
            self.skipTest(NO_DEPS.format(pkg="beautifulsoup4"))
        self.page = CancelPage()

    def cancel(self, query="Dishwasher", confirm=False, reason=None, sub_id=None):
        return cancel_subscription(self.page, sub_id, query, confirm, reason)

    def test_a_dry_run_reads_the_page_and_agrees_to_nothing(self):
        result = self.cancel()
        self.assertFalse(result["cancelled"])
        self.assertIsNone(result["verified"])
        self.assertEqual(result["heading"], "Cancel your subscription?")
        self.assertEqual(len(result["consequences"]), 2)
        self.assertFalse(self.page.cancelled)

    # Resolved through the list, so a title search works and a stray id gets a
    # refusal instead of somebody else's cancellation page.
    def test_the_target_is_resolved_before_the_cancel_page_is_opened(self):
        result = self.cancel()
        self.assertTrue(result["subscription_id"].startswith("SNS"))
        self.assertIn(result["subscription_id"], self.page.gotos[-1])
        self.assertTrue(result["title"])

    def test_the_dry_run_offers_the_reasons_it_would_accept(self):
        self.assertIn("accident", self.cancel()["reasons"])

    def test_confirming_clicks_through_and_verifies_it_is_gone(self):
        result = self.cancel(confirm=True)
        self.assertTrue(result["cancelled"])
        self.assertTrue(result["verified"])
        self.assertIn("confirmCancelLink", [c[1] for c in self.page.clicks])

    # Amazon's page reloads either way; only the list says which happened.
    def test_a_subscription_still_listed_afterwards_is_reported_as_such(self):
        self.page = CancelPage(still_listed=True)
        result = self.cancel(confirm=True)
        self.assertTrue(result["cancelled"])
        self.assertIs(result["verified"], False)

    def test_a_verification_that_cannot_be_made_is_none(self):
        page = CancelPage()
        page.goto = lambda *_a, **_k: (_ for _ in ()).throw(RuntimeError("network"))
        self.assertIsNone(verify_cancelled(page, "SNSD0_FIXTURESUB0000000001"))

    # Amazon marks the field "(Optional)", so the default puts no words in the
    # user's mouth.
    def test_no_reason_is_sent_unless_one_was_asked_for(self):
        self.cancel(confirm=True)
        self.assertEqual(self.page.selected, [])

    def test_a_reason_reaches_the_dropdown(self):
        self.cancel(confirm=True, reason="accident")
        selector, value = self.page.selected[0]
        self.assertEqual(selector, CANCEL_REASON_SELECT)
        self.assertTrue(value.endswith("accident"))

    # Refused before the confirm click, not after: a cancellation that went
    # through with the wrong reason attached cannot be taken back.
    def test_a_bad_reason_stops_before_anything_is_clicked(self):
        with self.assertRaises(CancelReasonUnknown):
            self.cancel(confirm=True, reason="too_many_cats")
        self.assertFalse(self.page.cancelled)

    def test_a_page_with_no_cancel_form_is_a_refusal_not_a_crash(self):
        self.page = CancelPage(has_form=False)
        with self.assertRaises(NotCancellable) as e:
            self.cancel()
        self.assertIn("already be cancelled", str(e.exception))

    def test_an_unknown_subscription_never_reaches_a_cancel_page(self):
        with self.assertRaises(NoSuchSubscription):
            self.cancel(query="bicycle")
        self.assertFalse(any("cancelSubscription" in u for u in self.page.gotos))
