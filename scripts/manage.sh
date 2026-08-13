#!/bin/bash

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="$(basename "$APP_DIR")"
PID_FILE="$APP_DIR/app.pid"
TUNNEL_PID_FILE="$APP_DIR/tunnel.pid"
LOG_FILE="$APP_DIR/logs/app.log"

start() {
    mkdir -p "$APP_DIR/logs" "$APP_DIR/uploads/staging" "$APP_DIR/uploads/public" "$APP_DIR/uploads/quarantine"

    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "App is already running (PID: $(cat "$PID_FILE"))"
        return
    fi
    rm -f "$PID_FILE"

    if [ ! -f "$APP_DIR/.admin_pass_hash" ]; then
        echo "Error: $APP_DIR/.admin_pass_hash not found. Run install.sh first."
        return 1
    fi

    echo "Starting Gallery App..."
    ADMIN_PASSWORD_HASH="$(cat "$APP_DIR/.admin_pass_hash")"
    export ADMIN_PASSWORD_HASH

    if command -v proot-distro >/dev/null 2>&1; then
        # Start inside the Debian proot environment (Termux). proot-distro bind
        # mounts the Termux home directory to the proot user's home, so the
        # repo is reachable at $HOME/<app-name> inside Debian.
        proot-distro login debian -- bash -c "
            if [ -d \"\$HOME/$APP_NAME\" ]; then
                cd \"\$HOME/$APP_NAME\" || exit 1
            else
                cd \"$APP_DIR\" || exit 1
            fi
            source /opt/venv/bin/activate
            export ADMIN_PASSWORD_HASH=\"$ADMIN_PASSWORD_HASH\"
            mkdir -p logs uploads/staging uploads/public uploads/quarantine
            nohup python3 -m uvicorn backend.main:app --host 127.0.0.1 --port 8000 >> logs/app.log 2>&1 &
            echo \$! > app.pid
        "
    else
        # Fallback for non-Termux machines (e.g. dev box): run directly.
        cd "$APP_DIR" || exit 1
        if [ -d "$APP_DIR/.venv" ]; then
            # shellcheck disable=SC1091
            . "$APP_DIR/.venv/bin/activate"
        fi
        nohup python3 -m uvicorn backend.main:app --host 127.0.0.1 --port 8000 >> "$LOG_FILE" 2>&1 &
        echo $! > "$PID_FILE"
    fi

    # Also start cloudflared if token is available
    if [ -f "$APP_DIR/.env" ]; then
        # shellcheck disable=SC1090
        . "$APP_DIR/.env"
        if [ -n "$TUNNEL_TOKEN" ] && [ -x "$APP_DIR/bin/cloudflared" ]; then
            echo "Starting Cloudflare Tunnel..."
            nohup "$APP_DIR/bin/cloudflared" tunnel --original-client-ip --token "$TUNNEL_TOKEN" run > "$APP_DIR/logs/tunnel.log" 2>&1 &
            echo $! > "$TUNNEL_PID_FILE"
        fi
    fi
    echo "App and Tunnel started."
}

stop() {
    if [ -f "$PID_FILE" ]; then
        PID="$(cat "$PID_FILE")"
        if kill "$PID" 2>/dev/null; then
            echo "Stopped Gallery App (PID: $PID)"
        else
            echo "Gallery App process not found (stale PID file)."
        fi
        rm -f "$PID_FILE"
    else
        echo "App is not running."
    fi

    if [ -f "$TUNNEL_PID_FILE" ]; then
        TPID="$(cat "$TUNNEL_PID_FILE")"
        if kill "$TPID" 2>/dev/null; then
            echo "Stopped Cloudflare Tunnel (PID: $TPID)"
        fi
        rm -f "$TUNNEL_PID_FILE"
    fi
}

backup() {
    echo "Creating backup..."
    cd "$APP_DIR" || exit 1
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="$APP_DIR/backup_$TIMESTAMP.tar.gz"
    # Create archive of db and public images
    tar -czf "$BACKUP_FILE" gallery.db uploads/public
    # Encrypt
    read -s -p "Enter Backup Encryption Password: " BACKUP_PASS
    echo ""
    gpg --symmetric --batch --passphrase "$BACKUP_PASS" "$BACKUP_FILE"
    rm "$BACKUP_FILE"
    echo "Backup created: $BACKUP_FILE.gpg"
}

restore() {
    FILE=$1
    if [ -z "$FILE" ]; then
        echo "Usage: $0 restore <file.gpg>"
        return 1
    fi
    read -s -p "Enter Backup Decryption Password: " BACKUP_PASS
    echo ""
    TMP_FILE="$APP_DIR/restored.tar.gz"
    gpg --decrypt --batch --passphrase "$BACKUP_PASS" "$FILE" > "$TMP_FILE"
    tar -xzf "$TMP_FILE" -C "$APP_DIR"
    rm "$TMP_FILE"
    echo "Restore complete."
}

status() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "App is running (PID: $(cat "$PID_FILE"))"
    else
        echo "App is not running."
    fi
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status) status ;;
    backup) backup ;;
    restore) restore "$2" ;;
    *) echo "Usage: $0 {start|stop|restart|status|backup|restore}" ;;
esac
