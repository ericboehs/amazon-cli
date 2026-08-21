"""Tests for the login worker's authentication check.

Only the pure decision functions are covered — the browser flow around them
needs a real Chrome window and a human, and is verified by running it.
"""

import io
import json
import os
import stat
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from login import (  # noqa: E402
    ORDER_MARKERS,
    ORDERS_URL,
    credentials_from,
    describe_state,
    dismiss_upsell,
    should_dismiss_upsell,
    fill_otp,
    fill_password,
    read_request,
    should_submit_otp,
    is_amazon_domain,
    is_signin_url,
    marker_counts,
    order_access_ok,
    report_markers,
    poll_state,
    resolve_cookies,
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

    def test_a_nudge_can_only_ever_be_about_the_tab_the_poll_will_nudge(self):
        # The poll decides from `poll_state(...)` and acts on `pages[0]`. That is
        # only safe while the sole tab `should_renavigate` approves is the first
        # one, which holds because the signin and orders branches return URLs it
        # always declines. Change the fallback and this is where it breaks —
        # otherwise the poll approves tab N and reloads tab 0 out from under the
        # user, with nothing in the output to say it happened.
        product = "https://www.amazon.com/dp/B0747R1M51"
        approved = 0
        for tabs in ([HOME, SIGNIN, ORDERS, product, None], [HOME, product],
                     [product, HOME], [HOME, None], [HOME, ORDERS], [HOME, SIGNIN]):
            for i in range(len(tabs)):
                urls = tabs[i:] + tabs[:i]
                picked = poll_state(urls)
                if should_renavigate(picked):
                    approved += 1
                    self.assertEqual(picked, urls[0], urls)
        # The invariant is only worth asserting if the branch is reachable.
        self.assertTrue(approved, "no arrangement produced a nudge")

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

    def reason(self, cookies):
        """The gate as `main()` runs it: resolve the list, then judge it."""
        return unsavable_reason(resolve_cookies(cookies), self.NOW)

    def refusal(self, cookies):
        """The reason, asserted to exist. Every caller here wants both halves."""
        reason = self.reason(cookies)
        self.assertIsNotNone(reason)
        return reason or ""

    def test_a_live_session_cookie_is_savable(self):
        self.assertIsNone(self.reason(self.jar()))

    def test_a_browser_session_cookie_is_refused(self):
        # Playwright writes -1 for a cookie that dies with the window — which is
        # what Amazon issues when "Keep me signed in" is left unchecked.
        # `sync.rb`'s `session_cookie_live?` rejects exactly this, so writing it
        # produced "saved 47 cookies" followed by a sync that called itself
        # unauthenticated and fell through to a full password login.
        self.assertIn("Keep me signed in", self.refusal(self.jar(expires=-1)))

    def test_an_already_expired_cookie_is_refused(self):
        self.assertIsNotNone(self.reason(self.jar(expires=self.NOW - 1)))

    def test_a_cookie_expiring_within_the_minute_is_refused(self):
        # The gate exists to assert what `sync.rb` asserts — and sync asserts it
        # strictly later, by definition. A cookie with seconds left passes here
        # and fails there, which is the exact split this function removes.
        self.assertIsNotNone(self.reason(self.jar(expires=self.NOW + 5)))

    def test_a_non_numeric_expiry_is_refused(self):
        self.assertIsNotNone(self.reason(self.jar(expires="soon")))
        self.assertIsNotNone(self.reason(self.jar(expires=None)))

    def test_a_bool_expiry_is_refused(self):
        # `True` is an int in Python and would otherwise sail past the numeric
        # check and compare as 1 — i.e. epoch, i.e. long expired, read as valid.
        self.assertIsNotNone(self.reason(self.jar(expires=True)))

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
        self.assertIsNone(self.reason(just_it))


class ResolveCookiesTest(unittest.TestCase):
    """`context.cookies()` is a list, and Amazon puts the same name in it twice.

    A host-scoped `www.amazon.com` duplicate can sit alongside the domain-scoped
    `.amazon.com` cookie during sign-in. The gate and the jar used to resolve
    that collision independently — `next(...)` took the first match, the dict
    comprehension took the last — so the entry that was validated and the entry
    that was stored could be different cookies with different expiries.
    """

    NOW = 1_700_000_000.0

    def dup(self, first_expires, second_expires):
        return [
            {"name": "x-main", "value": "first", "domain": "www.amazon.com",
             "expires": first_expires},
            {"name": "x-main", "value": "second", "domain": ".amazon.com",
             "expires": second_expires},
        ]

    def test_the_durable_duplicate_wins_whichever_way_round_it_is(self):
        live, dead = self.NOW + 86_400, -1
        self.assertEqual(resolve_cookies(self.dup(dead, live))["x-main"]["value"], "second")
        self.assertEqual(resolve_cookies(self.dup(live, dead))["x-main"]["value"], "first")

    def test_a_session_duplicate_no_longer_refuses_a_good_login(self):
        # The false refusal: the gate read the host-scoped session cookie and
        # told the user to check "Keep me signed in" — a box that was already
        # checked, about a session that was fine.
        resolved = resolve_cookies(self.dup(-1, self.NOW + 86_400))
        self.assertIsNone(unsavable_reason(resolved, self.NOW))

    def test_a_session_duplicate_no_longer_passes_a_dead_one_through(self):
        # And the mirror image: gate validates the durable cookie, jar stores
        # the session one, login reports success, sync rejects the jar.
        resolved = resolve_cookies(self.dup(self.NOW + 86_400, -1))
        self.assertIsNone(unsavable_reason(resolved, self.NOW))
        self.assertEqual(resolved["x-main"]["value"], "first")

    def test_the_broader_domain_breaks_a_tie(self):
        same = self.NOW + 86_400
        self.assertEqual(resolve_cookies(self.dup(same, same))["x-main"]["value"], "second")

    def test_unnamed_cookies_are_dropped(self):
        self.assertEqual(resolve_cookies([{"value": "v"}, {"name": "", "value": "v"}]), {})

    def test_distinct_names_all_survive(self):
        cookies = [{"name": "x-main", "value": "a"}, {"name": "session-id", "value": "b"}]
        self.assertEqual(set(resolve_cookies(cookies)), {"x-main", "session-id"})


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


def emitted(fn):
    """Run `fn`, returning the JSON events it wrote to stdout."""
    buf = io.StringIO()
    with redirect_stdout(buf):
        fn()
    return [json.loads(line) for line in buf.getvalue().splitlines() if line.strip()]


class FakeMarkerPage:
    """selector -> match count. Unlisted selectors match nothing."""

    def __init__(self, counts):
        self._counts = counts

    def locator(self, sel):
        return FakeMarkerLocator(self._counts.get(sel, 0))


class FakeMarkerLocator:
    def __init__(self, n):
        self._n = n

    def count(self):
        return self._n


class MarkerReportTest(unittest.TestCase):
    """The gate has to say which marker carried it.

    `amazon login` is the only probe in this repo that runs against a real
    signed-in account every time, so it is the one place a selector list can be
    measured instead of argued about. Measured on 2026-08-10, one of the four
    markers matched and three returned zero — a list that reads as defense in
    depth and is currently a single point of failure. The report is what stops
    the next reading of that coming from a stale comment.
    """

    # The live measurement, verbatim. Ten orders on the page; the container is
    # the single <section> all ten cards sit inside, so it counts 1, not 10.
    LIVE = {
        ".order-card, .js-order-card": 10,
        ".your-orders-content-container": 1,
        "[data-component=orderCard]": 0,
        "#ordersContainer": 0,
        "#your-orders-content": 0,
    }

    # Same URL, fresh context, no storage state — Amazon bounces to /ap/signin.
    # This is the half of the measurement that makes a marker worth having: the
    # card selector is *present* on the page we must reject, and only the URL
    # check keeps that 1 from reading as proof.
    BOUNCED = {
        ".order-card, .js-order-card": 1,
        ".your-orders-content-container": 0,
        "[data-component=orderCard]": 0,
        "#ordersContainer": 0,
        "#your-orders-content": 0,
    }

    def test_counts_are_reported_per_selector(self):
        got = marker_counts(FakeMarkerPage(self.LIVE))
        self.assertEqual(got, self.LIVE)
        # Every marker gets a key, including the ones that matched nothing —
        # a report that only listed hits could not distinguish "three are dead"
        # from "three were never probed".
        self.assertEqual(set(got), set(ORDER_MARKERS))

    def test_the_report_names_the_markers_that_matched(self):
        msgs = [e["msg"] for e in emitted(lambda: report_markers(self.LIVE))]
        self.assertEqual(len(msgs), 1)
        self.assertIn("2 of 5 markers", msgs[0])
        self.assertIn(".order-card, .js-order-card (10)", msgs[0])

    def test_the_report_does_not_list_markers_that_matched_nothing(self):
        # Naming them would read as though they contributed. The count in
        # "1 of 4" is what says three did not.
        msg = [e["msg"] for e in emitted(lambda: report_markers(self.LIVE))][0]
        for dead in ("[data-component=orderCard]", "#ordersContainer", "#your-orders-content"):
            self.assertNotIn(dead, msg)

    def test_a_layout_where_more_markers_render_says_so(self):
        # The point of reporting rather than asserting: another account, or
        # Amazon next month, is allowed to disagree with the measurement above.
        counts = dict(self.LIVE, **{"#ordersContainer": 1})
        msg = [e["msg"] for e in emitted(lambda: report_markers(counts))][0]
        self.assertIn("3 of 5 markers", msg)
        self.assertIn("#ordersContainer (1)", msg)

    def test_the_container_marker_is_absent_from_the_page_we_must_reject(self):
        # What makes a marker worth adding: it has to separate the two pages,
        # not merely appear on the good one. The card selector does not — it
        # counts 1 on the sign-in page — so it is the URL half of
        # `order_access_ok` doing that work today, alone.
        self.assertEqual(self.BOUNCED[".your-orders-content-container"], 0)
        self.assertEqual(self.LIVE[".your-orders-content-container"], 1)
        self.assertGreater(self.BOUNCED[".order-card, .js-order-card"], 0)

    def test_the_bounced_page_is_refused_despite_matching_a_marker(self):
        # The measurement above, run through the gate it exists to justify.
        self.assertFalse(order_access_ok(SIGNIN, sum(self.BOUNCED.values())))
        self.assertTrue(order_access_ok(ORDERS, sum(self.LIVE.values())))


class AmazonDomainTest(unittest.TestCase):
    """Which cookies reach the jar. Measured: 46 of 68 in a real login context
    are third-party ad-tech that Amazon's own pages loaded."""

    def test_amazon_domains_are_ours(self):
        for d in ("amazon.com", ".amazon.com", "www.amazon.com", ".www.amazon.com"):
            self.assertTrue(is_amazon_domain(d), d)

    def test_a_suffix_match_is_not_a_domain_match(self):
        # The bug in `endswith("amazon.com")`. Unreachable through the login
        # flow, which is the premise this module has been wrong about most.
        self.assertFalse(is_amazon_domain("notamazon.com"))
        self.assertFalse(is_amazon_domain(".notamazon.com"))
        self.assertFalse(is_amazon_domain("evilamazon.com"))

    def test_the_third_party_cookies_a_real_login_collects_are_dropped(self):
        # Names taken from an actual storage state, not invented.
        for d in (".doubleclick.net", ".pubmatic.com", ".rubiconproject.com",
                  ".casalemedia.com", ".demdex.net", ".taboola.com"):
            self.assertFalse(is_amazon_domain(d), d)

    def test_amazon_adsystem_is_not_carried(self):
        # Correctly excluded by the old test too, but only by accident of not
        # ending in the string. Now it is excluded because it is a different
        # domain, which is the reason that survives Amazon renaming things.
        self.assertFalse(is_amazon_domain(".amazon-adsystem.com"))

    def test_nothing_is_not_ours(self):
        self.assertFalse(is_amazon_domain(None))
        self.assertFalse(is_amazon_domain(""))


class OrderMarkersTest(unittest.TestCase):
    def test_the_empty_account_container_is_still_in_the_list(self):
        # This used to assert a working contract: `#your-orders-content` is the
        # page container, so a brand-new account with no orders would match it
        # and pass. Measured on a live orders page on 2026-08-10 it matched
        # zero times, with ten orders on the page — so it is not rendering at
        # all, and an empty account times out at ten minutes today.
        #
        # Kept in the list, and kept asserted, because removing it would delete
        # the only record that the empty-account case is meant to be covered.
        # Closing it needs the real container id off a live empty account;
        # guessing one here is how the original claim got made.
        self.assertIn("#your-orders-content", ORDER_MARKERS)

    def test_the_card_selectors_are_not_the_container(self):
        # The list has to keep both kinds. Cards alone can't distinguish an
        # empty order list from a bounce; the container alone renders on a shell
        # Amazon serves before it has decided which you get. The poll's
        # two-consecutive-ticks rule exists because of that second half.
        cards = [m for m in ORDER_MARKERS if m != "#your-orders-content"]
        self.assertTrue(cards, "no card-level markers left")


if __name__ == "__main__":
    unittest.main()


class FakeField:
    """One form field, standing in for a Playwright locator."""

    def __init__(self, present=True, visible=True, value="", raise_wait=False):
        self.present = present
        self.visible = visible
        self.value = value
        self.raise_wait = raise_wait
        self.filled = None
        self.waited = False

    @property
    def first(self):
        return self

    def count(self):
        return 1 if self.present else 0

    def is_visible(self):
        return self.visible

    def input_value(self):
        return self.value

    def fill(self, value):
        self.filled = value
        self.value = value

    def wait_for(self, state=None, timeout=None):
        self.waited = True
        if self.raise_wait:
            raise RuntimeError("timeout")

    def click(self):
        self.clicked = True


class FakePage:
    def __init__(self, fields):
        self.fields = fields
        self.asked = []

    def locator(self, selector):
        self.asked.append(selector)
        return self.fields.get(selector, FakeField(present=False, visible=False))


class ReadRequestTest(unittest.TestCase):
    def read_with(self, stream):
        real = sys.stdin
        sys.stdin = stream
        try:
            return read_request()
        finally:
            sys.stdin = real

    class Tty(io.StringIO):
        def isatty(self):
            return True

    def test_a_credentials_line_is_parsed(self):
        self.assertEqual(
            self.read_with(io.StringIO('{"password": "hunter2"}\n')),
            {"password": "hunter2"},
        )

    # `python login.py` from a shell is a supported way to run this. Blocking
    # on a line nobody is going to type would hang it forever.
    def test_a_terminal_is_never_read(self):
        self.assertEqual(self.read_with(self.Tty("{}")), {})

    def test_an_empty_stdin_is_fine(self):
        self.assertEqual(self.read_with(io.StringIO("")), {})
        self.assertEqual(self.read_with(io.StringIO("   \n")), {})

    # Deliberately not echoed: a malformed line is still the line with the
    # password in it.
    def test_a_broken_line_is_reported_without_being_quoted(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            self.assertEqual(self.read_with(io.StringIO('{"password": "hunt\n')), {})
        self.assertIn("unreadable credentials line", buf.getvalue())
        self.assertNotIn("hunt", buf.getvalue())

    def test_a_json_scalar_is_not_a_request(self):
        self.assertEqual(self.read_with(io.StringIO('"hunter2"\n')), {})


class CredentialsFromTest(unittest.TestCase):
    def test_it_returns_both(self):
        self.assertEqual(
            credentials_from({"password": "hunter2", "otp_secret": "JBSWY3DPEHPK3PXP"}),
            ("hunter2", "JBSWY3DPEHPK3PXP"),
        )

    def test_an_otpauth_uri_is_reduced_to_its_secret(self):
        uri = "otpauth://totp/Amazon:me?secret=JBSWY3DPEHPK3PXP&issuer=Amazon"
        self.assertEqual(credentials_from({"otp_secret": uri})[1], "JBSWY3DPEHPK3PXP")

    # A blank field in config must behave like a missing one, not like a
    # password of length zero submitted into the form.
    def test_empty_strings_are_absent(self):
        self.assertEqual(credentials_from({"password": "", "otp_secret": ""}), (None, None))
        self.assertEqual(credentials_from({}), (None, None))

    # A broken OTP costs the 2FA step, not the password step.
    def test_a_useless_otp_uri_keeps_the_password(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            got = credentials_from({"password": "hunter2", "otp_secret": "otpauth://totp/x?issuer=y"})
        self.assertEqual(got, ("hunter2", None))
        self.assertIn("ignoring the OTP secret", buf.getvalue())
        self.assertNotIn("hunter2", buf.getvalue())


class ShouldSubmitOtpTest(unittest.TestCase):
    def test_an_empty_box_and_a_new_code_goes(self):
        self.assertTrue(should_submit_otp("", "123456", None))

    # The user may be halfway through typing from their phone.
    def test_it_never_types_over_the_user(self):
        self.assertFalse(should_submit_otp("12", "123456", None))

    # A TOTP is good for thirty seconds and this poll ticks every two. Without
    # this the same rejected code is submitted fifteen times and earns a rate
    # limit.
    def test_the_same_code_is_not_submitted_twice(self):
        self.assertFalse(should_submit_otp("", "123456", "123456"))
        self.assertTrue(should_submit_otp("", "654321", "123456"))


class FillPasswordTest(unittest.TestCase):
    def test_it_fills_and_submits(self):
        field = FakeField()
        submit = FakeField()
        page = FakePage({"#ap_password": field, "#signInSubmit": submit})
        self.assertTrue(fill_password(page, "hunter2"))
        self.assertEqual(field.filled, "hunter2")
        self.assertTrue(getattr(submit, "clicked", False))

    # Amazon renders the password step after Continue, so a field that never
    # appears means this is a page we don't understand — leave it to the human.
    def test_a_field_that_never_appears_is_declined(self):
        page = FakePage({"#ap_password": FakeField(raise_wait=True)})
        self.assertFalse(fill_password(page, "hunter2"))

    def test_a_missing_submit_button_still_counts_as_filled(self):
        field = FakeField()
        page = FakePage({"#ap_password": field})
        self.assertTrue(fill_password(page, "hunter2"))
        self.assertEqual(field.filled, "hunter2")


class FillOtpTest(unittest.TestCase):
    SECRET = "JBSWY3DPEHPK3PXP"

    def test_it_types_the_current_code(self):
        try:
            import pyotp  # noqa: F401
        except ImportError:
            self.skipTest("pyotp not installed")
        field = FakeField()
        page = FakePage({"#auth-mfa-otpcode": field, "#auth-signin-button": FakeField()})
        code = fill_otp(page, self.SECRET, None)
        self.assertRegex(code, r"^\d{6}$")
        self.assertEqual(field.filled, code)

    def test_no_box_means_nothing_to_do(self):
        page = FakePage({})
        self.assertIsNone(fill_otp(page, self.SECRET, None))

    def test_an_invisible_box_is_left_alone(self):
        page = FakePage({"#auth-mfa-otpcode": FakeField(visible=False)})
        self.assertIsNone(fill_otp(page, self.SECRET, None))

    # Amazon uses a similar box for codes it emails you. A TOTP typed into that
    # one is simply wrong, so only the authenticator field is touched.
    def test_the_email_verification_box_is_not_the_authenticator_box(self):
        page = FakePage({"#cvf-input-code": FakeField()})
        self.assertIsNone(fill_otp(page, self.SECRET, None))
        self.assertNotIn("#cvf-input-code", page.asked)


class ShouldDismissUpsellTest(unittest.TestCase):
    # A stray click during sign-in is how you throw away a 2FA code Amazon has
    # already sent.
    def test_the_signin_flow_is_never_clicked(self):
        self.assertFalse(should_dismiss_upsell(SIGNIN))
        self.assertFalse(should_dismiss_upsell("https://www.amazon.com/ap/mfa"))
        self.assertFalse(should_dismiss_upsell("https://www.amazon.com/ap/cvf/request"))

    def test_the_finish_line_is_not_an_upsell(self):
        self.assertFalse(should_dismiss_upsell(ORDERS))

    # The passkey pitch, the phone-number pitch, and whatever they invent next.
    def test_an_interstitial_is_fair_game(self):
        self.assertTrue(should_dismiss_upsell("https://www.amazon.com/ax/claim/webauthn/enroll"))
        self.assertTrue(should_dismiss_upsell("https://www.amazon.com/ap/accountfixup"))

    # The homepage already has an owner: should_renavigate steers it back to
    # orders, so probing it for buttons would only add noise to a normal login.
    def test_an_idle_page_belongs_to_the_nudge(self):
        self.assertFalse(should_dismiss_upsell(HOME))
        self.assertFalse(should_dismiss_upsell("https://www.amazon.com/gp/css/homepage.html"))

    def test_nothing_off_amazon_is_touched(self):
        self.assertFalse(should_dismiss_upsell("https://example.com/not-now"))
        self.assertFalse(should_dismiss_upsell(None))
        self.assertFalse(should_dismiss_upsell("http://["))


class RoleField(FakeField):
    """A control found by role and accessible name."""

    def __init__(self, role, name, visible=True):
        super().__init__(visible=visible)
        self.role = role
        self.name = name


class RolePage:
    def __init__(self, controls=(), by_selector=None):
        self.controls = list(controls)
        self.by_selector = by_selector or {}
        self.clicked = []

    def locator(self, selector):
        return self.by_selector.get(selector, FakeField(present=False, visible=False))

    def get_by_role(self, role, name=None):
        for control in self.controls:
            if control.role == role and name.match(control.name):
                found = control
                page = self

                class Bound:
                    first = found

                    def __getattr__(self, attr):
                        return getattr(found, attr)

                found.click = lambda: page.clicked.append(found.name)
                return Bound()
        return FakeField(present=False, visible=False)


class DismissUpsellTest(unittest.TestCase):
    def test_it_clicks_not_now(self):
        page = RolePage([RoleField("button", "Not now")])
        self.assertEqual(dismiss_upsell(page), "not now")
        self.assertEqual(page.clicked, ["Not now"])

    def test_a_link_counts_too(self):
        page = RolePage([RoleField("link", "Maybe later")])
        self.assertEqual(dismiss_upsell(page), "maybe later")

    # "Skip" as a substring also matches "Skip to main content", the first link
    # on every Amazon page — which would click away from a page we mean to read.
    def test_the_accessibility_skip_link_is_not_a_decline_button(self):
        page = RolePage([RoleField("link", "Skip to main content")])
        self.assertIsNone(dismiss_upsell(page))
        self.assertEqual(page.clicked, [])

    def test_an_id_beats_a_text_match(self):
        known = FakeField()
        page = RolePage([RoleField("button", "Not now")],
                        by_selector={"#ap-account-fixup-phone-skip-link": known})
        self.assertEqual(dismiss_upsell(page), "#ap-account-fixup-phone-skip-link")
        self.assertTrue(getattr(known, "clicked", False))
        self.assertEqual(page.clicked, [])

    def test_an_invisible_control_is_not_clicked(self):
        page = RolePage([RoleField("button", "Not now", visible=False)])
        self.assertIsNone(dismiss_upsell(page))

    def test_a_page_with_no_decline_control_says_so_by_returning_none(self):
        self.assertIsNone(dismiss_upsell(RolePage()))

    # A locator that throws is a page mid-navigation, not a reason to stop.
    def test_a_throwing_locator_is_survivable(self):
        class Angry:
            def locator(self, _selector):
                raise RuntimeError("detached")

            def get_by_role(self, role, name=None):
                raise RuntimeError("detached")

        self.assertIsNone(dismiss_upsell(Angry()))
