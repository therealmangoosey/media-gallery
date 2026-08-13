# Security Audit — Media Gallery

**Scope:** backend (`*.py`), `scripts/*.sh`, `install.sh`, `requirements.txt`,
`settings.example.json`, `.gitignore`
**Standards referenced:** OWASP Top 10 (2021), CWE Top 25, CIS Benchmarks,
NIST SP 800-53
**Status:** ✅ = remediated in-tree · 🔶 = remediation recommended

---

### ⚠️ [High] - Unpinned / floating dependencies (Supply-chain risk) / CWE-1104, CWE-1357

* **Location:** `requirements.txt` (all entries), `install.sh` (`pip install -r …`), `install.sh` (`pip install tflite-runtime`)

* **The Risk:** Every requirement was listed with no version bound, so `pip`
  resolved the *latest* version at install time. This means (a) the exact code
  an operator runs is not reproducible, and (b) a compromised or broken new
  release of an image-processing dependency (`Pillow`, `numpy`) or the web
  framework (`fastapi`/`starlette`) is pulled silently. `Pillow` and `starlette`
  have historically carried remote-exploitable CVEs (e.g. image decode
  memory-corruption, DoS). With no lockfile and no scanner in CI, the project
  cannot detect when a transitive dependency becomes vulnerable.

* **Secure Remediation:**

```text
# requirements.txt — pin every direct dependency to a known-good version.
# Target: Python >=3.11 (Debian bookworm/trixie). Re-verify with `pip-audit`.
fastapi==0.141.1
uvicorn[standard]==0.52.3
sqlalchemy==2.0.52
pillow==12.3.0
argon2-cffi==25.1.0
numpy==2.2.6        # 2.5.x requires Python >=3.12; keep 2.2.x for 3.11
python-multipart==0.0.32
```

```yaml
# .github/workflows/security.yml — continuous dependency + SAST scanning
name: security
on: [push, pull_request]
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.11" }
      - run: pip install pip-audit
      - run: pip-audit -r requirements.txt
      - uses: github/codeql-action/init@v3
        with: { languages: python }
      - uses: github/codeql-action/analyze@v3
```

---

### ⚠️ [Medium] - Secrets written to `.env` with default permissions / CWE-732 (Incorrect Permission Assignment) ✅

* **Location:** `install.sh` — "4. Save Configuration" block (`cat <<EOF > .env`)

* **The Risk:** The Cloudflare **Tunnel Token** (which grants control of the
  tunnel into the phone) was written to `.env` with the process umask (typically
  `0644`), leaving it readable by any other app/process on the device. An
  attacker who reads it can operate the tunnel. The admin password *hash* was
  correctly `chmod 600`, but the token was not.

* **Secure Remediation:**

```bash
cat <<EOF > .env
DOMAIN='$DOMAIN'
TUNNEL_TOKEN='$TUNNEL_TOKEN'
AUTO_APPROVE_THRESHOLD='$THRESHOLD_APPROVE'
EOF
chmod 600 .env
```

---

### ⚠️ [Medium] - OS command injection via sourcing `.env` / CWE-78, CWE-94 ✅

* **Location:** `scripts/manage.sh` `start()` — `. "$APP_DIR/.env"`; `install.sh`
  — unquoted `KEY=$VALUE` lines written to `.env`

* **The Risk:** `manage.sh` loaded `.env` with `source`/`.`, which **executes**
  the file as shell. Values are read interactively in `install.sh` and written
  unquoted. A value containing shell metacharacters (e.g. a tunnel token or
  domain containing `` ` `` `$()` `;` or a newline, whether maliciously supplied
  or the result of a paste error) becomes arbitrary code executed with the
  operator's privileges at every `start`.

* **Secure Remediation:**

```bash
# manage.sh — parse KEY=VALUE without evaluating it as shell
load_env_safe() {
    local file="$1" line key value
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac
        key="${line%%=*}"; [ -z "$key" ] && continue
        value="${line#*=}"
        case "$value" in
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
        esac
        export "$key=$value"
    done < "$file"
}
# …call load_env_safe "$APP_DIR/.env" instead of sourcing it
```

```bash
# install.sh — write single-quoted values and reject unsafe characters
for _v in "$DOMAIN" "$TUNNEL_TOKEN"; do
    case "$_v" in
        *"'"*|*$'\n'*|*$'\r'*) echo "Error: unsupported character in value."; exit 1 ;;
    esac
