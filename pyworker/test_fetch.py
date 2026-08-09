"""Tests for the sync worker's cookie-jar protection.

amazon-orders rewrites the jar after every request, so a request that Amazon
bounces to sign-in persists a stripped jar over a working one. These cover the
decision about when to put the old jar back.
"""

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import types
import unittest
from contextlib import redirect_stdout
from datetime import date
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fetch  # noqa: E402
from fetch import (  # noqa: E402
    AUTH_COOKIE_NAMES,
    JarGuard,
    clear_dead_session,
    jar_cookie_names,
    jar_regressed,
    jar_without_auth,
    restore_jar,
    write_jar,
)

# Values here are meaningless fixtures — the code under test only reads names.
GOOD = json.dumps({"x-main": "v", "at-main": "v", "session-id": "v", "ubid-main": "v"})
WIPED = json.dumps({})
# What a sign-in bounce actually leaves: the anonymous cookies survive, the
# authenticated ones are expired out.
BOUNCED = json.dumps({"session-id": "v", "session-id-time": "v"})
# A jar amazon-orders wrote partway through the run, after a real sign-in.
FRESH = json.dumps({"x-main": "earned", "at-main": "earned", "session-id": "v"})


def emitted(fn):
    """Run fn, returning the NDJSON events it wrote to stdout."""
    buf = io.StringIO()
    with redirect_stdout(buf):
        fn()
    return [json.loads(line) for line in buf.getvalue().splitlines() if line.strip()]


def silently(fn):
    """Run fn for its return value, keeping its NDJSON out of the test output."""
    with redirect_stdout(io.StringIO()):
        return fn()


class JarCookieNamesTest(unittest.TestCase):
    def test_reads_names(self):
        self.assertEqual(jar_cookie_names(GOOD), {"x-main", "at-main", "session-id", "ubid-main"})

    def test_a_cookie_with_no_value_is_not_held(self):
        # How a cookie is deleted over HTTP: the response sets it to empty with
        # an expiry in the past, and requests' jar keeps the name with `""`.
        # Counting the name as present is counting a deletion as a session —
        # the strip that this whole file exists to catch would sail past the
        # regression check with `x-main` sitting there, empty.
        self.assertEqual(jar_cookie_names(json.dumps({"x-main": "", "session-id": "v"})),
                         {"session-id"})

    def test_unreadable_jars_are_empty_not_fatal(self):
        # A corrupt or truncated jar must not crash a sync; it reads as "no
        # cookies", which makes the regression check treat it as a loss.
        for raw in (None, "", "not json", "[]", '"scalar"', "null"):
            self.assertEqual(jar_cookie_names(raw), set(), repr(raw))


