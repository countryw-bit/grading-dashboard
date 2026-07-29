from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import secrets
import threading

@dataclass
class CredentialSession:
    username: str
    password: str
    expires_at: datetime

class CredentialStore:
    """Local MVP credential store.

    Passwords remain in server process memory only. The browser receives a
    random opaque session token, never the Oracle password.
    """

    def __init__(self) -> None:
        self._sessions: dict[str, CredentialSession] = {}
        self._lock = threading.Lock()

    def create(self, username: str, password: str, ttl_minutes: int) -> str:
        token = secrets.token_urlsafe(32)
        expires_at = datetime.now(timezone.utc) + timedelta(minutes=ttl_minutes)
        with self._lock:
            self._purge_expired()
            self._sessions[token] = CredentialSession(
                username=username,
                password=password,
                expires_at=expires_at,
            )
        return token

    def get(self, token: str | None) -> CredentialSession | None:
        if not token:
            return None
        with self._lock:
            self._purge_expired()
            session = self._sessions.get(token)
            if not session:
                return None
            if session.expires_at <= datetime.now(timezone.utc):
                self._sessions.pop(token, None)
                return None
            return session

    def delete(self, token: str | None) -> None:
        if not token:
            return
        with self._lock:
            self._sessions.pop(token, None)

    def _purge_expired(self) -> None:
        now = datetime.now(timezone.utc)
        expired = [k for k, v in self._sessions.items() if v.expires_at <= now]
        for key in expired:
            self._sessions.pop(key, None)

credential_store = CredentialStore()
