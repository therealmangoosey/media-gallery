"""Authentication, password hashing, and signed session tokens.

Sessions are *stateless* signed cookies: a token embeds its own expiry and is
HMAC-signed with a persistent secret key. This survives app restarts (no
in-memory session dict to lose) and works across processes, while remaining
tamper-proof.
"""

import base64
import hashlib
import hmac
import json
import os
import secrets
import time

from argon2 import PasswordHasher
from argon2.exceptions import Argon2Error, InvalidHashError, VerificationError

from .config import BASE_DIR, settings

SESSION_COOKIE_NAME = "session_id"
CSRF_COOKIE_NAME = "csrf"

_ph = PasswordHasher()

# Secret key is persisted to the repo root so tokens stay valid across
# restarts. It is auto-generated on first run (chmod 600).
_SECRET_PATH = os.path.join(BASE_DIR, ".secret_key")


def get_secret_key() -> str:
    env_key = os.environ.get("GALLERY_SECRET_KEY")
    if env_key:
        return env_key
    if os.path.exists(_SECRET_PATH):
        with open(_SECRET_PATH, "r", encoding="utf-8") as f:
            key = f.read().strip()
        if key:
            return key
    key = secrets.token_urlsafe(48)
    try:
        with open(_SECRET_PATH, "w", encoding="utf-8") as f:
            f.write(key + "\n")
        os.chmod(_SECRET_PATH, 0o600)
    except OSError:
        # Read-only filesystem fallback: an ephemeral key still works, tokens
        # just won't survive a restart.
        pass
    return key


def _b64encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _b64decode(text: str) -> bytes:
    padding = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + padding)


def _sign(payload_b64: str) -> str:
    secret = get_secret_key().encode("utf-8")
    digest = hmac.new(secret, payload_b64.encode("ascii"), hashlib.sha256).digest()
    return _b64encode(digest)


def hash_password(password: str) -> str:
    return _ph.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    if not password_hash or not password:
        return False
    try:
        return _ph.verify(password_hash, password)
    except (Argon2Error, InvalidHashError, VerificationError, TypeError, ValueError):
        return False


def create_session(admin_id: str = "admin") -> str:
    ttl = settings.get_int("admin.session_hours", 24) * 3600
    payload = {"admin": admin_id, "exp": int(time.time()) + ttl}
    payload_b64 = _b64encode(json.dumps(payload).encode("utf-8"))
    return f"{payload_b64}.{_sign(payload_b64)}"


def _parse_session(token: str):
    """Return the payload dict if valid & unexpired, else None."""
    if not token or "." not in token:
        return None
    payload_b64, signature = token.split(".", 1)
    expected = _sign(payload_b64)
    if not hmac.compare_digest(signature, expected):
        return None
    try:
        payload = json.loads(_b64decode(payload_b64).decode("utf-8"))
    except (ValueError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict):
        return None
    if int(payload.get("exp", 0)) < int(time.time()):
        return None
    return payload


def validate_session(session_id: str) -> bool:
    return _parse_session(session_id) is not None


def session_admin_id(session_id: str):
    payload = _parse_session(session_id)
    return payload.get("admin") if payload else None


def delete_session(session_id: str) -> None:
    """Stateless sessions have nothing to revoke server-side.

    The client clears the cookie on logout. Kept for API compatibility.
    """
    return None


def new_csrf_token() -> str:
    return secrets.token_urlsafe(32)


def csrf_matches(request_token, cookie_token) -> bool:
    if not request_token or not cookie_token:
        return False
    return hmac.compare_digest(request_token, cookie_token)