class JarRegressedTest(unittest.TestCase):
    def test_a_wiped_jar_is_a_regression(self):
        # The reproduced bug: 22 cookies before the sync, `{}` after.
        self.assertTrue(jar_regressed(GOOD, WIPED))

    def test_a_signin_bounce_is_a_regression(self):
        self.assertTrue(jar_regressed(GOOD, BOUNCED))

    def test_an_unchanged_jar_is_not(self):
        self.assertFalse(jar_regressed(GOOD, GOOD))

    def test_a_refreshed_jar_is_not(self):
        # Amazon rotates non-auth cookies constantly and amazon-orders persists
        # every one of those writes. Treating a normal refresh as a regression
        # would roll back good state on every successful sync.
        refreshed = json.dumps({"x-main": "v2", "at-main": "v2", "ubid-main": "v",
                                "session-id": "v2", "csm-hit": "v"})
        self.assertFalse(jar_regressed(GOOD, refreshed))

    def test_no_prior_jar_means_nothing_to_protect(self):
        # First-ever sync: there is no earlier state, so there is no rollback.
        self.assertFalse(jar_regressed(None, WIPED))

    def test_a_jar_that_never_had_auth_cookies_is_not_a_regression(self):
        self.assertFalse(jar_regressed(BOUNCED, WIPED))

    def test_an_auth_cookie_emptied_out_is_a_regression(self):
        # The quiet version of a sign-in bounce: the name survives, the value
        # doesn't. Read as "still there", it is a stripped jar that no longer
        # looks stripped — and the restore never fires.
        before = json.dumps({"x-main": "v", "session-id": "v"})
        emptied = json.dumps({"x-main": "", "session-id": "v"})
        self.assertTrue(jar_regressed(before, emptied))

    def test_an_anonymous_jar_is_not_a_session_worth_protecting(self):
        # `ubid-main` is a device id Amazon sets before you have ever signed in.
        # Treating its loss as a regression armed the rollback on a jar that was
        # never a session — including on the first sync of a new install, where
        # what it would roll back over is the jar the login just earned.
        anonymous = json.dumps({"ubid-main": "v", "session-id": "v"})
        self.assertFalse(jar_regressed(anonymous, WIPED))

    def test_the_trigger_is_the_cookie_everything_keys_on(self):
        # amazon-orders and `cookies_authenticated?` both decide on `x-main`
        # alone, so it is the loss that actually costs you the session. The
        # others are put back by the repair, but they don't arm it: firing on a
        # cookie nobody reads is how a rollback happens over a healthy jar.
        for name in AUTH_COOKIE_NAMES:
            if name == "x-main":
                continue
            before = json.dumps({"x-main": "v", name: "v"})
            self.assertFalse(jar_regressed(before, json.dumps({"x-main": "v"})), name)
        self.assertTrue(jar_regressed(json.dumps({"x-main": "v"}), WIPED))


