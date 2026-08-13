#!/bin/bash

echo "--- Post-Install Security Test ---"

# Check if app is listening on 0.0.0.0
if netstat -tuln | grep -q "0.0.0.0:8000"; then
    echo "[FAIL] App is listening on 0.0.0.0:8000! It should only listen on 127.0.0.1."
else
    echo "[PASS] App is not exposed to 0.0.0.0."
fi

# Check for .env permissions
PERMS=$(stat -c "%a" .admin_pass_hash)
if [ "$PERMS" -eq "600" ]; then
    echo "[PASS] Admin secret file has safe permissions (600)."
else
    echo "[FAIL] Admin secret file has unsafe permissions: $PERMS"
fi

echo "Test complete."
