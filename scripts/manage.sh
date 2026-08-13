#!/bin/bash

# Media Gallery management script.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="$(basename "$APP_DIR")"
PID_FILE="$APP_DIR/app.pid"
TUNNEL_PID_FILE="$APP_DIR/tunnel.pid"
LOG_FILE="$APP_DIR/logs/app.log"
PORT=8000

log() { echo "[manage] $*"; }

# Load a KEY=VALUE file *without* sourcing it. Sourcing executes the file as
# shell, so a hostile or malformed value (e.g. a tunnel token containing shell
# metacharacters) could otherwise run arbitrary commands. Values may be
# optionally single- or double-quoted; everything else is taken literally.
load_env_safe() {
    local file="$1" line key value
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        key="${line%%=*}"
        [ -z "$key" ] && continue
        value="${line#*=}"
        case "$value" in
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
        esac
        export "$key=$value"
    done < "$file"
}

# Find a tool to list listening ports (ss is preferred; netstat as fallback).
port_tool() {
    if command -v ss >/dev/null 2>&1; then
        echo "ss"
    elif command -v netstat >/dev/null 2>&1; then
        echo "netstat"
    else
        echo ""
    fi
}

is_port_open() {
    local tool
    tool="$(port_tool)"
    case "$tool" in
        ss) ss -tln 2>/dev/null | grep -q ":${PORT} " ;;
        netstat) netstat -tuln 2>/dev/null | grep -q ":${PORT} " ;;
        *) false ;;
    esac
}

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
            nohup python3 -m uvicorn backend.main:app --host 127.0.0.1 --port $PORT >> logs/app.log 2>&1 &
            echo \$! > app.pid
        "
    else
        # Fallback for non-Termux machines (e.g. dev box): run directly.
        cd "$APP_DIR" || exit 1
        if [ -d "$APP_DIR/.venv" ]; then
            # shellcheck disable=SC1091
            . "$APP_DIR/.venv/bin/activate"
        fi
        nohup python3 -m uvicorn backend.main:app --host 127.0.0.1 --port $PORT >> "$LOG_FILE" 2>&1 &
        echo $! > "$PID_FILE"
    fi

    # Wait briefly for the port to come up so the user gets real feedback.
    local i
    for i in $(seq 1 15); do
        if is_port_open; then
            break
        fi
        sleep 1
    done

    if is_port_open; then
        echo "App is up on http://127.0.0.1:$PORT"
    else
        echo "App process started but port $PORT isn't responding yet — check logs/app.log."
    fi

    # Also start cloudflared if token is available
    if [ -f "$APP_DIR/.env" ]; then
        load_env_safe "$APP_DIR/.env"
        if [ -n "${TUNNEL_TOKEN:-}" ] && [ -x "$APP_DIR/bin/cloudflared" ]; then
            echo "Starting Cloudflare Tunnel..."
            nohup "$APP_DIR/bin/cloudflared" tunnel --original-client-ip --token "$TUNNEL_TOKEN" run > "$APP_DIR/logs/tunnel.log" 2>&1 &
            echo $! > "$TUNNEL_PID_FILE"
        fi
    fi
    echo "App and Tunnel started."
}

stop() {
    local stopped=0

    if [ -f "$PID_FILE" ]; then
        PID="$(cat "$PID_FILE")"
        if kill "$PID" 2>/dev/null; then
            echo "Stopped Gallery App (PID: $PID)"
            stopped=1
        else
            echo "Gallery App process not found (stale PID file)."
        fi
        rm -f "$PID_FILE"
    else
        # No PID file: try to find the app process by its command line.
        if pkill -f "uvicorn backend.main:app" 2>/dev/null; then
            echo "Stopped Gallery App (found via pkill)."
            stopped=1
        fi
    fi

    if [ "$stopped" -eq 0 ]; then
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
    if ! command -v gpg >/dev/null 2>&1; then
        echo "Error: 'gpg' is not installed. Install it first (pkg install gnupg / apt install gnupg)."
        return 1
    fi
    echo "Creating backup..."
    cd "$APP_DIR" || exit 1
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="$APP_DIR/backup_$TIMESTAMP.tar.gz"
    # Create archive of db, settings, and public images
    tar -czf "$BACKUP_FILE" gallery.db settings.json uploads/public 2>/dev/null || true
    read -s -p "Enter Backup Encryption Password: " BACKUP_PASS
    echo ""
    # Pass the passphrase via a file descriptor, not argv, so it never shows up
    # in `ps` / the process list.
    gpg --symmetric --batch --passphrase-fd 0 "$BACKUP_FILE" <<< "$BACKUP_PASS"
    rm -f "$BACKUP_FILE"
    echo "Backup created: $BACKUP_FILE.gpg"
}

restore() {
    FILE=$1
    if [ -z "$FILE" ]; then
        echo "Usage: $0 restore <file.gpg>"
        return 1
    fi
    if [ ! -f "$FILE" ]; then
        echo "Error: backup file not found: $FILE"
        return 1
    fi
    read -s -p "Enter Backup Decryption Password: " BACKUP_PASS
    echo ""
    TMP_FILE="$APP_DIR/restored.tar.gz"
    gpg --decrypt --batch --passphrase-fd 0 "$FILE" > "$TMP_FILE" <<< "$BACKUP_PASS"
    tar -xzf "$TMP_FILE" -C "$APP_DIR"
    rm -f "$TMP_FILE"
    echo "Restore complete."
}

status() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "App is running (PID: $(cat "$PID_FILE"))"
    elif is_port_open; then
        echo "App is running (responding on port $PORT; PID file missing)."
    else
        echo "App is not running."
    fi
}

logs() {
    if [ -f "$LOG_FILE" ]; then
        tail -n 100 "$LOG_FILE"
    else
        echo "No log file found yet ($LOG_FILE)."
    fi
}

# Only dispatch when executed directly (not when sourced by scripts/menu.sh).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "$1" in
        start) start ;;
        stop) stop ;;
        restart) stop; start ;;
        status) status ;;
        logs) logs ;;
        backup) backup ;;
        restore) restore "$2" ;;
        *) echo "Usage: $0 {start|stop|restart|status|logs|backup|restore}" ;;
    esac
fi
