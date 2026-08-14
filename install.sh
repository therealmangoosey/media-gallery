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

# cloudflared MUST come from the Termux package build. The official Linux
# release binary is not the correct Android/Termux build and can fail to
# register a connector even though the file is executable.
pkg update
pkg upgrade -y
pkg_retry python python-pip python-pillow git curl coreutils openssl gnupg clang pkg-config cloudflared

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
python - <<'PY'
import PIL
print("Termux Pillow available:", PIL.__version__)
PY

python -m pip install --only-binary=pydantic-core --extra-index-url "$TUR_INDEX" pydantic==2.12.5 pydantic-core==2.41.5
python -m pip install --extra-index-url "$TUR_INDEX" -r requirements.txt
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

# Verify that the native Android connector is actually runnable.
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "ERROR: Termux cloudflared package was not installed."
  exit 1
fi
if ! cloudflared --version >/dev/null 2>&1; then
  echo "ERROR: Termux cloudflared is installed but cannot execute."
  exit 1
fi

if [ ! -f models/nsfw_model.tflite ]; then
  echo "Note: moderation model not installed; moderation will fail closed until a compatible model is added or moderation is disabled."
fi

bash scripts/test_security.sh || true

echo
echo "Installation complete — Termux-only."
echo "Start the control panel with: bash scripts/menu.sh"
echo "No Debian/proot/container setup is required or supported."