class RestoreJarTest(unittest.TestCase):
    """The write-back itself, exercised against a real file.

    jar_regressed is the decision; this is the part that has to not lose data.
    These used to run against a hand-copied mirror of the closure inside
    `main()`, which meant they could keep passing while the code they stood for
    changed underneath them — the one failure mode a test cannot report.
    """

    def _restore(self, before_text, after_text):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "cookies.json"
            path.write_text(after_text)
            wrote = silently(lambda: restore_jar(path, before_text, "the test"))
            return wrote, path.read_text(), path.stat().st_mode & 0o777

    def test_a_wiped_jar_is_restored_byte_for_byte(self):
        wrote, text, _ = self._restore(GOOD, WIPED)
        self.assertTrue(wrote)
        self.assertEqual(text, GOOD)

    def test_restored_jars_stay_owner_only(self):
        # The jar holds live session cookies; restoring it must not widen it.
        _, _, mode = self._restore(GOOD, WIPED)
        self.assertEqual(mode, 0o600)

    def test_a_healthy_write_is_left_alone(self):
        fresher = json.dumps({"x-main": "v2", "at-main": "v2", "ubid-main": "v2"})
        wrote, text, _ = self._restore(GOOD, fresher)
        self.assertFalse(wrote)
        self.assertEqual(text, fresher)

    def test_no_prior_snapshot_means_no_write(self):
        wrote, text, _ = self._restore(None, WIPED)
        self.assertFalse(wrote)
        self.assertEqual(text, WIPED)

    def test_a_missing_jar_is_restored_not_skipped(self):
        # amazon-orders can unlink rather than truncate. "Gone" is the most
        # complete regression there is, so it must not read as "nothing to do".
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "cookies.json"
            self.assertTrue(silently(lambda: restore_jar(path, GOOD, "the test")))
            self.assertEqual(path.read_text(), GOOD)

    def test_the_runs_own_writes_survive_the_repair(self):
        # Rolling the file back wholesale undoes more than the failure did.
        # Amazon rotates its anonymous cookies constantly and amazon-orders
        # persists every one of those writes, so a jar restored byte-for-byte
        # comes back stale in ways that had nothing to do with the bounce.
        after = json.dumps({"session-id": "rotated", "csm-hit": "new"})
        wrote, text, _ = self._restore(GOOD, after)
        self.assertTrue(wrote)
        self.assertEqual(json.loads(text), {
            "x-main": "v", "at-main": "v", "ubid-main": "v",  # put back
            "session-id": "rotated",                          # kept, not reverted
            "csm-hit": "new",                                 # kept
        })

    def test_a_truncated_jar_is_replaced_wholesale(self):
        # Nothing can read it — amazon-orders least of all — so there is no
        # write of this run's worth keeping. It counts as the session gone.
        wrote, text, _ = self._restore(GOOD, '{"x-main": "v", "at-mai')
        self.assertTrue(wrote)
        self.assertEqual(json.loads(text), json.loads(GOOD))

    def test_it_says_which_run_did_the_damage(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "cookies.json"
            path.write_text(WIPED)
            events = emitted(lambda: restore_jar(path, GOOD, "the failed 2025 history fetch"))
            self.assertEqual(len(events), 1)
            self.assertEqual(events[0]["level"], "warn")
            self.assertIn("the failed 2025 history fetch", events[0]["msg"])


class CleanupNeverEscapesTest(unittest.TestCase):
    """Cleanup runs beside a diagnostic the user needs. It cannot outrank it.

    `read_text()` raises `UnicodeDecodeError` — a `ValueError`, not an
    `OSError` — on a jar with invalid UTF-8, which is precisely what a killed
    write leaves behind. It escaped the handler, escaped `main()`, and took the
    "Run: amazon login" message with it: the Ruby parent saw no error event at
    all and printed `python worker exited 1`. The stderr tail added in 98526ac
    can't rescue that either, because it attaches to an error event.
    """

    def undecodable(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        path = Path(d) / "cookies.json"
        path.write_bytes(b'{"x-main": "\xff\xfe"}')
        return path

    def test_restore_survives_a_jar_it_cannot_decode(self):
        path = self.undecodable()
        events = emitted(lambda: restore_jar(path, GOOD, "the test"))
        self.assertEqual(events[0]["level"], "warn")

    def test_clear_survives_a_jar_it_cannot_decode(self):
        path = self.undecodable()
        self.assertFalse(silently(lambda: clear_dead_session(path)))

    def test_the_guard_survives_a_jar_it_cannot_decode(self):
        # And it still counts as "no snapshot", so nothing gets written back
        # from a decode that never produced one.
        path = self.undecodable()
        guard = silently(lambda: JarGuard(path))
        self.assertIsNone(guard.jar_before)


class JarWithoutAuthTest(unittest.TestCase):
    def test_auth_cookies_are_dropped_and_the_rest_kept(self):
        out = jar_without_auth(GOOD)
        self.assertEqual(json.loads(out or "{}"), {"session-id": "v"})

    def test_a_jar_with_no_auth_cookies_needs_no_write(self):
        self.assertIsNone(jar_without_auth(BOUNCED))

    def test_unreadable_jars_are_left_alone(self):
        # Not "clear everything": a jar we cannot parse is a jar we cannot
        # reason about, and the caller's fallback is to leave it untouched.
        for raw in (None, "", "not json", "[]", '"scalar"', "null"):
            self.assertIsNone(jar_without_auth(raw), repr(raw))


class ClearDeadSessionTest(unittest.TestCase):
    """What has to happen when Amazon says the saved session is dead.

    Restoring the jar here — which is what the rejected-request path used to do
    — puts `x-main` back in the file that `sync.rb`'s `cookies_authenticated?`
    reads. Sync then takes its "we already have cookies" branch on every later
    run and posts the literal placeholder `unused-have-cookies` at Amazon's
    password form. It never recovers, and nothing in the output explains why:
    the fix is `amazon login`, and the tool has stopped being able to tell you
    that because it believes it is already logged in.
    """

    def _clear(self, text):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "cookies.json"
            path.write_text(text)
            os.chmod(path, 0o600)
            wrote = clear_dead_session(path)
            return wrote, path.read_text(), path.stat().st_mode & 0o777

    def test_the_auth_cookies_are_gone(self):
        wrote, text, _ = self._clear(GOOD)
        self.assertTrue(wrote)
        self.assertFalse(set(json.loads(text)) & set(AUTH_COOKIE_NAMES))

    def test_the_anonymous_cookies_survive(self):
        # Clearing is not deleting the file. Amazon's anonymous cookies are
        # what the next sign-in continues from, and throwing them away turns a
        # re-auth into a fresh-device challenge.
        _, text, _ = self._clear(GOOD)
        self.assertEqual(json.loads(text), {"session-id": "v"})

    def test_the_jar_stays_owner_only(self):
        _, _, mode = self._clear(GOOD)
        self.assertEqual(mode, 0o600)

    def test_an_already_stripped_jar_is_not_rewritten(self):
        wrote, text, _ = self._clear(BOUNCED)
        self.assertFalse(wrote)
        self.assertEqual(text, BOUNCED)

    def test_a_missing_jar_is_not_an_error(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertFalse(clear_dead_session(Path(d) / "cookies.json"))

    def test_sync_stops_believing_it_is_authenticated(self):
        # The assertion that matters, stated the way sync.rb tests it:
        # `cookies_authenticated?` fails at `jar.key?("x-main")` and never
        # reaches the expiry check, so the next run signs in for real.
        _, text, _ = self._clear(GOOD)
        self.assertNotIn("x-main", json.loads(text))


class JarGuardTest(unittest.TestCase):
    def guard(self, text: "str | None" = GOOD):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        path = Path(d) / "cookies.json"
        if text is not None:
            path.write_text(text)
        return JarGuard(path), path

    def test_it_snapshots_what_was_there(self):
        guard, _ = self.guard()
        self.assertEqual(guard.jar_before, GOOD)

    def test_a_first_ever_sync_has_nothing_to_snapshot(self):
        guard, _ = self.guard(None)
        self.assertIsNone(guard.jar_before)

    def test_an_unreadable_jar_says_the_net_is_down(self):
        # `None` is also how "first-ever sync" is spelled, so a silent fallback
        # left the two indistinguishable: the protection turned itself off and
        # the session died exactly as it did before the fix, with nothing in
        # the output to say the net was never strung up.
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        unreadable = Path(d) / "cookies.json"
        unreadable.mkdir()  # any OSError will do; this one needs no chmod games
        events = emitted(lambda: JarGuard(unreadable))
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["level"], "warn")
        self.assertIn("cannot read", events[0]["msg"])

    def test_a_first_ever_sync_is_not_warned_about(self):
        # The other half: nothing to protect is normal, not a problem.
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        self.assertEqual(emitted(lambda: JarGuard(Path(d) / "cookies.json")), [])

    def test_it_restores_a_stripped_jar(self):
        guard, path = self.guard()
        path.write_text(BOUNCED)
        self.assertTrue(silently(lambda: guard.restore("the test")))
        self.assertEqual(json.loads(path.read_text())["x-main"], "v")

    def test_clearing_latches_the_session_dead(self):
        # The interaction that makes the latch necessary rather than tidy: the
        # rejected path clears, and then the same cleanup every other run gets
        # would read that as a strip and put `x-main` straight back — finding 1
        # returning through the door marked "cleanup".
        guard, path = self.guard()
        silently(guard.clear)
        self.assertNotIn("x-main", json.loads(path.read_text()))
        self.assertFalse(silently(lambda: guard.restore("the test")))
        self.assertNotIn("x-main", json.loads(path.read_text()))

    def test_a_session_earned_during_the_run_is_the_one_protected(self):
        # The run that matters most is the one that had no usable jar: it spent
        # a real password (and possibly an OTP) and amazon-orders wrote the
        # result to disk mid-run. Restoring the jar this guard was *constructed*
        # with would throw that away and put the stale one back — and a stale
        # `x-main` still satisfies `cookies_authenticated?`, so the next run
        # skips login and feeds Amazon the placeholder password instead.
        guard, path = self.guard()
        path.write_text(FRESH)
        guard.resnapshot()
        path.write_text(BOUNCED)
        self.assertTrue(silently(lambda: guard.restore("the test")))
        self.assertEqual(json.loads(path.read_text())["x-main"], "earned")

    def test_resnapshotting_a_jar_that_is_gone_protects_nothing(self):
        # Not every login leaves a jar behind — and "nothing there" must not
        # mean "keep protecting the stale copy I read at startup".
        guard, path = self.guard()
        path.unlink()
        guard.resnapshot()
        self.assertIsNone(guard.jar_before)
        path.write_text(BOUNCED)
        self.assertFalse(silently(lambda: guard.restore("the test")))

    def test_the_latch_is_one_way(self):
        guard, path = self.guard()
        silently(guard.clear)
        for _ in range(3):
            silently(lambda: guard.restore("the test"))
        self.assertNotIn("x-main", json.loads(path.read_text()))

    def test_restoring_twice_is_a_no_op_the_second_time(self):
        # `finally` restores on top of the explicit call sites, so a second
        # restore has to be silent — not a warn line per failure path.
        guard, path = self.guard()
        path.write_text(BOUNCED)
        silently(lambda: guard.restore("the test"))
        self.assertEqual(emitted(lambda: guard.restore("the test")), [])


class WriteJarTest(unittest.TestCase):
    """The jar's only writer. Both callers exist to keep a bad jar off disk."""

    def test_it_lands_complete_and_0600(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "cookies.json"
            write_jar(path, GOOD)
            self.assertEqual(path.read_text(), GOOD)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_a_failed_write_leaves_the_previous_jar_intact(self):
        # `write_text` truncates first, so a crash mid-write used to leave a
        # half-written jar — surfacing much later as unparseable JSON, blaming
        # whichever command happened to read it next.
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "cookies.json"
            write_jar(path, GOOD)
            with self.assertRaises(TypeError):
                write_jar(path, None)  # type: ignore[arg-type]
            self.assertEqual(path.read_text(), GOOD)

    def test_it_leaves_no_temp_file_behind(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "cookies.json"
            with self.assertRaises(TypeError):
                write_jar(path, None)  # type: ignore[arg-type]
            self.assertEqual(list(Path(d).iterdir()), [])

    def test_overwriting_never_widens_the_mode(self):
        # The old order was write-then-chmod, leaving the file briefly 0644
        # with live session cookies in it.
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "cookies.json"
            path.write_text("old")
            os.chmod(path, 0o644)
            write_jar(path, GOOD)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)


class BareInterpreterImportTest(unittest.TestCase):
    """fetch.py has to import on an interpreter with no dependencies installed.

    CI runs `python -m unittest discover -s pyworker` against a bare 3.12 with
    no install step, on the stated grounds that the helpers under test are pure.
    So a module-scope `from amazonorders...` in fetch.py doesn't fail the one
    test that needs it — it makes this entire file uncollectable, and the error
    surfaces as `unittest.loader._FailedTest`, naming the loader rather than the
    import that broke. Locally it stays invisible, because `uv run pytest`
    installs amazon-orders and the import succeeds.

    Blocking the module in a subprocess reproduces CI on a machine where the
    package *is* installed, so the guard is meaningful in both environments.
    """

    def test_fetch_imports_without_amazonorders(self):
        script = textwrap.dedent(
            """
            import sys
            from importlib.abc import MetaPathFinder

            class NoAmazonOrders(MetaPathFinder):
                def find_spec(self, name, path=None, target=None):
                    if name == "amazonorders" or name.startswith("amazonorders."):
                        raise ImportError("simulating CI: amazon-orders is not installed")
                    return None

            sys.meta_path.insert(0, NoAmazonOrders())
            sys.path.insert(0, %r)
            import fetch
            print(",".join(sorted(fetch.AUTH_COOKIE_NAMES)))
            """
            % os.path.dirname(os.path.abspath(__file__))
        )
        proc = subprocess.run(
            [sys.executable, "-c", script], capture_output=True, text=True
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), ",".join(sorted(AUTH_COOKIE_NAMES)))


class FakeOrder:
    """The attributes `order_to_dict` and `_emit_progress` actually read."""

    def __init__(self, number, detailed=False):
        self.order_number = number
        self.order_placed_date = date(2026, 1, 2)
        self.grand_total = 9.99
        self.order_details_link = f"https://example.invalid/{number}"
        self.recipient = None
        self.items = []
        self.shipments = []
        self.detailed = detailed


@contextlib.contextmanager
def fake_amazonorders(login, history, get_order):
    """Stand in for the amazon-orders package for the length of a `main()` call.

    `main()` imports it lazily precisely so this module loads without it, which
    also means it can be swapped here. Nothing else gives these paths a seam: a
    detail fetch that comes back empty and a session Amazon rejects mid-run are
    wrong in terms of which events reach the parent and what the exit code is,
    and neither is reachable from a pure helper.
    """
    class AmazonOrdersConfig:
        def __init__(self, config_path=None, data=None):
            self.config_path, self.data = config_path, data

    class AmazonOrders:
        def __init__(self, session, config=None):
            self.session, self.config = session, config

        def get_order_history(self, year=None, full_details=False):
            return history(year)

        def get_order(self, order_number, clone=None):
            return get_order(order_number, clone)

    class IODefault:
        pass

    class AmazonSession:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

        def login(self):
            login()

    mods = {
        "amazonorders": _module("amazonorders", __version__="0.0.0-fake"),
        "amazonorders.conf": _module("amazonorders.conf", AmazonOrdersConfig=AmazonOrdersConfig),
        "amazonorders.orders": _module("amazonorders.orders", AmazonOrders=AmazonOrders),
        "amazonorders.session": _module(
            "amazonorders.session", IODefault=IODefault, AmazonSession=AmazonSession
        ),
    }
    with mock.patch.dict(sys.modules, mods):
        yield


def _module(name, **attrs):
    mod = types.ModuleType(name)
    mod.__dict__.update(attrs)
    return mod


class WorkerRunTest(unittest.TestCase):
    """End-to-end `main()` runs against the fake package above."""

    def run_worker(self, *, orders=(), login=None, get_order=None, jar=None, **overrides):
        home = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, home, True)
        cookies = home / "amazon" / "cache" / "cookies.json"
        cookies.parent.mkdir(parents=True)
        if jar is not None:
            cookies.write_text(jar)

        request = {
            "action": "sync",
            "email": "someone@example.invalid",
            "password": "unused-have-cookies",
            "years": [2026],
            "full_details": True,
            "detail_delay": 0,
            "detail_jitter": 0,
            "retry_backoff": [],
            **overrides,
        }
        def default_get_order(number, clone):
            return FakeOrder(number, detailed=True)

        buf = io.StringIO()
        with fake_amazonorders(
            login or (lambda: None),
            lambda year: list(orders),
            get_order or default_get_order,
        ), mock.patch.dict(
            os.environ, {"XDG_DATA_HOME": str(home), "XDG_CONFIG_HOME": str(home)}
        ), mock.patch.object(
            sys, "stdin", io.StringIO(json.dumps(request) + "\n")
        ), redirect_stdout(buf):
            code = fetch.main()

        events = [json.loads(line) for line in buf.getvalue().splitlines() if line.strip()]
        return code, events, cookies

    def kinds(self, events, name):
        return [e for e in events if e["event"] == name]

    def test_a_clean_run_reports_every_order(self):
        code, events, _ = self.run_worker(orders=[FakeOrder("111"), FakeOrder("222")])
        self.assertEqual(code, 0)
        self.assertEqual(
            [e["data"]["order_id"] for e in self.kinds(events, "order")], ["111", "222"]
        )
        self.assertEqual(self.kinds(events, "done")[0]["count"], 2)

    def test_an_order_whose_details_failed_is_never_handed_to_the_store(self):
        # The parent writes every `order` event it receives and then feeds those
        # ids back as `known_order_ids`, so emitting the history-page stub for a
        # failed detail fetch caches a detail-less order permanently — the next
        # sync skips it as already known. Being forgiving here is what makes the
        # damage unrecoverable.
        def get_order(number, clone):
            return None if number == "222" else FakeOrder(number, detailed=True)

        code, events, _ = self.run_worker(
            orders=[FakeOrder("111"), FakeOrder("222")], get_order=get_order
        )
        self.assertEqual([e["data"]["order_id"] for e in self.kinds(events, "order")], ["111"])
        self.assertEqual(code, 1)

    def test_a_run_that_lost_details_does_not_look_like_a_clean_sync(self):
        # Exit 0 with no terminal error is how cron and `&&` chains are told the
        # sync completed. A run that gave up on orders has not completed.
        code, events, _ = self.run_worker(
            orders=[FakeOrder("111")], get_order=lambda number, clone: None
        )
        self.assertEqual(code, 1)
        self.assertEqual(self.kinds(events, "done"), [])
        errors = self.kinds(events, "error")
        self.assertEqual(len(errors), 1)
        self.assertIn("111", errors[0]["msg"])

    def test_a_detail_fetch_that_raises_is_treated_as_a_loss_not_a_stub(self):
        def get_order(number, clone):
            raise RuntimeError("connection reset by peer")

        code, events, _ = self.run_worker(orders=[FakeOrder("111")], get_order=get_order)
        self.assertEqual(code, 1)
        self.assertEqual(self.kinds(events, "order"), [])

    def test_already_stored_orders_are_counted_as_skipped(self):
        # `skipped` reached the parent as a hard-coded 0, so the "(N skipped)"
        # the parent knows how to print could never appear.
        code, events, _ = self.run_worker(
            orders=[FakeOrder("111"), FakeOrder("222")], known_order_ids=["111"]
        )
        self.assertEqual(code, 0)
        done = self.kinds(events, "done")[0]
        self.assertEqual((done["count"], done["skipped"]), (1, 1))

    def test_a_session_earned_this_run_survives_a_later_failure(self):
        # Finding 7 end to end: the run starts with a stale jar, signs in for
        # real, and only then hits a failure that strips the jar. What gets put
        # back must be the session this run earned.
        cookies_holder = {}

        def login():
            cookies_holder["path"].write_text(FRESH)

        def history(year):
            cookies_holder["path"].write_text(BOUNCED)
            raise RuntimeError("500 Server Error")

        home = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, home, True)
        cookies = home / "amazon" / "cache" / "cookies.json"
        cookies.parent.mkdir(parents=True)
        cookies.write_text(GOOD)
        cookies_holder["path"] = cookies

        request = {
            "action": "sync",
            "email": "someone@example.invalid",
            "password": "unused-have-cookies",
            "years": [2026],
        }
        with fake_amazonorders(login, history, lambda n, c: None), mock.patch.dict(
            os.environ, {"XDG_DATA_HOME": str(home), "XDG_CONFIG_HOME": str(home)}
        ), mock.patch.object(
            sys, "stdin", io.StringIO(json.dumps(request) + "\n")
        ), redirect_stdout(io.StringIO()):
            code = fetch.main()

        self.assertEqual(code, 1)
        self.assertEqual(json.loads(cookies.read_text())["x-main"], "earned")


if __name__ == "__main__":
    unittest.main()
