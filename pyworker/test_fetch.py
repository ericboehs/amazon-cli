"""Tests for the sync worker's cookie-jar protection.

amazon-orders rewrites the jar after every request, so a request that Amazon
bounces to sign-in persists a stripped jar over a working one. These cover the
decision about when to put the old jar back.
"""

import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

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

    def test_losing_any_single_auth_cookie_counts(self):
        for name in AUTH_COOKIE_NAMES:
            before = json.dumps({name: "v", "session-id": "v"})
            self.assertTrue(jar_regressed(before, BOUNCED), name)


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

    def test_it_says_which_run_did_the_damage(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "cookies.json"
            path.write_text(WIPED)
            events = emitted(lambda: restore_jar(path, GOOD, "the failed 2025 history fetch"))
            self.assertEqual(len(events), 1)
            self.assertEqual(events[0]["level"], "warn")
            self.assertIn("the failed 2025 history fetch", events[0]["msg"])


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
    def guard(self, text=GOOD):
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

    def test_it_restores_a_stripped_jar(self):
        guard, path = self.guard()
        path.write_text(BOUNCED)
        self.assertTrue(silently(lambda: guard.restore("the test")))
        self.assertEqual(path.read_text(), GOOD)

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


if __name__ == "__main__":
    unittest.main()
