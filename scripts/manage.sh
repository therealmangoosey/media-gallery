#!/bin/bash

# Media Gallery management script.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="$(basename "$APP_DIR")"
PID_FILE="$APP_DIR/app.pid"
TUNNEL_PID_FILE="$APP_DIR/tunnel.pid"
LOG_FILE="$APP_DIR/logs/app.log"
ENV_FILE="$APP_DIR/.env"
PORT=8000

read_setting() {
    local key="$1" default="$2"
    python3 - "$APP_DIR/settings.json" "$key" "$default" <<'PYSET' 2>/dev/null
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding="utf-8"))
    for p in sys.argv[2].split("."): d=d[p]
    print(d)
except Exception: print(sys.argv[3])
PYSET
}
if [ -f "$APP_DIR/settings.json" ] && command -v python3 >/dev/null 2>&1; then
    PORT="$(read_setting server.port 8000)"
fi

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
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1
        return $?
    fi
    local tool
    tool="$(port_tool)"
    case "$tool" in
        ss) ss -tln 2>/dev/null | grep -Eq "127\.0\.0\.1:${PORT}([[:space:]]|$)" ;;
        netstat) netstat -tuln 2>/dev/null | grep -Eq "127\.0\.0\.1:${PORT}([[:space:]]|$)" ;;
        *) false ;;
    esac
}

configure_discord() {
    local webhook confirm tmp
    echo "Discord notifications send approved/newly published photos to the channel attached to the webhook."
    echo "The webhook is stored in .env (permissions 600); no channel ID is needed."
    printf "Webhook URL (leave blank to disable): "
    read -r webhook
    if [ -n "$webhook" ]; then
        case "$webhook" in
            https://discord.com/api/webhooks/*|https://discordapp.com/api/webhooks/*) ;;
            *) echo "Invalid Discord webhook URL."; return 1 ;;
        esac
        printf "Confirm webhook URL: "
        read -r confirm
        if [ "$webhook" != "$confirm" ]; then
            echo "Webhook confirmation did not match."; return 1
        fi
    fi
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    tmp="$ENV_FILE.tmp.$$"
    awk -F= '!/^DISCORD_WEBHOOK_URL=/' "$ENV_FILE" > "$tmp" 2>/dev/null || true
    if [ -n "$webhook" ]; then
        printf "DISCORD_WEBHOOK_URL=%s\n" "$webhook" >> "$tmp"
    else
        printf "# DISCORD_WEBHOOK_URL=\n" >> "$tmp"
    fi
    chmod 600 "$tmp"
    mv "$tmp" "$ENV_FILE"
    echo "Discord webhook configuration saved. Restart the gallery for it to take effect."
}

