#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$APP_DIR"

echo "--- Media Gallery — Termux-only installer ---"
echo "Native Android/Termux runtime only. No Debian, proot, Docker, or Linux container is supported."
echo

if [ -z "${TERMUX_VERSION:-}" ] || [ "${PREFIX:-}" != "/data/data/com.termux/files/usr" ]; then
  echo "ERROR: Media Gallery is Termux-only."
  echo "Install the current Termux app, open it, and run this installer from inside Termux."
  exit 1
fi

pkg_retry() {
  local n=1
  while [ "$n" -le 3 ]; do
    echo "Installing packages (attempt $n/3)..."
    if pkg install -y --fix-missing "$@"; then return 0; fi
    pkg update || true
    sleep 3
    n=$((n+1))
  done
  echo "Package installation failed. Try termux-change-repo, then run install.sh again."
  return 1
}

pkg update
pkg upgrade -y
pkg_retry python python-pip python-pillow git curl coreutils openssl gnupg clang pkg-config

# TUR provides Android/Termux wheels for packages such as pydantic-core that
# otherwise try to compile desktop Linux/Rust artifacts on the device.
TUR_INDEX="https://termux-user-repository.github.io/pypi/"

venv_needs_rebuild=0
if [ ! -x .venv/bin/python ]; then
  venv_needs_rebuild=1
elif ! grep -q '^include-system-site-packages = true$' .venv/pyvenv.cfg 2>/dev/null; then
  venv_needs_rebuild=1
fi
if [ "$venv_needs_rebuild" -eq 1 ]; then
  if [ -d .venv ]; then
    echo "Recreating the runtime environment as a Termux system-site-packages venv."
    rm -rf .venv
  fi
  python3 -m venv --system-site-packages .venv
fi
. .venv/bin/activate

python -m pip install --upgrade pip

# Install the native Termux Pillow package into the system interpreter; the
# venv above intentionally exposes Termux site-packages to avoid a fragile
# Pillow source build on Android.
python - <<'PY'
import PIL
print("Termux Pillow available:", PIL.__version__)
PY

# Install pydantic/core from TUR first. --only-binary prevents pip from
# silently falling back to the Rust source distribution.
python -m pip install --only-binary=pydantic-core --extra-index-url "$TUR_INDEX" pydantic==2.12.5 pydantic-core==2.41.5

# Remaining packages are mostly pure Python; keep TUR available for any
# Android-native dependency wheels it supplies.
python -m pip install --extra-index-url "$TUR_INDEX" -r requirements.txt

# Verify the complete application import before asking for credentials.
PYTHONPATH="$APP_DIR" python -c 'import fastapi,uvicorn,sqlalchemy,PIL,pydantic; import backend.main; print("PRE-FLIGHT OK")'

read -r -s -p "Admin password (10+ characters): " ADMIN_PASS; echo
read -r -s -p "Confirm admin password: " ADMIN_CONFIRM; echo
if [ "${#ADMIN_PASS}" -lt 10 ] || [ "$ADMIN_PASS" != "$ADMIN_CONFIRM" ]; then
  echo "Admin passwords must match and be at least 10 characters."
  exit 1
fi

printf '%s' "$ADMIN_PASS" | python -c 'import sys; from argon2 import PasswordHasher; print(PasswordHasher().hash(sys.stdin.read()))' > .admin_pass_hash
chmod 600 .admin_pass_hash

[ -f settings.json ] || cp settings.example.json settings.json

python - <<'PY'
import json, os, tempfile, secrets
p='settings.json'
try:
    with open(p, encoding='utf-8') as f: d=json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    with open('settings.example.json', encoding='utf-8') as f: d=json.load(f)
d.setdefault('server', {})['host'] = '0.0.0.0'
d.setdefault('runtime', {}).pop('use_proot', None)
d.setdefault('runtime', {})['auto_recover'] = True
fd, tmp = tempfile.mkstemp(dir='.', prefix='settings.', suffix='.tmp')
with os.fdopen(fd, 'w', encoding='utf-8') as f:
    json.dump(d, f, indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())
os.chmod(tmp, 0o600); os.replace(tmp, p)
secret_path='.secret_key'
if not os.path.exists(secret_path):
    with open(secret_path,'w',encoding='utf-8') as f: f.write(secrets.token_urlsafe(48)+'\n')
os.chmod(secret_path,0o600)
PY

mkdir -p uploads/public uploads/quarantine uploads/staging models logs
chmod 700 uploads uploads/public uploads/quarantine uploads/staging

VERSION="2026.8.1"
ARCH="$(uname -m)"
ASSET=""; SHA=""
case "$ARCH" in
  aarch64|arm64) ASSET=cloudflared-linux-arm64; SHA=6d517efc10dfce17440177bd7011909166eab44bae0f6998182183df717c7dba;;
  armv7l|armv8l|arm) ASSET=cloudflared-linux-arm; SHA=61a4818c1537197a5f1c0a4662808e2e7e166b8eba701a91b62b33d7adba9b32;;
  x86_64|amd64) ASSET=cloudflared-linux-amd64; SHA=98d8eadbfdf8c7ec994e08260599c9be991e7833c746f98692b18bdf71c9b9dc;;
  i686|i386) ASSET=cloudflared-linux-386; SHA=cfc47459b9cdd190f16e1ba35a9476c5616bf68130ba12c49b7d1fcc95f50c03;;
  *) echo "Cloudflare Tunnel binary is unavailable for $ARCH; local gallery hosting still works.";;
esac
if [ -n "$ASSET" ] && [ ! -f bin/cloudflared ]; then
  mkdir -p bin
  curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "https://github.com/cloudflare/cloudflared/releases/download/$VERSION/$ASSET" -o bin/cloudflared
  printf '%s  %s\n' "$SHA" bin/cloudflared | sha256sum -c -
  chmod 755 bin/cloudflared
fi

if [ ! -f models/nsfw_model.tflite ]; then
  echo "Note: moderation model not installed; moderation will fail closed until a compatible model is added or moderation is disabled."
fi

bash scripts/test_security.sh || true

echo
echo "Installation complete — Termux-only."
echo "Start the control panel with: bash scripts/menu.sh"
echo "No Debian/proot/container setup is required or supported."
