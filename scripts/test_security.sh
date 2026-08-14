#!/data/data/com.termux/files/usr/bin/bash
set -u

echo "--- Post-Install Security Test ---"
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APP_DIR" || exit 1
FAIL=0
PORT="$(python3 - <<'PY' 2>/dev/null || echo 8000
import json
try: print(int(json.load(open('settings.json',encoding='utf-8')).get('server',{}).get('port',8000)))
except Exception: print(8000)
PY
)"
HOST="$(python3 - <<'PY' 2>/dev/null || echo 0.0.0.0
import json
try: print(str(json.load(open('settings.json',encoding='utf-8')).get('server',{}).get('host','0.0.0.0')))
except Exception: print('0.0.0.0')
PY
)"

if command -v ss >/dev/null 2>&1; then LISTENING="$(ss -tln 2>/dev/null)"; elif command -v netstat >/dev/null 2>&1; then LISTENING="$(netstat -tuln 2>/dev/null)"; else LISTENING=""; fi
if [ -z "$LISTENING" ]; then
    echo "[SKIP] Could not inspect listening sockets."
elif echo "$LISTENING" | grep -Eq "(^|[[:space:]])0\.0\.0\.0:${PORT}([[:space:]]|$)|(^|[[:space:]])\[::\]:${PORT}([[:space:]]|$)"; then
    if [ "$HOST" = "0.0.0.0" ]; then echo "[PASS] Wildcard network binding is intentional for LAN access (0.0.0.0:$PORT)."; else echo "[FAIL] The gallery is listening on a wildcard network interface while configured host is $HOST."; FAIL=1; fi
else
    echo "[PASS] The gallery is not exposed on a wildcard network interface."
fi

check_private_file(){
    local file="$1"
    [ -f "$file" ] || { echo "[WARN] $file not found."; return 0; }
    local perms mode
    perms="$(stat -c "%a" "$file" 2>/dev/null || true)"
    [ -n "$perms" ] || { echo "[WARN] Could not inspect $file."; return 0; }
    mode=$((8#$perms))
    if (( (mode & 077) == 0 )); then echo "[PASS] $file is private ($perms)."; else echo "[FAIL] $file has unsafe permissions: $perms."; FAIL=1; fi
}

if [ ! -s ".secret_key" ] && [ -z "${GALLERY_SECRET_KEY:-}" ]; then
    umask 077
    python3 - <<'PY' >/dev/null 2>&1 || true
import os,secrets
p='.secret_key'
if not os.path.exists(p):
    with open(p,'w',encoding='utf-8') as f: f.write(secrets.token_urlsafe(48)+'\n')
    os.chmod(p,0o600)
PY
fi
check_private_file ".admin_pass_hash"
if [ -n "${GALLERY_SECRET_KEY:-}" ] || [ -s ".secret_key" ]; then echo "[PASS] Gallery secret is configured and private."; else echo "[FAIL] Gallery secret could not be created or configured."; FAIL=1; fi
check_private_file ".secret_key"
check_private_file ".env"

STORAGE_DIR="$(python3 - <<'PY' 2>/dev/null || echo uploads
import json
try: print(json.load(open('settings.json',encoding='utf-8')).get('server',{}).get('storage_directory','uploads'))
except Exception: print('uploads')
PY
)"
for dir in "$STORAGE_DIR" "$STORAGE_DIR/staging" "$STORAGE_DIR/public" "$STORAGE_DIR/quarantine"; do
    if [ -d "$dir" ]; then
        perms="$(stat -c "%a" "$dir" 2>/dev/null || true)"; mode=$((8#${perms:-777}))
        if (( (mode & 007) == 0 )); then echo "[PASS] $dir is private ($perms)."; else echo "[FAIL] $dir is world-accessible ($perms)."; FAIL=1; fi
    fi
done

if command -v cloudflared >/dev/null 2>&1; then
    if cloudflared --version >/dev/null 2>&1; then echo "[PASS] Native Termux Cloudflare Tunnel is installed and executable."; else echo "[FAIL] Native Termux cloudflared is installed but cannot execute."; FAIL=1; fi
else
    echo "[WARN] Native Termux cloudflared is not installed (Cloudflare Tunnel will be unavailable)."
fi
[ -x "scripts/settings_cli.py" ] && echo "[PASS] Configuration panel is installed."

if [ "$FAIL" -ne 0 ]; then echo "Security test failed. Fix the [FAIL] items before exposing the gallery."; exit 1; fi
echo "Security test complete: no failed checks."
