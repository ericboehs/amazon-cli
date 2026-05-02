"""
Interactive Amazon login via Playwright.

Opens a real (headed) Chromium window pointed at amazon.com sign-in. The user
logs in themselves — including any captcha, 2FA, or "verify it's you" prompts
that the headless `amazon-orders` flow can't handle.

Once authenticated (Amazon home page shows the signed-in nav), we dump the
session cookies into amazon-orders' `cookie_jar_path` format so a subsequent
`amazon sync` skips the login flow entirely.

Output format on stdout (NDJSON):
    {"event":"log","msg":"..."}
    {"event":"navigate","url":"..."}
    {"event":"done","cookies_path":"...","count":N}
    {"event":"error","msg":"..."}
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any


def emit(event: str, **fields: Any) -> None:
    sys.stdout.write(json.dumps({"event": event, **fields}) + "\n")
    sys.stdout.flush()


def xdg_data_home() -> Path:
    base = os.environ.get("XDG_DATA_HOME")
    return Path(base) if base else Path.home() / ".local/share"


def xdg_config_home() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME")
    return Path(base) if base else Path.home() / ".config"


def load_email() -> str | None:
    cfg = xdg_config_home() / "amazon" / "config.json"
    if not cfg.exists():
        return None
    try:
        data = json.loads(cfg.read_text())
        email = data.get("email")
        return email if email and email != "you@example.com" else None
    except Exception:  # noqa: BLE001
        return None


SIGN_IN_URL = (
    "https://www.amazon.com/ap/signin"
    "?openid.pape.max_auth_age=0"
    "&openid.return_to=https%3A%2F%2Fwww.amazon.com%2F"
    "&openid.identity=http%3A%2F%2Fspecs.openid.net%2Fauth%2F2.0%2Fidentifier_select"
    "&openid.assoc_handle=usflex"
    "&openid.mode=checkid_setup"
    "&openid.claimed_id=http%3A%2F%2Fspecs.openid.net%2Fauth%2F2.0%2Fidentifier_select"
    "&openid.ns=http%3A%2F%2Fspecs.openid.net%2Fauth%2F2.0"
)


def main() -> int:
    try:
        from playwright.sync_api import sync_playwright
    except ImportError as e:
        emit("error", msg=f"playwright not installed: {e}")
        return 2

    cache_dir = xdg_data_home() / "amazon" / "cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(cache_dir, 0o700)
    except OSError:
        pass
    cookies_path = cache_dir / "cookies.json"
    storage_state_path = cache_dir / "storage_state.json"

    emit("log", msg=f"opening browser; cookies will be saved to {cookies_path}")

    with sync_playwright() as p:
        # Prefer real Chrome (proper macOS focus + menu bar). Fall back to
        # bundled Chromium if Chrome isn't installed.
        browser = None
        last_err: Exception | None = None
        try:
            browser = p.chromium.launch(channel="chrome", headless=False)
            emit("log", msg="launched browser (channel=chrome)")
        except Exception as e:  # noqa: BLE001
            last_err = e
            try:
                browser = p.chromium.launch(headless=False)
                emit("log", msg="launched browser (channel=chromium)")
            except Exception as e2:  # noqa: BLE001
                last_err = e2
        if browser is None:
            emit(
                "error",
                msg=(
                    f"failed to launch browser: {last_err}. "
                    "Run: cd pyworker && .venv/bin/python -m playwright install chromium"
                ),
            )
            return 1

        context_args: dict[str, Any] = {
            "viewport": {"width": 1280, "height": 900},
            "user_agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
            ),
        }
        if storage_state_path.exists():
            context_args["storage_state"] = str(storage_state_path)
            emit("log", msg="reusing prior storage_state (may already be logged in)")

        context = browser.new_context(**context_args)
        page = context.new_page()
        emit("navigate", url=SIGN_IN_URL)
        page.goto(SIGN_IN_URL, wait_until="domcontentloaded")

        email = load_email()
        if email:
            try:
                email_input = page.locator("#ap_email_login, #ap_email").first
                email_input.wait_for(state="visible", timeout=5000)
                email_input.fill(email)
                emit("log", msg=f"pre-filled email: {email}")
                cont = page.locator("#continue, input[type=submit][aria-labelledby*=continue]").first
                if cont.count() > 0:
                    cont.click()
                    emit("log", msg="clicked Continue — finish password + any 2FA in the window")
            except Exception as e:  # noqa: BLE001
                emit("log", msg=f"could not pre-fill email ({e}); continue manually")

        emit(
            "log",
            msg=(
                "Sign in to Amazon in the browser window. Solve any captcha or 2FA. "
                "When you reach the signed-in homepage, this script will detect it "
                "automatically and save cookies."
            ),
        )

        # Poll for authenticated state. Two signals:
        #   1) `x-main` cookie present (amazon-orders' COOKIES_SET_WHEN_AUTHENTICATED)
        #   2) URL is on amazon.com root or a non-auth path AND nav-item-signout exists
        deadline = time.time() + 600  # 10 minutes
        authenticated = False
        while time.time() < deadline:
            cookies = context.cookies()
            names = {c.get("name") for c in cookies}
            if "x-main" in names:
                # Also confirm we're not still on the signin page
                try:
                    if "/ap/signin" not in page.url:
                        authenticated = True
                        break
                except Exception:  # noqa: BLE001
                    pass
            time.sleep(2)

        if not authenticated:
            emit("error", msg="timed out waiting for sign-in (10 min). Cookies not saved.")
            context.close()
            browser.close()
            return 1

        # Persist cookies in two places:
        #   1) amazon-orders cookie_jar_path: simple {name: value} dict
        #   2) Playwright storageState: full storage for future Playwright runs (e.g., `amazon buy`)
        cookies = context.cookies()
        ao_cookies = {
            c.get("name", ""): c.get("value", "")
            for c in cookies
            if c.get("domain", "").endswith("amazon.com") and c.get("name")
        }
        cookies_path.write_text(json.dumps(ao_cookies))
        os.chmod(cookies_path, 0o600)

        context.storage_state(path=str(storage_state_path))
        os.chmod(storage_state_path, 0o600)

        emit("done", cookies_path=str(cookies_path), count=len(ao_cookies))

        context.close()
        browser.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
