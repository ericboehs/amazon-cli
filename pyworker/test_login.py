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
    should_prefill_email,
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
        self.assertTrue(order_access_ok(ORDERS, order_cards=12))

    def test_a_signed_in_page_that_is_not_orders_is_not_proof(self):
        # The tier this whole module exists to reject. Amazon renders the global
        # Sign Out link on every page it serves a *recognized* session — the
        # homepage, the cart, a product page — while bouncing that same session
        # from order history. Reading it as proof of order access saves exactly
        # the cookies `amazon order sync` will be rejected with.
        self.assertFalse(order_access_ok(HOME, order_cards=0))
        self.assertFalse(order_access_ok("https://www.amazon.com/gp/cart/view.html", 0))
        self.assertFalse(order_access_ok("https://www.amazon.com/dp/B0747R1M51", 0))

    def test_order_shaped_nodes_elsewhere_are_not_proof_either(self):
        # Marker counts are only meaningful once the URL says we are looking at
        # order history; other pages carry card-shaped nodes of their own.
        self.assertFalse(order_access_ok(HOME, order_cards=12))

    def test_a_signin_bounce_fails_even_with_markers_present(self):
        # This is the regression. The sign-in page really does contain a node
        # matching the order-card selector, so counting markers without
        # checking the URL declared a recognized-only session authenticated —
        # and `amazon order sync` was then rejected with the cookies it saved.
        self.assertFalse(order_access_ok(SIGNIN, order_cards=1))
        self.assertFalse(order_access_ok(SIGNIN, order_cards=12))

    def test_a_page_with_no_markers_fails(self):
        # On the orders URL with nothing rendered: the navigation is in flight,
        # or Amazon served a shell. Either way there is nothing to conclude yet.
        self.assertFalse(order_access_ok(ORDERS, order_cards=0))

    def test_missing_url_fails(self):
        self.assertFalse(order_access_ok(None, order_cards=1))
        self.assertFalse(order_access_ok("", order_cards=1))


class ShouldPrefillEmailTest(unittest.TestCase):
    def test_the_email_step_gets_prefilled(self):
        self.assertTrue(should_prefill_email(email_visible=True, password_visible=False))

    def test_a_password_prompt_is_left_alone(self):
        # The reported regression: the re-auth page shows an email field next to
        # the password box, so pre-filling it and clicking Continue submitted an
        # empty password. Amazon threw the context away and re-rendered a clean
        # sign-in page -- which reads as "it skipped past the password".
        self.assertFalse(should_prefill_email(email_visible=True, password_visible=True))

    def test_nothing_to_fill(self):
        self.assertFalse(should_prefill_email(email_visible=False, password_visible=False))
        self.assertFalse(should_prefill_email(email_visible=False, password_visible=True))


class ShouldRenavigateTest(unittest.TestCase):
    def test_an_idle_homepage_gets_steered_to_orders(self):
        # Amazon often returns you to the homepage after sign-in rather than the
        # page you asked for; without the nudge the poll would watch a
        # signed-in homepage for ten minutes and time out having tested nothing.
        self.assertTrue(should_renavigate(HOME))

    def test_a_tab_mid_challenge_is_left_alone(self):
        self.assertFalse(should_renavigate(SIGNIN))
        self.assertFalse(should_renavigate("https://www.amazon.com/ap/mfa"))

    def test_a_captcha_is_left_alone(self):
        # The regression, and the worst one in this file: the bot check is served
        # from /errors/validateCaptcha, which is not under /ap/, so the old
        # "anything outside /ap/ is idle" rule nudged it every ten seconds. Each
        # nudge throws away the characters the user has typed and makes Amazon
        # mint a fresh captcha, so the login cannot be completed at all — it
        # burns the full ten minutes and then reports a timeout.
        self.assertFalse(
            should_renavigate("https://www.amazon.com/errors/validateCaptcha?x=1")
        )

    def test_the_other_account_pages_are_left_alone(self):
        # Same hijack, less dramatic: steering away from a password reset or an
        # account-fixup step abandons a flow the user is partway through.
        for path in ("/ap/forgotpassword", "/ap/accountfixup", "/ap/switchaccount"):
            self.assertFalse(should_renavigate(f"https://www.amazon.com{path}"), path)

    def test_an_unrecognized_page_is_left_alone(self):
        # The allowlist's whole purpose. A URL nobody anticipated is far more
        # likely a challenge we haven't seen than an idle tab, and the two
        # mistakes do not cost the same.
        self.assertFalse(should_renavigate("https://www.amazon.com/some/new/hold"))

    def test_a_non_amazon_page_is_left_alone(self):
        # Amazon hands 2FA off to third-party identity pages; a `goto` there is
        # both useless and destructive.
        self.assertFalse(should_renavigate("https://example.com/"))

    def test_already_on_orders_needs_no_nudge(self):
        self.assertFalse(should_renavigate(ORDERS))
        self.assertFalse(should_renavigate(ORDERS_URL))
        # The legacy order-history paths Amazon still redirects some accounts to.
        # Treating them as "somewhere else" would steer away from the very page
        # the poll is waiting for.
        self.assertFalse(
            should_renavigate("https://www.amazon.com/gp/css/order-history?ref=nav")
        )

    def test_no_url_yet(self):
        self.assertFalse(should_renavigate(None))
        self.assertFalse(should_renavigate(""))


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
