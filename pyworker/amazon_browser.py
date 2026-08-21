"""amazon-orders challenge forms backed by a coherent headless Chrome.

Playwright's stock launcher advertises automation to bot sensors.  Amazon's
JavaScript challenge then waits until timeout even though the browser extra is
installed.  These forms keep amazon-orders' challenge detection and cookie
bridging, but launch the installed Chrome with the two settings that make its
browser-visible identity internally consistent:

* disable ``AutomationControlled`` so ``navigator.webdriver`` is false; and
* replace HeadlessChrome's UA with the UA this same Chrome uses when headed.

The launch uses a persistent profile because challenge trust can be scoped to
the browser profile.  See the private Akamai sensor research in the wiki and
the sibling tractor-supply-cli's Browser::Chrome implementation.
"""

from __future__ import annotations

import logging
import os
import platform
import re
import subprocess
from pathlib import Path
from typing import Any

from amazonorders.contrib.browser.playwright import (
    PlaywrightAcicForm,
    PlaywrightJSAuthForm,
)
from amazonorders.exception import AmazonOrdersError

logger = logging.getLogger(__name__)

CHROME_BINARIES = (
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/usr/bin/google-chrome",
    "/usr/bin/google-chrome-stable",
)

PLATFORMS = {
    "Darwin": "Macintosh; Intel Mac OS X 10_15_7",
    "Linux": "X11; Linux x86_64",
}


def chrome_binary() -> str:
    override = os.environ.get("AMAZON_CHROME_PATH")
    candidates = (override,) + CHROME_BINARIES if override else CHROME_BINARIES
    binary = next((path for path in candidates if path and os.access(path, os.X_OK)), None)
    if binary:
        return binary
    raise AmazonOrdersError(
        "Google Chrome was not found; install it or set AMAZON_CHROME_PATH"
    )


def chrome_user_agent(binary: str | None = None, system: str | None = None) -> str:
    binary = binary or chrome_binary()
    try:
        version_line = subprocess.run(
            [binary, "--version"], check=True, capture_output=True, text=True
        ).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        raise AmazonOrdersError(f"could not read the Chrome version from {binary}: {e}") from e

    match = re.search(r"\d+", version_line)
    if not match:
        raise AmazonOrdersError(f"Chrome reported an unreadable version: {version_line.strip()!r}")

    host = system or platform.system()
    platform_token = PLATFORMS.get(host)
    if not platform_token:
        raise AmazonOrdersError(
            f"no coherent headless Chrome user agent is known for {host}; "
            "run on macOS/Linux or add its platform token"
        )

    # Chrome's reduced UA exposes the real major and zeroes the other fields.
    # Building this from the binary keeps it honest after Chrome upgrades.
    version = f"{match.group(0)}.0.0.0"
    return (
        f"Mozilla/5.0 ({platform_token}) AppleWebKit/537.36 "
        f"(KHTML, like Gecko) Chrome/{version} Safari/537.36"
    )


def chrome_launch_args(binary: str | None = None) -> list[str]:
    binary = binary or chrome_binary()
    return [
        "--disable-blink-features=AutomationControlled",
        f"--user-agent={chrome_user_agent(binary)}",
    ]


class CoherentChromeForm:
    """Override amazon-orders' Playwright launch, preserving its form logic."""

    def submit(self, last_response: Any) -> Any:
        if not self.amazon_session:
            raise AmazonOrdersError(f"Call {type(self).__name__}.select_form() first.")

        try:
            from playwright.sync_api import (
                TimeoutError as PlaywrightTimeoutError,
                sync_playwright,
            )
        except ImportError as e:
            raise AmazonOrdersError(
                "JavaScript challenge handling requires Playwright; run `uv sync` in pyworker"
            ) from e

        session = self.amazon_session
        debug = session.debug
        message = "Info: A coherent headless Chrome is handling a JavaScript authentication challenge."
        logger.info(message)
        session.io.echo(message)
        output_dir = self.config.output_dir if debug else None
        original_url = last_response.url
        binary = chrome_binary()
        profile = Path(self.config.cookie_jar_path).with_name("challenge-chrome-profile")
        profile.mkdir(parents=True, exist_ok=True)

        with sync_playwright() as playwright:
            context = playwright.chromium.launch_persistent_context(
                str(profile),
                executable_path=binary,
                headless=True,
                args=chrome_launch_args(binary),
            )
            try:
                self._inject_cookies(context, original_url)
                page = context.pages[0] if context.pages else context.new_page()
                page.goto(original_url)
                logger.debug("Browser navigated to challenge URL: %s", page.url)
                self._save_debug_snapshot(page, output_dir, "browser-challenge")
                self._on_challenge_page(page, context, output_dir)

                try:
                    page.wait_for_url(
                        lambda url: not self._is_challenge_url(url, original_url),
                        timeout=self.config.browser_timeout * 1000,
                    )
                except PlaywrightTimeoutError as e:
                    logger.debug("Browser timed out at URL: %s", page.url)
                    self._save_debug_snapshot(page, output_dir, "browser-timeout")
                    raise AmazonOrdersError(
                        "Coherent headless Chrome timed out waiting for the "
                        "JavaScript challenge to resolve."
                    ) from e

                final_url = page.url
                logger.debug("Browser challenge resolved, final URL: %s", final_url)
                self._save_debug_snapshot(page, output_dir, "browser-resolved")
                self._harvest_cookies(context)
            finally:
                context.close()

        response = session.get(final_url, persist_cookies=True)
        self.clear_form()
        return response


class CoherentPlaywrightAcicForm(CoherentChromeForm, PlaywrightAcicForm):
    """ACIC handler using coherent headless Chrome."""


class CoherentPlaywrightJSAuthForm(CoherentChromeForm, PlaywrightJSAuthForm):
    """Generic JavaScript challenge handler using coherent headless Chrome."""