done
cat <<EOF > .env
DOMAIN='$DOMAIN'
TUNNEL_TOKEN='$TUNNEL_TOKEN'
AUTO_APPROVE_THRESHOLD='$THRESHOLD_APPROVE'
EOF
chmod 600 .env
```

---

### ⚠️ [Medium] - Sensitive cookies without the `Secure` flag / CWE-614 🔶

* **Location:** `backend/main.py` — `set_cookie(...)` for `SESSION_COOKIE_NAME`
  and `CSRF_COOKIE_NAME` (`secure=COOKIE_SECURE`); `backend/config.py`
  `security.cookie_secure` defaults to `false`

* **The Risk:** The admin session token (a signed, bearer credential) and the
  CSRF token are transmitted without the `Secure` attribute unless the operator
  opts in. If the gallery is ever reached over plaintext HTTP (misconfigured
  tunnel, local test), the session cookie leaks to any on-path observer,
  allowing full admin takeover. HSTS is emitted, but HSTS only helps after the
  first successful HTTPS visit and cannot protect the very first request.

* **Secure Remediation:**

```jsonc
// settings.json — enable for production (the gallery is served over HTTPS via
// Cloudflare, so the browser still presents an HTTPS origin to the user)
"security": { "cookie_secure": true, "trust_proxy_headers": true, "frame_deny": true }
```

```python
# backend/main.py — optionally default to Secure unless explicitly disabled
COOKIE_SECURE = settings.get_bool("security.cookie_secure", True)  # safer default
```

---

### ⚠️ [Medium] - Backup passphrase exposed on the command line / CWE-522, CWE-214 ✅

* **Location:** `scripts/manage.sh` `backup()` and `restore()` —
  `gpg --passphrase "$BACKUP_PASS"`

* **The Risk:** The backup encryption passphrase was passed as an argv element,
  which is visible in `ps`, `/proc/<pid>/cmdline`, and shell job listings to
  any same-user (or root) process. If the backup encrypts the DB + public
  images, the passphrase disclosure defeats the encryption.

* **Secure Remediation:**

```bash
# Pass the passphrase via stdin (never in argv)
gpg --symmetric --batch --passphrase-fd 0 "$BACKUP_FILE" <<< "$BACKUP_PASS"
# …
gpg --decrypt --batch --passphrase-fd 0 "$FILE" > "$TMP_FILE" <<< "$BACKUP_PASS"
```

---

### ⚠️ [Low] - Raw client IPs persisted in the reports table / CWE-359 ✅

* **Location:** `backend/main.py` `submit_report()` (`ip_hash=ip`); column
  declared in `backend/database.py` `Report.ip_hash`

* **The Risk:** The field is named `ip_hash` but stored the *plaintext* client
  IP of every reporter. If the SQLite DB is ever leaked (backup mishap, device
  compromise), this deanonymizes reporters — a privacy violation, especially
  for a moderation/reporting feature where anonymity is expected.

* **Secure Remediation:**

```python
import hashlib, hmac
from .security import get_secret_key

def _hash_client_ip(ip: str) -> str:
    return hmac.new(get_secret_key().encode(), ip.encode(), hashlib.sha256).hexdigest()

