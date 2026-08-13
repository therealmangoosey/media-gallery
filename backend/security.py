from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
import secrets
import time

ph = PasswordHasher()

def hash_password(password: str) -> str:
    return ph.hash(password)

def verify_password(hash: str, password: str) -> bool:
    try:
        return ph.verify(hash, password)
    except VerifyMismatchError:
        return False

# Simple session management in memory for now, or use a signed cookie.
# For simplicity and security, we'll use a secret key for session cookies.

SESSION_COOKIE_NAME = "session_id"
sessions = {} # session_id -> {expiry, admin_id}

def create_session(admin_id: str):
    session_id = secrets.token_urlsafe(32)
    expiry = time.time() + 3600 * 24 # 24 hours
    sessions[session_id] = {"admin_id": admin_id, "expiry": expiry}
    return session_id

def validate_session(session_id: str):
    session = sessions.get(session_id)
    if not session:
        return False
    if time.time() > session["expiry"]:
        del sessions[session_id]
        return False
    return True

def delete_session(session_id: str):
    if session_id in sessions:
        del sessions[session_id]
