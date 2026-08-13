"""Central configuration loader.

Settings live in ``settings.json`` at the repository root. Every value has a
sensible default, so the app works out of the box — you only need to edit the
file when you want to change something (site name, description, colors,
upload limits, moderation thresholds, etc.).

A small number of values can also be overridden with environment variables,
which is handy for secrets and for the installer:

    GALLERY_SITE_NAME, GALLERY_MAX_FILE_MB, GALLERY_UPLOADS_ENABLED,
    GALLERY_AUTO_APPROVE_THRESHOLD, GALLERY_AUTO_REJECT_THRESHOLD,
    GALLERY_COOKIE_SECURE

Environment variables win over ``settings.json``.
"""

import json
import os
from copy import deepcopy

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SETTINGS_PATH = os.path.join(BASE_DIR, "settings.json")

# Defaults are the single source of truth for every supported key. The
# committed settings.json mirrors these; keeping them here means missing keys
# are always filled in gracefully instead of raising KeyError at runtime.
DEFAULTS = {
    "site": {
        "name": "Media Gallery",
        "tagline": "A private, self-hosted image gallery",
        "description": "Your own fast, private gallery — upload, moderate, and share images on your own terms.",
        "emoji": "🖼️",
        "theme_color": "#7c3aed",
        "accent_color": "#a78bfa",
        "footer_text": "Self-hosted · Powered by Media Gallery",
    },
    "uploads": {
        "enabled": True,
        "max_file_mb": 20,
        "rate_limit_count": 10,
        "rate_limit_window_seconds": 600,
    },
    "gallery": {
        "page_size": 60,
        "allow_reports": True,
    },
    "moderation": {
        "auto_approve_threshold": 0.2,
        "auto_reject_threshold": 0.8,
        "blur_quarantine_thumbnails": True,
    },
    "admin": {
        "session_hours": 24,
    },
    "security": {
        "cookie_secure": False,
        "trust_proxy_headers": True,
        "frame_deny": True,
    },
}


def _deep_merge(base: dict, override: dict) -> dict:
    """Recursively merge ``override`` into a copy of ``base``."""
    result = deepcopy(base)
    for key, value in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = _deep_merge(result[key], value)
        else:
            result[key] = deepcopy(value)
    return result


def _load_settings() -> dict:
    data = deepcopy(DEFAULTS)
    if os.path.exists(SETTINGS_PATH):
        try:
            with open(SETTINGS_PATH, "r", encoding="utf-8") as f:
                raw = json.load(f)
            if isinstance(raw, dict):
                data = _deep_merge(data, raw)
        except (json.JSONDecodeError, OSError):
            # A broken settings file should never take the app down; fall back
            # to defaults and let the caller know via the .invalid flag.
            data["_invalid"] = True
    else:
        _write_defaults()
    return data


def _write_defaults():
    """Create a settings.json with defaults so there is an editable file to
    discover. Best-effort: silently ignore read-only filesystems."""
    try:
        with open(SETTINGS_PATH, "w", encoding="utf-8") as f:
            json.dump(DEFAULTS, f, indent=2, ensure_ascii=False)
            f.write("\n")
    except OSError:
        pass


class Settings:
    """Dotted-path access to configuration, e.g. ``settings.get("site.name")``."""

    def __init__(self):
        self._data = _load_settings()
        self.invalid = bool(self._data.pop("_invalid", False))

    def get(self, dotted_key, default=None):
        node = self._data
        for part in dotted_key.split("."):
            if not isinstance(node, dict) or part not in node:
                return default
            node = node[part]
        return node

    def get_float(self, dotted_key, default=0.0):
        try:
            return float(self.get(dotted_key, default))
        except (TypeError, ValueError):
            return default

    def get_int(self, dotted_key, default=0):
        try:
            return int(self.get(dotted_key, default))
        except (TypeError, ValueError):
            return default

    def get_bool(self, dotted_key, default=False):
        value = self.get(dotted_key, default)
        if isinstance(value, bool):
            return value
        if isinstance(value, str):
            return value.strip().lower() in ("1", "true", "yes", "on")
        return bool(value)


settings = Settings()

# Environment overrides (secrets & installer-provided values win over the file).
_ENV_MAP = {
    "GALLERY_SITE_NAME": "site.name",
    "GALLERY_MAX_FILE_MB": "uploads.max_file_mb",
    "GALLERY_UPLOADS_ENABLED": "uploads.enabled",
    "GALLERY_AUTO_APPROVE_THRESHOLD": "moderation.auto_approve_threshold",
    "GALLERY_AUTO_REJECT_THRESHOLD": "moderation.auto_reject_threshold",
    "GALLERY_COOKIE_SECURE": "security.cookie_secure",
}


def _apply_env_overrides():
    for env_key, dotted in _ENV_MAP.items():
        if env_key in os.environ:
            _set_dotted(settings._data, dotted, os.environ[env_key])


def _set_dotted(node: dict, dotted_key: str, value):
    parts = dotted_key.split(".")
    for part in parts[:-1]:
        node = node.setdefault(part, {})
    node[parts[-1]] = value


_apply_env_overrides()
