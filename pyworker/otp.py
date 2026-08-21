"""One-time-password helpers, shared by the sync and login workers.

Both workers get their TOTP from the same place — a 1Password field read by
the Ruby side — and both have to turn it into six digits. Keeping one copy of
that means a fix to the parsing reaches both, and it puts the "never log the
secret" rule in a single file.
"""

from __future__ import annotations

import base64
import re
from typing import Any
from urllib.parse import parse_qs, urlsplit


def _validated_base32(secret: str) -> str:
    """The secret, cleaned up — or a ValueError naming the problem.

    pyotp decodes Base32 lazily, at the moment a code is generated, which in
    the login worker is once every two seconds inside the poll loop. An
    unusable secret therefore raised on every tick and got counted as a failed
    browser probe, and five ticks later the window was destroyed with a
    message about the network while the user was typing their 2FA code by
    hand. Failing here instead turns that into one line at startup.

    Spaces and dashes are stripped rather than rejected: 1Password displays
    TOTP secrets in groups of four, and a copied secret keeps them.
    """
    cleaned = re.sub(r"[\s-]", "", secret).upper()
    if not cleaned:
        raise ValueError("the OTP secret is blank")
    try:
        # Base32 wants a multiple of eight; the stored form usually isn't.
        base64.b32decode(cleaned + "=" * (-len(cleaned) % 8))
    except ValueError as e:  # binascii.Error is a ValueError
        # Never echo the value: a rejected secret is still a secret.
        raise ValueError(
            "the OTP secret is not valid Base32 — check that the reference "
            "points at a one-time-password field and not a password field"
        ) from e
    return cleaned


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
        return _validated_base32(value)

    parsed = urlsplit(value)
    secret = parse_qs(parsed.query).get("secret", [None])[0]
    if not secret:
        # Never include the URI in this message: its query string is the secret.
        raise ValueError("the otpauth URI has no secret parameter")
    return _validated_base32(secret)


def current_code(secret: str) -> str:
    """The six digits valid right now for ``secret``.

    pyotp is imported here rather than at module scope: CI runs these tests on
    a bare interpreter with no dependencies installed, and a module-level
    import would make every test in the file uncollectable instead of skipping
    the one that needs it.
    """
    import pyotp

    return pyotp.TOTP(secret).now()
