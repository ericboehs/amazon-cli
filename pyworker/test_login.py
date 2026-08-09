"""Tests for the login worker's authentication check.

Only the pure decision functions are covered — the browser flow around them
needs a real Chrome window and a human, and is verified by running it.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from login import (  # noqa: E402
    ORDER_MARKERS,
    ORDERS_URL,
    describe_state,
    is_signin_url,
    order_access_ok,
    should_renavigate,
)

SIGNIN = (
    "https://www.amazon.com/ap/signin?openid.pape.max_auth_age=0"
    "&openid.return_to=https%3A%2F%2Fwww.amazon.com%2Fyour-orders%2Forders"
)
ORDERS = "https://www.amazon.com/your-orders/orders?timeFilter=year-2026"
HOME = "https://www.amazon.com/"


class IsSigninUrlTest(unittest.TestCase):
    def test_recognizes_the_signin_page(self):
        self.assertTrue(is_signin_url(SIGNIN))

    def test_recognizes_the_other_challenge_paths(self):
        # A 2FA or "verify it's you" step is still mid-sign-in, and treating it
        # as "somewhere else" would make the poll steer the tab away from the
        # prompt the user is trying to answer.
        for path in ("/ap/mfa", "/ap/challenge", "/ap/cvf/verify"):
            self.assertTrue(is_signin_url(f"https://www.amazon.com{path}?x=1"), path)

    def test_ordinary_pages_are_not_signin(self):
        self.assertFalse(is_signin_url(ORDERS))
        self.assertFalse(is_signin_url(HOME))
        self.assertFalse(is_signin_url(None))
        self.assertFalse(is_signin_url(""))


class OrderAccessOkTest(unittest.TestCase):
    def test_rendered_orders_pass(self):
        self.assertTrue(order_access_ok(ORDERS, signout_links=1, order_cards=12))

    def test_either_marker_alone_is_enough(self):
        self.assertTrue(order_access_ok(ORDERS, signout_links=1, order_cards=0))
        self.assertTrue(order_access_ok(ORDERS, signout_links=0, order_cards=12))

    def test_a_signin_bounce_fails_even_with_markers_present(self):
        # This is the regression. The sign-in page really does contain a node
        # matching the order-card selector, so counting markers without
        # checking the URL declared a recognized-only session authenticated —
        # and `amazon order sync` was then rejected with the cookies it saved.
        self.assertFalse(order_access_ok(SIGNIN, signout_links=0, order_cards=1))
        self.assertFalse(order_access_ok(SIGNIN, signout_links=1, order_cards=12))

    def test_a_page_with_no_markers_fails(self):
        self.assertFalse(order_access_ok(ORDERS, signout_links=0, order_cards=0))

    def test_missing_url_fails(self):
        self.assertFalse(order_access_ok(None, signout_links=1, order_cards=1))


class ShouldRenavigateTest(unittest.TestCase):
    def test_an_idle_homepage_gets_steered_to_orders(self):
        # Amazon often returns you to the homepage after sign-in rather than the
        # page you asked for; without the nudge the poll would watch a
        # signed-in homepage for ten minutes and time out having tested nothing.
        self.assertTrue(should_renavigate(HOME))

    def test_a_tab_mid_challenge_is_left_alone(self):
        self.assertFalse(should_renavigate(SIGNIN))
        self.assertFalse(should_renavigate("https://www.amazon.com/ap/mfa"))

    def test_already_on_orders_needs_no_nudge(self):
        self.assertFalse(should_renavigate(ORDERS))
        self.assertFalse(should_renavigate(ORDERS_URL))

    def test_no_url_yet(self):
        self.assertFalse(should_renavigate(None))


class DescribeStateTest(unittest.TestCase):
    """The heartbeat exists so a ten-minute timeout is diagnosable afterwards."""

    def test_names_each_place_the_flow_can_stall(self):
        self.assertIn("sign-in", describe_state(SIGNIN))
        self.assertIn("hasn't rendered", describe_state(ORDERS))
        self.assertIn("amazon.com", describe_state(HOME))
        self.assertIn("no page", describe_state(None))


class OrderMarkersTest(unittest.TestCase):
    def test_several_markers_are_tried(self):
        # A single selector that Amazon has since renamed costs the user ten
        # minutes of waiting and then a failure, so breadth is worth more here
        # than precision -- the URL check is what keeps it honest.
        self.assertGreater(len(ORDER_MARKERS), 1)
        self.assertTrue(all(isinstance(s, str) and s for s in ORDER_MARKERS))


if __name__ == "__main__":
    unittest.main()
