#!/bin/bash
set -e
APP_DIR="$(pwd)"; APP_NAME="$(basename "$APP_DIR")"
echo "--- Media Gallery Installer ---"
if [ -z "${TERMUX_VERSION:-}" ]; then echo "Warning: this installer is optimised for Termux, but native Python may still work elsewhere."; fi
pkg_retry(){ local n=1; while [ "$n" -le 3 ]; do echo "Installing packages (attempt $n/3)..."; if pkg install -y --fix-missing "$@"; then return 0; fi; pkg update || true; sleep 5; n=$((n+1)); done; echo "Package installation failed. Try termux-change-repo, then run install.sh again."; return 1; }
if command -v pkg >/dev/null 2>&1; then pkg update || true; pkg upgrade -y || true; pkg_retry python git curl coreutils gnupg || exit 1; fi
NATIVE_OK=true
python3 -m venv .venv 2>/dev/null || NATIVE_OK=false
if [ "$NATIVE_OK" = true ]; then
  . .venv/bin/activate
  pip install --upgrade pip || NATIVE_OK=false
  if [ "$NATIVE_OK" = true ]; then
    # Prefer the Termux-built watcher if present; never require compiling watchfiles.
    if command -v pkg >/dev/null 2>&1; then
      pkg install -y python-watchfiles 2>/dev/null || true
    fi
    if ! pip install -r requirements.txt; then
      echo "pip install failed. Retrying without compiling native extras (watchfiles/uvloop)..."
      pip install --only-binary=:all: -r requirements.txt || NATIVE_OK=false
    fi
  fi
fi
if [ "$NATIVE_OK" = false ]; then
  echo "Native Python packages are incomplete; a Debian/proot fallback will be offered after the admin password."
fi
read -r -s -p "Admin password (10+ characters): " ADMIN_PASS; echo
read -r -s -p "Confirm admin password: " ADMIN_CONFIRM; echo
if [ "${#ADMIN_PASS}" -lt 10 ] || [ "$ADMIN_PASS" != "$ADMIN_CONFIRM" ]; then echo "Admin passwords must match and be at least 10 characters."; exit 1; fi
export ADMIN_PASS
if [ "$NATIVE_OK" = true ]; then
 . .venv/bin/activate
 printf '%s' "$ADMIN_PASS" | python -c 'import sys; from argon2 import PasswordHasher; print(PasswordHasher().hash(sys.stdin.read()))' > .admin_pass_hash
 chmod 600 .admin_pass_hash
else
 echo "Native dependencies failed. Trying Debian/proot fallback..."
 pkg_retry proot-distro || exit 1
 proot-distro install debian 2>/dev/null || true
 # proot-distro does NOT put the Termux app directory at $HOME inside Debian
 # (Debian's root user has its own $HOME=/root). Bind-mount it explicitly to
 # a fixed, known path so the container side never has to guess.
 PROOT_APP_DIR="/root/$APP_NAME"
 proot-distro login debian --bind "$APP_DIR:$PROOT_APP_DIR" -- env ADMIN_PASS="$ADMIN_PASS" REPO_DIR="$PROOT_APP_DIR" bash <<'EOF'
set -e
apt update
apt install -y -o Acquire::Retries=3 python3 python3-pip python3-venv libjpeg-dev zlib1g-dev
[ -d "$REPO_DIR" ] || { echo "Gallery directory not visible inside Debian (bind mount failed)." >&2; exit 1; }
python3 -m venv /opt/venv
source /opt/venv/bin/activate
pip install -r "$REPO_DIR/requirements.txt"
printf '%s' "$ADMIN_PASS" | python -c 'import sys; from argon2 import PasswordHasher; print(PasswordHasher().hash(sys.stdin.read()))' > "$REPO_DIR/.admin_pass_hash"
chmod 600 "$REPO_DIR/.admin_pass_hash"
EOF
 python3 - <<'PY'
import json,tempfile,os
p='settings.json';d=json.load(open(p));d.setdefault('runtime',{})['use_proot']=True
fd,t=tempfile.mkstemp(dir='.',prefix='settings.',suffix='.tmp')
with os.fdopen(fd,'w') as f:json.dump(d,f,indent=2);f.write('\n')
os.chmod(t,0o600);os.replace(t,p)
PY
fi
chmod 600 .admin_pass_hash
[ -f settings.json ] || cp settings.example.json settings.json
mkdir -p uploads/public uploads/quarantine uploads/staging models logs
chmod 700 uploads uploads/public uploads/quarantine uploads/staging
# Cloudflared is optional; download only when the CPU is supported.
VERSION="2026.8.1"; ARCH="$(uname -m)"; ASSET=""; SHA=""
case "$ARCH" in aarch64|arm64) ASSET=cloudflared-linux-arm64; SHA=6d517efc10dfce17440177bd7011909166eab44bae0f6998182183df717c7dba;; armv7l|armv8l|arm) ASSET=cloudflared-linux-arm; SHA=61a4818c1537197a5f1c0a4662808e2e7e166b8eba701a91b62b33d7adba9b32;; x86_64|amd64) ASSET=cloudflared-linux-amd64; SHA=98d8eadbfdf8c7ec994e08260599c9be991e7833c746f98692b18bdf71c9b9dc;; i686|i386) ASSET=cloudflared-linux-386; SHA=cfc47459b9cdd190f16e1ba35a9476c5616bf68130ba12c49b7d1fcc95f50c03;; *) echo "Cloudflare Tunnel binary is unavailable for $ARCH; the gallery can still run locally.";; esac
if [ -n "$ASSET" ] && [ ! -f bin/cloudflared ]; then mkdir -p bin; curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "https://github.com/cloudflare/cloudflared/releases/download/$VERSION/$ASSET" -o bin/cloudflared; printf '%s  %s\n' "$SHA" bin/cloudflared | sha256sum -c -; chmod 755 bin/cloudflared; fi
if [ ! -f models/nsfw_model.tflite ]; then echo "Moderation model not installed: moderation will fail closed until you add models/nsfw_model.tflite or disable moderation in the console."; fi
bash scripts/test_security.sh || true
echo
echo "Installation complete."
echo "Start the numbered control panel with: bash scripts/menu.sh"
echo "Configure everything from the console; normal operation does not require editing files."
