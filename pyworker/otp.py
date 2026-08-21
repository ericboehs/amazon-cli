"""One-time-password helpers, shared by the sync and login workers.

Both workers get their TOTP from the same place — a 1Password field read by
the Ruby side — and both have to turn it into six digits. Keeping one copy of
that means a fix to the parsing reaches both, and it puts the "never log the
secret" rule in a single file.
"""

from __future__ import annotations

from typing import Any
from urllib.parse import parse_qs, urlsplit


def normalize_otp_secret(value: Any) -> str | None:
    """Turn a 1Password TOTP field into a raw Base32 secret.

    ``op read`` returns an ``otpauth://`` URI for a one-time-password field,
    while pyotp wants the Base32 secret out of its query string. Accept both
    shapes so config can hold an ordinary field reference instead of a copy of
    the secret itself.
    """
    if value is None:
        return None
    if not isinstance(value, str) or not value:
        raise ValueError("the OTP value must be a non-empty string")
    if not value.lower().startswith("otpauth://"):
        return value

    parsed = urlsplit(value)
    secret = parse_qs(parsed.query).get("secret", [None])[0]
    if not secret:
        # Never include the URI in this message: its query string is the secret.
        raise ValueError("the otpauth URI has no secret parameter")
    return secret


def current_code(secret: str) -> str:
    """The six digits valid right now for ``secret``.

    pyotp is imported here rather than at module scope: CI runs these tests on
    a bare interpreter with no dependencies installed, and a module-level
    import would make every test in the file uncollectable instead of skipping
    the one that needs it.
    """
    import pyotp

    return pyotp.TOTP(secret).now()
