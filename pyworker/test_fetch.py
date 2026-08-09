"""Tests for the sync worker's cookie-jar protection.

amazon-orders rewrites the jar after every request, so a request that Amazon
bounces to sign-in persists a stripped jar over a working one. These cover the
decision about when to put the old jar back.
"""

import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fetch import (  # noqa: E402
    AUTH_COOKIE_NAMES,
    jar_cookie_names,
    jar_regressed,
)

# Values here are meaningless fixtures — the code under test only reads names.
GOOD = json.dumps({"x-main": "v", "at-main": "v", "session-id": "v", "ubid-main": "v"})
WIPED = json.dumps({})
# What a sign-in bounce actually leaves: the anonymous cookies survive, the
# authenticated ones are expired out.
BOUNCED = json.dumps({"session-id": "v", "session-id-time": "v"})


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


class RestoreJarBehaviorTest(unittest.TestCase):
    """The write-back itself, exercised against a real file.

    jar_regressed is the decision; this is the part that has to not lose data.
    """

    def _restore(self, before_text, after_text):
        """Mirror of the restore_jar closure in main(), against a temp file."""
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "cookies.json"
            path.write_text(after_text)
            if jar_regressed(before_text, path.read_text()):
                path.write_text(before_text)
                os.chmod(path, 0o600)
            return path.read_text(), path.stat().st_mode & 0o777

    def test_a_wiped_jar_is_restored_byte_for_byte(self):
        text, _ = self._restore(GOOD, WIPED)
        self.assertEqual(text, GOOD)

    def test_restored_jars_stay_owner_only(self):
        # The jar holds live session cookies; restoring it must not widen it.
        _, mode = self._restore(GOOD, WIPED)
        self.assertEqual(mode, 0o600)

    def test_a_healthy_write_is_left_alone(self):
        fresher = json.dumps({"x-main": "v2", "at-main": "v2", "ubid-main": "v2"})
        text, _ = self._restore(GOOD, fresher)
        self.assertEqual(text, fresher)


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