# …in submit_report():
ip_hash=_hash_client_ip(ip),
```

---

### ⚠️ [Low] - Admin password hash passed through the process environment / CWE-522 🔶

* **Location:** `install.sh` (`env ADMIN_PASS="$ADMIN_PASS"`), `scripts/manage.sh`
  `start()` (`export ADMIN_PASSWORD_HASH`, re-exported into the proot command)

* **The Risk:** The admin password (install) and its Argon2id hash (runtime) are
  placed in the process environment, which is readable via
  `/proc/<pid>/environ` and inherited by every child process. The hash is not
  directly reusable as a credential, but it enables offline cracking and should
  not be needlessly exposed.

* **Secure Remediation:**

```bash
# install.sh — pass the password via a 0600 temp file, not the environment
PW_FILE="$APP_DIR/.install_admin_pass"
printf '%s' "$ADMIN_PASS" > "$PW_FILE" && chmod 600 "$PW_FILE"
proot-distro login debian -- env PW_FILE="$PW_FILE" APP_NAME="$APP_NAME" bash <<'EOF'
REPO_DIR="$HOME/$APP_NAME"; [ -d "$REPO_DIR" ] || REPO_DIR="/root/$APP_NAME"
ADMIN_PASS="$(cat "$REPO_DIR/$PW_FILE")"
# …hash ADMIN_PASS, then:
rm -f "$REPO_DIR/$PW_FILE"
EOF
rm -f "$APP_DIR/$PW_FILE"
```

```bash
# manage.sh — read the hash file inside the proot rather than re-exporting it
# (avoids the value appearing in the proot-distro command line / environment)
```

---

### ⚠️ [Low] - Reliance on Pillow's default decompression-bomb limit / CWE-400, CWE-789 ✅

* **Location:** `backend/image_processing.py` `validate_image()` / `process_and_save()`

* **The Risk:** A hostile image can declare small header dimensions but expand to
  an enormous bitmap on decode (a "decompression bomb"), exhausting RAM on the
  phone. Header-based `MAX_PIXELS` checks help, but an explicit bound on the
  decoder is the authoritative defense.

* **Secure Remediation:**

```python
from PIL import Image as PILImage
MAX_PIXELS = 40_000_000
PILImage.MAX_IMAGE_PIXELS = MAX_PIXELS   # enforced by Pillow at decode time
```

---

### ⚠️ [Low] - In-memory rate limiting is per-process and non-persistent / CWE-799 🔶

* **Location:** `backend/main.py` `RateLimiter` (upload/report/login limiters)

* **The Risk:** Limits reset on restart and are not shared across multiple
  workers/processes. An attacker can defeat upload/report/login throttling by
  waiting for a restart or spreading across a horizontally-scaled deployment.
  This is acceptable for the single-process Termux deployment, but must be
  understood as a mitigation, not a hard control.

* **Secure Remediation:** Acceptable for the current single-process model; if
  multi-worker support is added, move counters to a shared store (SQLite table
  or Redis) with the same sliding-window logic.

---

### ⚠️ [Low] - Lenient login brute-force protection / CWE-307 🔶

* **Location:** `backend/main.py` `login()` (`login_limiter.allow(ip, 20, 600)`)

* **The Risk:** 20 attempts per 10 minutes per IP is a weak brake against
  credential guessing and provides no lockout or backoff. Combined with the
  in-memory limiter (above), a patient or distributed attacker can keep
  guessing the single admin password.

* **Secure Remediation:**

```python
# Reduce the budget and add exponential backoff after consecutive failures
if not login_limiter.allow(ip, 5, 600):
    raise HTTPException(status_code=429, detail="Too many login attempts. Please wait.")
