#!/bin/bash

set -e

echo "--- Media Gallery Installer ---"

APP_DIR="$(pwd)"
APP_NAME="$(basename "$APP_DIR")"

# 1. Check dependencies (Termux)
if [ -z "$TERMUX_VERSION" ]; then
    echo "Warning: This script is designed for Termux."
fi

# Install packages with retries. A common Termux failure is a mirror that is
# still syncing serving a truncated archive (e.g. "File has unexpected size"
# or a checksum mismatch). That is not an error on your end; waiting a moment
# and retrying usually fixes it. If it keeps failing we point the user at
# switching mirrors instead of silently dying.
pkg_install_retry() {
    local attempt=1
    local max_attempts=3
    while [ "$attempt" -le "$max_attempts" ]; do
        echo "--- Installing packages (attempt $attempt/$max_attempts) ---"
        if pkg install -y --fix-missing "$@"; then
            return 0
        fi
        echo ""
        echo "⚠️  Package install failed. This is usually a mirror still syncing"
        echo "    (size/checksum mismatch) — not a problem on your end."
        if [ "$attempt" -lt "$max_attempts" ]; then
            echo "    Refreshing package lists and retrying in 10 seconds..."
            sleep 10
            pkg update || true
        fi
        attempt=$((attempt + 1))
    done
    echo ""
    echo "❌ Could not install packages after $max_attempts attempts."
    echo "   The mirror may still be out of sync. Try switching mirrors:"
    echo ""
    echo "     termux-change-repo"
    echo ""
    echo "   Pick a different mirror, then re-run:  bash install.sh"
    echo ""
    return 1
}

pkg update || true
pkg upgrade -y || true
pkg_install_retry proot-distro git python binutils || exit 1

# 2. Setup Debian environment (proot-distro)
if ! proot-distro list | grep -q "debian"; then
    echo "Installing Debian via proot-distro..."
    proot-distro install debian
fi

# 3. Interactive Configuration
read -p "Enter your Cloudflare domain (e.g., gallery.example.com): " DOMAIN
read -p "Enter your Cloudflare Tunnel Token: " TUNNEL_TOKEN
read -s -p "Enter Admin Password: " ADMIN_PASS
echo ""
read -p "Enter Auto-Approve NSFW Threshold (0.0-1.0, default 0.2): " THRESHOLD_APPROVE
THRESHOLD_APPROVE=${THRESHOLD_APPROVE:-0.2}

# 4. Save Configuration
#    Validate inputs and write them single-quoted so they can never be
#    interpreted as shell when the file is later read. The tunnel token is a
#    secret, so keep .env private (0600).
for _v in "$DOMAIN" "$TUNNEL_TOKEN"; do
    case "$_v" in
        *"'"*|*$'\n'*|*$'\r'*) echo "Error: value contains unsupported characters."; exit 1 ;;
    esac
done
case "$THRESHOLD_APPROVE" in
    ''|*[!0-9.]*) echo "Error: threshold must be a number (e.g. 0.2)."; exit 1 ;;
esac

cat <<EOF > .env
DOMAIN='$DOMAIN'
TUNNEL_TOKEN='$TUNNEL_TOKEN'
AUTO_APPROVE_THRESHOLD='$THRESHOLD_APPROVE'
EOF
chmod 600 .env

# 5. Install Python dependencies in Debian and hash the admin password there.
#    (argon2-cffi is only installed inside the Debian environment, so the hash
#    must be generated after pip install, not on the Termux host.)
echo "Setting up Python environment inside Debian..."
proot-distro login debian -- env ADMIN_PASS="$ADMIN_PASS" APP_NAME="$APP_NAME" bash <<'EOF'
# apt in the proot can hit the same mirror-sync issues as Termux; retry a few
# times before giving up.
for attempt in 1 2 3; do
    apt update && apt install -y -o Acquire::Retries=3 python3 python3-pip python3-venv libjpeg-dev zlib1g-dev && break
    echo "apt failed (attempt $attempt); retrying after a short delay..."
    sleep 10
done

python3 -m venv /opt/venv
source /opt/venv/bin/activate
REPO_DIR="$HOME/$APP_NAME"
[ -d "$REPO_DIR" ] || REPO_DIR="/root/$APP_NAME"
pip install -r "$REPO_DIR/requirements.txt"
# tflite-runtime might need a specific wheel for arm64
pip install tflite-runtime || echo "tflite-runtime install failed, will use fallback"

# Generate the Argon2id hash of the admin password (now that argon2 is available)
python -c 'import os; from argon2 import PasswordHasher; print(PasswordHasher().hash(os.environ["ADMIN_PASS"]))' > "$REPO_DIR/.admin_pass_hash"
chmod 600 "$REPO_DIR/.admin_pass_hash"

# Create a settings.json from the example if one doesn't exist yet.
[ -f "$REPO_DIR/settings.json" ] || cp "$REPO_DIR/settings.example.json" "$REPO_DIR/settings.json"
EOF

# 6. Download cloudflared (arm64)
if [ ! -f "bin/cloudflared" ]; then
    mkdir -p bin
    echo "Downloading cloudflared..."
    # URL for arm64
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o bin/cloudflared
    chmod +x bin/cloudflared
fi

# 7. Setup TFLite Model placeholder
mkdir -p models
if [ ! -f "models/nsfw_model.tflite" ]; then
    echo "Notice: You need to place a 'nsfw_model.tflite' in the models/ directory."
    echo "Until then the gallery fails closed (quarantines every upload)."
fi

echo "--- Installation Complete ---"
bash scripts/test_security.sh
echo "Use 'bash scripts/manage.sh start' to start the application."
echo "Use './bin/cloudflared tunnel --original-client-ip --token \$TUNNEL_TOKEN run' to start the tunnel."
