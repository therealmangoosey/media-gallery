#!/bin/bash

# Post-install / pre-flight security checks.

echo "--- Post-Install Security Test ---"

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APP_DIR" || exit 1

# 1. Make sure the app is not listening on 0.0.0.0 (must be localhost only).
if command -v ss >/dev/null 2>&1; then
    LISTENING="$(ss -tln 2>/dev/null)"
elif command -v netstat >/dev/null 2>&1; then
    LISTENING="$(netstat -tuln 2>/dev/null)"
else
    LISTENING=""
fi

if [ -z "$LISTENING" ]; then
    echo "[SKIP] Could not check ports (ss/netstat not installed)."
elif echo "$LISTENING" | grep -q "0.0.0.0:8000"; then
    echo "[FAIL] App is listening on 0.0.0.0:8000! It should only listen on 127.0.0.1."
else
    echo "[PASS] App is not exposed to 0.0.0.0."
fi

# 2. Secret file permissions.
check_perms() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "[WARN] $file not found."
        return
    fi
    local perms
    perms="$(stat -c "%a" "$file" 2>/dev/null)"
    case "$perms" in
        600) echo "[PASS] $file has safe permissions (600)." ;;
        *) echo "[FAIL] $file has unsafe permissions: $perms (should be 600)." ;;
    esac
}

check_perms ".admin_pass_hash"
check_perms ".secret_key"

# 3. Upload directories should not be world-readable.
if [ -d "uploads" ]; then
    UPLOAD_PERMS="$(stat -c "%a" uploads 2>/dev/null)"
    if [ "${UPLOAD_PERMS:0:1}" -gt 7 ]; then
        echo "[WARN] uploads/ is group/world accessible (perm: $UPLOAD_PERMS)."
    else
        echo "[PASS] uploads/ is private."
    fi
fi

echo "Test complete."