# Optional: track consecutive failures per IP and sleep 2**n seconds before verify
```

---

### ⚠️ [Low] - Orphaned files on DB-commit failure / CWE-459 (Incomplete Cleanup) 🔶

* **Location:** `backend/main.py` `upload_image()` — `shutil.move(...)` happens
  before `db.add()`/`db.commit()`

* **The Risk:** Files are moved into `public/` or `quarantine/` before the DB
  row is committed. If `commit()` fails (disk full, constraint error), the file
  exists with no record (or a record exists with no file), leaving either
  unreachable artifacts or broken gallery entries. Not remotely exploitable,
  but a consistency defect.

* **Secure Remediation:** Wrap the move + insert in the same try block, roll
  back moves on exception, and add a startup reconciliation that removes files
  with no matching row (and rows with no file).

---

### ⚠️ [Informational] - Audit trail model defined but never used / CWE-778 (Insufficient Logging) 🔶

* **Location:** `backend/database.py` `class AdminAction` (never written to)

* **The Risk:** Admin actions (approve/reject/emergency-stop) are only logged
  to stdout, not persisted. There is no durable, queryable audit trail of
  moderation decisions, which matters for abuse/CSAM reporting workflows.

* **Secure Remediation:** Insert an `AdminAction(action=..., image_uuid=...)`
  row in `approve_image`, `reject_image`, and `emergency_toggle` (after the
  existing `db.commit()`), and surface recent actions on the admin dashboard.

---

### ⚠️ [Informational] - Session cookie TTL independent of token TTL / CWE-613 🔶

* **Location:** `backend/main.py` `COOKIE_MAX_AGE = 60*60*24*30` vs.
  `backend/security.py` `create_session()` (`admin.session_hours`, default 24h)

* **The Risk:** The cookie lifetime (30 days) is hardcoded while the token
  expiry is configurable. If an operator sets `session_hours` above 720, the
  cookie expires before the token; the mismatch is only cosmetic, but the two
  lifetimes should be derived from one value.

* **Secure Remediation:**

```python
SESSION_TTL = settings.get_int("admin.session_hours", 24) * 3600
COOKIE_MAX_AGE = SESSION_TTL + 300          # token TTL + small clock-skew buffer
```

---

### ⚠️ [Informational] - Tunnel token passed on the cloudflared command line / CWE-522 🔶

* **Location:** `scripts/manage.sh` `start()` —
  `cloudflared tunnel … --token "$TUNNEL_TOKEN" run`

* **The Risk:** The token appears in `/proc/<pid>/cmdline`. This is the
  cloudflared-supported invocation and the exposure is same-user only, so it is
  informational; a stricter alternative is a credentials file with 0600 perms.

* **Secure Remediation:** Write the token to a 0600 file and run
  `cloudflared tunnel --token "$(cat …/token)" run`, or use a named tunnel
  credential file if the deployment model supports it.

---

### ⚠️ [Informational] - CSP permits inline styles / CWE-693 🔶

* **Location:** `backend/main.py` `security_headers()` — `style-src 'self' 'unsafe-inline'`

* **The Risk:** `'unsafe-inline'` for styles weakens CSP slightly; it is
  required because the theme color is injected into an inline `<style>` block.
  This is low risk (no inline *script* is allowed), but can be tightened.

* **Secure Remediation:** Move the theme variables into a small
  `<meta>`/`data-` attribute and reference them from the static stylesheet
  (e.g. `:root { --theme: … }` read via a single generated CSS file), then drop
  `'unsafe-inline'`.

---

## Verified controls (no action required)

- **Authentication:** Argon2id password hashing with constant-time-ish verify;
  failed verification short-circuits. ✅
- **Session integrity:** Stateless HMAC-SHA256 signed tokens with expiry;
  persistent 0600 secret key; `SameSite=Strict` + `HttpOnly`. ✅
- **CSRF:** Double-submit token (httponly cookie + hidden field) enforced on
  every state-changing route. ✅
- **Authorization:** All `/admin/*` routes are behind `get_admin_user`. ✅
- **Path traversal:** Image paths are built from the DB record (`uuid` +
  `extension`), never from raw URL input. ✅
- **XSS:** Every dynamic value is HTML-escaped in `backend/templates.py`. ✅
- **Upload hardening:** File-size cap, pixel/dimension caps, format allow-list,
  `verify()` + full re-encode (strips EXIF/GPS), fail-closed moderation. ✅
- **Header hardening:** `nosniff`, `DENY` framing, `Referrer-Policy`,
  `Permissions-Policy`, HSTS, restrictive CSP. ✅
- **IP trust:** Proxy headers honored only from loopback (prevents header
  spoofing). ✅
- **Secrets:** `.admin_pass_hash`, `.secret_key`, `.env`, `settings.json`,
  `gallery.db`, and uploads are gitignored. ✅

---

## Summary

| # | Severity | Finding | Status |
|---|----------|---------|--------|
| 1 | High | Floating/unpinned dependencies (CWE-1104/1357) | ✅ pinned + CI recommended |
| 2 | Medium | `.env` secrets world-readable (CWE-732) | ✅ `chmod 600` |
| 3 | Medium | OS command injection via `.env` sourcing (CWE-78/94) | ✅ safe parser + quoting |
| 4 | Medium | Cookies missing `Secure` flag (CWE-614) | 🔶 set `cookie_secure: true` |
| 5 | Medium | Backup passphrase on argv (CWE-522/214) | ✅ `--passphrase-fd 0` |
| 6 | Low | Raw IPs stored in reports (CWE-359) | ✅ keyed HMAC |
| 7 | Low | Admin hash via process env (CWE-522) | 🔶 temp-file/stdin |
| 8 | Low | Default decompression-bomb limit (CWE-400/789) | ✅ explicit `MAX_IMAGE_PIXELS` |
| 9 | Low | In-memory rate limiting (CWE-799) | 🔶 acceptable single-process |
| 10 | Low | Lenient login brute-force (CWE-307) | 🔶 tighten budget/backoff |
| 11 | Low | Orphaned files on commit failure (CWE-459) | 🔶 reconciliation |
| 12–16 | Info | Audit trail, cookie TTL, token argv, inline styles, CI | 🔶 hardening |
