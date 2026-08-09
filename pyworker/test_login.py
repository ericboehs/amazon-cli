"""Tests for the login worker's authentication check.

Only the pure decision functions are covered — the browser flow around them
needs a real Chrome window and a human, and is verified by running it.
"""

import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from login import (  # noqa: E402
    ORDER_MARKERS,
    ORDERS_URL,
    describe_state,
    is_signin_url,
    order_access_ok,
    poll_state,
    should_prefill_email,
    should_renavigate,
    timeout_message,
    unsavable_reason,
    write_private,
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


class PollStateTest(unittest.TestCase):
    """Which tab the poll reports on and acts on.

    The poll watched exactly one page: the one it opened. Amazon's challenges
    open their own windows, so the original tab can sit on an untouched homepage
    for the full ten minutes while the entire sign-in happens beside it.
    """

    def test_a_signin_tab_wins_over_an_idle_one(self):
        # Order matters: the idle tab is first, and is what the old code read.
        self.assertEqual(poll_state([HOME, SIGNIN]), SIGNIN)

    def test_a_signin_tab_suppresses_the_nudge(self):
        # The consequence that makes the ordering load-bearing rather than
        # cosmetic. `should_renavigate` reads this pick, so a 2FA prompt open
        # anywhere stops the poll from reloading the tab underneath it — the
        # code has already been sent and a reload spends it for nothing.
        self.assertFalse(should_renavigate(poll_state([HOME, SIGNIN])))

    def test_orders_in_a_second_tab_is_what_gets_reported(self):
        self.assertEqual(poll_state([HOME, ORDERS]), ORDERS)

    def test_signin_outranks_orders(self):
        # Both open at once means the orders tab is the stale one — it is the
        # page we were bounced *from*.
        self.assertEqual(poll_state([ORDERS, SIGNIN]), SIGNIN)

    def test_falls_back_to_the_tab_we_opened(self):
        self.assertEqual(poll_state([HOME, "https://www.amazon.com/dp/B0747R1M51"]), HOME)

    def test_no_tabs_at_all(self):
        # Every window closed. Handled rather than IndexError'd, because this is
        # reachable: the user quits the browser between two ticks.
        self.assertIsNone(poll_state([]))


class DescribeStateTest(unittest.TestCase):
    """The heartbeat exists so a ten-minute timeout is diagnosable afterwards."""

    def test_names_each_place_the_flow_can_stall(self):
        self.assertIn("sign-in", describe_state(SIGNIN))
        self.assertIn("hasn't rendered", describe_state(ORDERS))
        self.assertIn("amazon.com", describe_state(HOME))
        self.assertIn("no page", describe_state(None))

    def test_the_legacy_orders_paths_are_recognized_as_orders(self):
        # Was a bare `"/your-orders" in url`, so an account Amazon redirects to
        # the old path got reported as "on https://www.amazon.com/gp/css/..." —
        # the one state where the user should be told to keep waiting instead
        # read as the poll being lost.
        self.assertIn(
            "hasn't rendered",
            describe_state("https://www.amazon.com/gp/css/order-history?ref=nav"),
        )


class TimeoutMessageTest(unittest.TestCase):
    """A ten-minute timeout has several causes and used to name one of them."""

    def test_a_signin_stall_gets_the_password_explanation(self):
        msg = timeout_message(SIGNIN, None)
        self.assertIn("sign-in", msg)
        self.assertIn("password", msg)

    def test_other_stalls_do_not_claim_it_was_the_password(self):
        # The regression. A hijacked captcha, a dropped connection, or a stale
        # first tab all ended here, and all printed "Amazon asks for the
        # password again" — so the user retried the password and failed the
        # same way, with the actual cause never mentioned.
        for url in (HOME, ORDERS, None):
            self.assertNotIn("password", timeout_message(url, None), repr(url))

    def test_the_last_swallowed_error_is_carried_out(self):
        # The poll's `except` is what keeps a mid-navigation detach from killing
        # the run; the cost is that the one exception that mattered was dropped
        # on the floor along with the harmless ones.
        msg = timeout_message(ORDERS, "TargetClosedError: browser has been closed")
        self.assertIn("TargetClosedError", msg)

    def test_it_always_says_nothing_was_saved(self):
        for url in (SIGNIN, HOME, ORDERS, None):
            self.assertIn("nothing was saved", timeout_message(url, None))


class UnsavableReasonTest(unittest.TestCase):
    """The gate between "this window can read orders" and "these cookies can".

    Order history rendering proves the former. It says nothing about whether the
    cookies survive the window being closed, and login used to write them and
    report success either way.
    """

    NOW = 1_700_000_000.0

    def jar(self, **kw):
        cookie = {"name": "x-main", "value": "v", "expires": self.NOW + 86_400}
        cookie.update(kw)
        return [{"name": "session-id", "value": "1", "expires": self.NOW + 86_400}, cookie]

    def refusal(self, cookies):
        """The reason, asserted to exist. Every caller here wants both halves."""
        reason = unsavable_reason(cookies, self.NOW)
        self.assertIsNotNone(reason)
        return reason or ""

    def test_a_live_session_cookie_is_savable(self):
        self.assertIsNone(unsavable_reason(self.jar(), self.NOW))

    def test_a_browser_session_cookie_is_refused(self):
        # Playwright writes -1 for a cookie that dies with the window — which is
        # what Amazon issues when "Keep me signed in" is left unchecked.
        # `sync.rb`'s `session_cookie_live?` rejects exactly this, so writing it
        # produced "saved 47 cookies" followed by a sync that called itself
        # unauthenticated and fell through to a full password login.
        self.assertIn("Keep me signed in", self.refusal(self.jar(expires=-1)))

    def test_an_already_expired_cookie_is_refused(self):
        self.assertIsNotNone(unsavable_reason(self.jar(expires=self.NOW - 1), self.NOW))

    def test_a_non_numeric_expiry_is_refused(self):
        self.assertIsNotNone(unsavable_reason(self.jar(expires="soon"), self.NOW))
        self.assertIsNotNone(unsavable_reason(self.jar(expires=None), self.NOW))

    def test_a_bool_expiry_is_refused(self):
        # `True` is an int in Python and would otherwise sail past the numeric
        # check and compare as 1 — i.e. epoch, i.e. long expired, read as valid.
        self.assertIsNotNone(unsavable_reason(self.jar(expires=True), self.NOW))

    def test_the_auth_cookie_missing_is_refused(self):
        others = [{"name": "session-id", "value": "1", "expires": self.NOW + 86_400}]
        self.assertIn("x-main", self.refusal(others))

    def test_an_empty_jar_is_refused_rather_than_written(self):
        # The destructive case: cookie enumeration racing a navigation returned
        # nothing, login wrote `{}` over a working jar, emitted `done` with
        # count=0, and exited 0. The session was destroyed and the tool reported
        # success.
        self.assertIn("no cookies", self.refusal([]))

    def test_only_x_main_is_required(self):
        # Not a longer list on purpose. `sess-at-main` is not set in every
        # request context, and requiring it would refuse working sessions —
        # amazon-orders' own COOKIES_SET_WHEN_AUTHENTICATED is just ["x-main"].
        just_it = [{"name": "x-main", "value": "v", "expires": self.NOW + 86_400}]
        self.assertIsNone(unsavable_reason(just_it, self.NOW))


class WritePrivateTest(unittest.TestCase):
    def test_it_lands_complete_and_0600(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "cookies.json"
            write_private(path, '{"x-main":"v"}')
            self.assertEqual(path.read_text(), '{"x-main":"v"}')
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_a_failed_write_leaves_the_previous_file_alone(self):
        # The point of the rename: a crash mid-write used to leave a truncated
        # jar, and the failure then surfaced on some later command as corrupt
        # JSON rather than here.
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "cookies.json"
            write_private(path, "first")
            with self.assertRaises(TypeError):
                write_private(path, None)  # type: ignore[arg-type]
            self.assertEqual(path.read_text(), "first")
            self.assertFalse((Path(d) / "cookies.json.tmp").exists())

    def test_it_overwrites_without_widening_the_mode(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "cookies.json"
            path.write_text("old")
            os.chmod(path, 0o644)
            write_private(path, "new")
            self.assertEqual(path.read_text(), "new")
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)


class OrderMarkersTest(unittest.TestCase):
    def test_several_markers_are_tried(self):
        # A single selector that Amazon has since renamed costs the user ten
        # minutes of waiting and then a failure, so breadth is worth more here
        # than precision -- the URL check is what keeps it honest.
        self.assertGreater(len(ORDER_MARKERS), 1)
        self.assertTrue(all(isinstance(s, str) and s for s in ORDER_MARKERS))


if __name__ == "__main__":
    unittest.main()
