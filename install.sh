#!/bin/bash

set -e

echo "--- Media Gallery Installer ---"

# 1. Check dependencies (Termux)
if [ -z "$TERMUX_VERSION" ]; then
    echo "Warning: This script is designed for Termux."
fi

pkg update && pkg upgrade -y
pkg install -y proot-distro git python binutils

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
cat <<EOF > .env
DOMAIN=$DOMAIN
TUNNEL_TOKEN=$TUNNEL_TOKEN
AUTO_APPROVE_THRESHOLD=$THRESHOLD_APPROVE
EOF

# Use Python to hash the password safely
ADMIN_HASH=$(python3 -c "from argon2 import PasswordHasher; print(PasswordHasher().hash('$ADMIN_PASS'))")
echo "$ADMIN_HASH" > .admin_pass_hash
chmod 600 .admin_pass_hash

# 5. Install Python dependencies in Debian
echo "Setting up Python environment inside Debian..."
proot-distro login debian -- bash <<EOF
apt update
apt install -y python3 python3-pip python3-venv libjpeg-dev zlib1g-dev
python3 -m venv /opt/venv
source /opt/venv/bin/activate
pip install fastapi uvicorn sqlalchemy pillow argon2-cffi numpy python-multipart
# tflite-runtime might need a specific wheel for arm64
pip install tflite-runtime || echo "tflite-runtime install failed, will use fallback"
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
if [ ! -f "models/nsfw_model.tflite" ]; then
    echo "Notice: You need to place a 'nsfw_model.tflite' in the models/ directory."
    echo "For now, creating a placeholder."
    touch models/nsfw_model.tflite
fi

echo "--- Installation Complete ---"
bash scripts/test_security.sh
echo "Use 'bash scripts/manage.sh start' to start the application."
echo "Use './bin/cloudflared tunnel --original-client-ip --token \$TUNNEL_TOKEN run' to start the tunnel."