configure_tunnel() {
    local token confirm tmp
    echo "Cloudflare Tunnel token is stored as a secret and is never displayed after saving."
    printf "Tunnel token (leave blank to disable): "
    read -r token
    if [ -n "$token" ]; then
        printf "Confirm tunnel token: "
        read -r confirm
        [ "$token" = "$confirm" ] || { echo "Token confirmation did not match."; return 1; }
    fi
    touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
    tmp="$ENV_FILE.tmp.$$"
    awk -F= '!/^TUNNEL_TOKEN=/' "$ENV_FILE" > "$tmp" 2>/dev/null || true
    if [ -n "$token" ]; then printf "TUNNEL_TOKEN=%s\n" "$token" >> "$tmp"; else printf "# TUNNEL_TOKEN=\n" >> "$tmp"; fi
    chmod 600 "$tmp"; mv "$tmp" "$ENV_FILE"
    echo "Tunnel configuration saved. Restart the gallery to apply it."
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
    # Create archive of DB, settings, and only this gallery's configured storage.
    STORAGE_DIR="$(read_setting server.storage_directory uploads)"
    tar -czf "$BACKUP_FILE" gallery.db settings.json "$STORAGE_DIR" 2>/dev/null || true
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
    gpg --decrypt --batch --passphrase-fd 0 "$FILE" > "$TMP_FILE" <<< "$BACKUP_PASS" || { rm -f "$TMP_FILE"; return 1; }
    if tar -tzf "$TMP_FILE" | grep -Eq '(^/|(^|/)\.\./|(^|/)\.\.$)'; then
        echo "Error: backup contains unsafe paths."; rm -f "$TMP_FILE"; return 1
    fi
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


# Hardened replacement start routine: retries a different local port, then a
# different Python runtime, without ever printing the bind address.
start() {
    local storage public quarantine staging auto_recover use_proot candidate attempts=0 started=0 proot_dir
    storage="$(read_setting server.storage_directory uploads)"; public="$(read_setting server.public_path public)"; quarantine="$(read_setting server.quarantine_path quarantine)"; staging="$(read_setting server.staging_path staging)"
    for part in "$storage" "$public" "$quarantine" "$staging"; do case "$part" in ""|.|..|*/*|*..*) echo "Error: unsafe storage setting."; return 1;; esac; done
    mkdir -p "$APP_DIR/$storage/$public" "$APP_DIR/$storage/$quarantine" "$APP_DIR/$storage/$staging" "$APP_DIR/logs"
    chmod 700 "$APP_DIR/$storage" "$APP_DIR/$storage/$public" "$APP_DIR/$storage/$quarantine" "$APP_DIR/$storage/$staging" 2>/dev/null || true
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then echo "Gallery is already running."; return 0; fi
    [ -f "$APP_DIR/.admin_pass_hash" ] || { echo "Admin password is not configured. Run install.sh first."; return 1; }
    ADMIN_PASSWORD_HASH="$(cat "$APP_DIR/.admin_pass_hash")"; export ADMIN_PASSWORD_HASH
    auto_recover="$(read_setting runtime.auto_recover true)"; use_proot="$(read_setting runtime.use_proot false)"
    load_env_safe "$ENV_FILE"
    candidate="$(read_setting server.port 8000)"
    while [ "$attempts" -lt 4 ]; do
        PORT="$candidate"; attempts=$((attempts+1)); rm -f "$PID_FILE"
        echo "Starting gallery (attempt $attempts)..."
        if [ "$use_proot" = "true" ] || [ "$use_proot" = "True" ]; then
            if command -v proot-distro >/dev/null 2>&1; then
                # proot-distro does NOT put the Termux app directory at $HOME
                # inside Debian (Debian's root user has its own $HOME=/root).
                # Bind-mount it explicitly to a fixed, known path.
                proot_dir="/root/$APP_NAME"
                if ! proot-distro login debian --bind "$APP_DIR:$proot_dir" -- env ADMIN_PASSWORD_HASH="$ADMIN_PASSWORD_HASH" REPO_DIR="$proot_dir" PORT="$PORT" bash -c '
                    cd "$REPO_DIR" || exit 1
                    [ -f /opt/venv/bin/activate ] || { echo "Python environment missing inside Debian; rerun install.sh" >&2; exit 1; }
                    source /opt/venv/bin/activate
                    nohup python3 -m uvicorn backend.main:app --host 127.0.0.1 --port "$PORT" --no-access-log --no-server-header --log-level warning >> logs/app.log 2>&1 &
                    echo $! > app.pid
                '; then
                    echo "Debian/proot startup failed; see logs/app.log for detail."
                fi
            else
                echo "Error: native Python environment is unavailable and proot-distro is not installed."
            fi
        elif [ -x "$APP_DIR/.venv/bin/python" ]; then
            (cd "$APP_DIR" && nohup "$APP_DIR/.venv/bin/python" -m uvicorn backend.main:app --host 127.0.0.1 --port "$PORT" --no-access-log --no-server-header --log-level warning >> "$LOG_FILE" 2>&1 & echo $! > "$PID_FILE")
        elif command -v python3 >/dev/null 2>&1; then
            (cd "$APP_DIR" && nohup python3 -m uvicorn backend.main:app --host 127.0.0.1 --port "$PORT" --no-access-log --no-server-header --log-level warning >> "$LOG_FILE" 2>&1 & echo $! > "$PID_FILE")
        fi
        for _ in 1 2 3 4 5 6 7 8 9 10; do is_port_open && { started=1; break; }; sleep 1; done
        if [ "$started" -eq 1 ]; then
            if [ "$PORT" != "$(read_setting server.port 8000)" ] && [ "$auto_recover" = "true" ]; then
                python3 - "$APP_DIR/settings.json" "$PORT" <<'PYPORT'
import json,sys,tempfile,os
p=sys.argv[1]; port=int(sys.argv[2]); d=json.load(open(p,encoding='utf-8')); d.setdefault('server',{})['port']=port
fd,t=tempfile.mkstemp(dir=os.path.dirname(p));
with os.fdopen(fd,'w') as f: json.dump(d,f,indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())
os.chmod(t,0o600); os.replace(t,p)
PYPORT
                echo "The configured port was unavailable, so the gallery recovered automatically and saved a working port."
            else echo "Gallery started successfully."; fi
            if [ -n "${TUNNEL_TOKEN:-}" ] && [ -x "$APP_DIR/bin/cloudflared" ]; then
                echo "Starting Cloudflare Tunnel..."
                nohup "$APP_DIR/bin/cloudflared" tunnel --token "$TUNNEL_TOKEN" run > "$APP_DIR/logs/tunnel.log" 2>&1 &
                echo $! > "$TUNNEL_PID_FILE"
            fi
            return 0
        fi
        rm -f "$PID_FILE"
        [ "$auto_recover" = "true" ] || break
        candidate=$((candidate+1))
        use_proot="false"
    done
    echo "Gallery could not start after automatic recovery attempts. Check the local log file from the menu."
    return 1
}

# Only dispatch when executed directly (not when sourced by scripts/menu.sh).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        start) start ;;
        stop) stop ;;
        restart) stop; start ;;
        status) status ;;
        logs) logs ;;
        backup) backup ;;
        restore) restore "${2:-}" ;;
        settings) exec python3 "$SCRIPT_DIR/settings_cli.py" ;;
        discord) configure_discord ;;
        tunnel) configure_tunnel ;;
        *) echo "Usage: $0 {start|stop|restart|status|logs|backup|restore|settings|discord|tunnel}" ;;
    esac
fi
