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
    with open(sys.argv[1],encoding='utf-8') as f: d=json.load(f)
    for p in sys.argv[2].split('.'): d=d[p]
    print(d)
except Exception: print(sys.argv[3])
PYSET
}

if [ -f "$APP_DIR/settings.json" ] && command -v python3 >/dev/null 2>&1; then
    PORT="$(read_setting server.port 8000)"
fi

load_env_safe() {
    local file="$1" line key value
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            DISCORD_WEBHOOK_URL|TUNNEL_TOKEN|TURNSTILE_SECRET_KEY|GALLERY_SECRET_KEY)
                ;;
            *) continue ;;
        esac
        [ -n "$key" ] || continue
        case "$value" in
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
        esac
        export "$key=$value"
    done < "$file"
}

port_tool() {
    if command -v ss >/dev/null 2>&1; then echo "ss"
    elif command -v netstat >/dev/null 2>&1; then echo "netstat"
    else echo ""
    fi
}

is_port_open() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1
        return $?
    fi
    local tool; tool="$(port_tool)"
    case "$tool" in
        ss) ss -tln 2>/dev/null | grep -Eq "127\.0\.0\.1:${PORT}([[:space:]]|$)" ;;
        netstat) netstat -tuln 2>/dev/null | grep -Eq "127\.0\.0\.1:${PORT}([[:space:]]|$)" ;;
        *) false ;;
    esac
}

configure_discord() {
    local webhook confirm tmp
    echo "Discord notifications send approved/newly published media to the channel attached to the webhook."
    printf "Webhook URL (leave blank to disable): "; read -r webhook
    if [ -n "$webhook" ]; then
        case "$webhook" in
            https://discord.com/api/webhooks/*|https://discordapp.com/api/webhooks/*) ;;
            *) echo "Invalid Discord webhook URL."; return 1 ;;
        esac
        printf "Confirm webhook URL: "; read -r confirm
        [ "$webhook" = "$confirm" ] || { echo "Webhook confirmation did not match."; return 1; }
    fi
    touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
    tmp="$ENV_FILE.tmp.$$"
    awk -F= '!/^DISCORD_WEBHOOK_URL=/' "$ENV_FILE" > "$tmp" 2>/dev/null || true
    if [ -n "$webhook" ]; then printf "DISCORD_WEBHOOK_URL=%s\n" "$webhook" >> "$tmp"; else printf "# DISCORD_WEBHOOK_URL=\n" >> "$tmp"; fi
    chmod 600 "$tmp"; mv "$tmp" "$ENV_FILE"
    echo "Discord webhook configuration saved. Restart the gallery for it to take effect."
}

configure_tunnel() {
    local token confirm tmp
    echo "Cloudflare Tunnel token is stored as a secret and is never displayed after saving."
    printf "Tunnel token (leave blank to disable): "; read -r token
    if [ -n "$token" ]; then
        printf "Confirm tunnel token: "; read -r confirm
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
    local stopped=0 pid
    if [ -f "$PID_FILE" ]; then
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null; then
            echo "Stopped Gallery App (PID: $pid)"; stopped=1
        else echo "Gallery App process not found (stale PID file)."; fi
        rm -f "$PID_FILE"
    else
        if pkill -f "uvicorn backend.main:app" 2>/dev/null; then echo "Stopped Gallery App (found via pkill)."; stopped=1; fi
    fi
    [ "$stopped" -eq 1 ] || echo "App is not running."
    if [ -f "$TUNNEL_PID_FILE" ]; then
        local tpid; tpid="$(cat "$TUNNEL_PID_FILE" 2>/dev/null || true)"
        if [[ "$tpid" =~ ^[0-9]+$ ]]; then kill "$tpid" 2>/dev/null || true; fi
        rm -f "$TUNNEL_PID_FILE"
    fi
}

backup() {
    command -v gpg >/dev/null 2>&1 || { echo "Error: 'gpg' is not installed."; return 1; }
    echo "Creating backup..."; cd "$APP_DIR" || return 1
    local timestamp backup_file storage_dir backup_pass
    timestamp=$(date +%Y%m%d_%H%M%S); backup_file="$APP_DIR/backup_$timestamp.tar.gz"; storage_dir="$(read_setting server.storage_directory uploads)"
    tar -czf "$backup_file" gallery.db settings.json "$storage_dir" 2>/dev/null || { echo "Backup archive creation failed."; rm -f "$backup_file"; return 1; }
    read -r -s -p "Enter Backup Encryption Password: " backup_pass; echo
    if ! gpg --symmetric --batch --passphrase-fd 0 "$backup_file" <<< "$backup_pass"; then rm -f "$backup_file"; return 1; fi
    rm -f "$backup_file"; echo "Backup created: $backup_file.gpg"
}

restore() {
    local file="${1:-}" backup_pass tmp_file
    [ -n "$file" ] || { echo "Usage: $0 restore <file.gpg>"; return 1; }
    [ -f "$file" ] || { echo "Error: backup file not found: $file"; return 1; }
    read -r -s -p "Enter Backup Decryption Password: " backup_pass; echo
    tmp_file="$APP_DIR/restored.tar.gz"
    gpg --decrypt --batch --passphrase-fd 0 "$file" > "$tmp_file" <<< "$backup_pass" || { rm -f "$tmp_file"; return 1; }
    if tar -tzf "$tmp_file" | grep -Eq '(^/|(^|/)\.\./|(^|/)\.\.$)'; then echo "Error: backup contains unsafe paths."; rm -f "$tmp_file"; return 1; fi
    tar -xzf "$tmp_file" -C "$APP_DIR" || { rm -f "$tmp_file"; return 1; }
    rm -f "$tmp_file"; echo "Restore complete."
}

status() {
    local pid=''
    if [ -f "$PID_FILE" ]; then pid="$(cat "$PID_FILE" 2>/dev/null || true)"; fi
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && is_port_open; then
        echo "App is running (PID: $pid)"
    elif is_port_open; then
        echo "App is running (responding on port $PORT; PID file missing or stale)."
    else
        echo "App is not running."
    fi
}

logs() {
    if [ -f "$LOG_FILE" ]; then tail -n 100 "$LOG_FILE"; else echo "No log file found yet ($LOG_FILE)."; fi
}

write_log_header() {
    mkdir -p "$APP_DIR/logs"; touch "$LOG_FILE"; chmod 600 "$LOG_FILE" 2>/dev/null || true
    printf '\n[%s] ===== startup attempt =====\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" >> "$LOG_FILE"
}
record_start_error() { printf '[%s] STARTUP ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$1" >> "$LOG_FILE"; }

start() {
    local storage public quarantine staging auto_recover use_proot candidate attempts=0 started=0 proot_dir native_python
    storage="$(read_setting server.storage_directory uploads)"; public="$(read_setting server.public_path public)"; quarantine="$(read_setting server.quarantine_path quarantine)"; staging="$(read_setting server.staging_path staging)"
    for part in "$storage" "$public" "$quarantine" "$staging"; do case "$part" in ""|.|..|*/*|*..*) echo "Error: unsafe storage setting."; return 1;; esac; done
    mkdir -p "$APP_DIR/$storage/$public" "$APP_DIR/$storage/$quarantine" "$APP_DIR/$storage/$staging" "$APP_DIR/logs" || { echo "Error: cannot create required directories."; return 1; }
    chmod 700 "$APP_DIR/$storage" "$APP_DIR/$storage/$public" "$APP_DIR/$storage/$quarantine" "$APP_DIR/$storage/$staging" 2>/dev/null || true
    write_log_header
    if [ -f "$PID_FILE" ]; then
        local existing_pid; existing_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null && is_port_open; then echo "Gallery is already running."; return 0; fi
        rm -f "$PID_FILE"
    fi
    if [ ! -s "$APP_DIR/.admin_pass_hash" ]; then record_start_error "Admin password hash is missing. Run install.sh first."; echo "Admin password is not configured. Run install.sh first."; return 1; fi
    ADMIN_PASSWORD_HASH="$(cat "$APP_DIR/.admin_pass_hash")"; export ADMIN_PASSWORD_HASH
    auto_recover="$(read_setting runtime.auto_recover true)"; use_proot="$(read_setting runtime.use_proot false)"; load_env_safe "$ENV_FILE"
    candidate="$(read_setting server.port 8000)"; [[ "$candidate" =~ ^[0-9]+$ ]] || candidate=8000; if [ "$candidate" -lt 1024 ] || [ "$candidate" -gt 65535 ]; then candidate=8000; fi
    while [ "$attempts" -lt 4 ]; do
        PORT="$candidate"; attempts=$((attempts+1)); started=0; rm -f "$PID_FILE"; echo "Starting gallery (attempt $attempts)..."; write_log_header; native_python="$APP_DIR/.venv/bin/python"
        if [ "$use_proot" = "true" ] || [ "$use_proot" = "True" ]; then
            if command -v proot-distro >/dev/null 2>&1; then
                proot_dir="/root/$APP_NAME"
                if ! proot-distro login debian --bind "$APP_DIR:$proot_dir" -- env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root ADMIN_PASSWORD_HASH="$ADMIN_PASSWORD_HASH" REPO_DIR="$proot_dir" PORT="$PORT" bash -c '
                    cd "$REPO_DIR" || exit 1
                    [ -x /opt/venv/bin/python ] || { echo "Python environment missing inside Debian; rerun install.sh" >&2; exit 1; }
                    nohup /opt/venv/bin/python -m uvicorn backend.main:app --host 127.0.0.1 --port "$PORT" --no-access-log --no-server-header --log-level warning >> logs/app.log 2>&1 &
                    echo $! > app.pid
                '; then record_start_error "Debian/proot launch command failed."; fi
            else record_start_error "runtime.use_proot is enabled but proot-distro is not installed."; fi
        elif [ -x "$native_python" ]; then
            (cd "$APP_DIR" && nohup "$native_python" -m uvicorn backend.main:app --host 127.0.0.1 --port "$PORT" --no-access-log --no-server-header --log-level warning >> "$LOG_FILE" 2>&1 & echo $! > "$PID_FILE")
        elif command -v python3 >/dev/null 2>&1; then
            (cd "$APP_DIR" && nohup python3 -m uvicorn backend.main:app --host 127.0.0.1 --port "$PORT" --no-access-log --no-server-header --log-level warning >> "$LOG_FILE" 2>&1 & echo $! > "$PID_FILE")
        else record_start_error "No usable Python runtime was found."; echo "Python 3 is not available. Run install.sh again."; return 1; fi
        for _ in 1 2 3 4 5 6 7 8 9 10; do if is_port_open; then started=1; break; fi; sleep 1; done
        if [ "$started" -eq 1 ]; then
            local configured_port; configured_port="$(read_setting server.port 8000)"
            if [ "$PORT" != "$configured_port" ] && [ "$auto_recover" = "true" ]; then
                if python3 - "$APP_DIR/settings.json" "$PORT" <<'PYPORT'
import json,sys,tempfile,os
p=sys.argv[1]; port=int(sys.argv[2])
try:
 with open(p,encoding='utf-8') as f:d=json.load(f)
except Exception:d={}
d.setdefault('server',{})['port']=port
fd,t=tempfile.mkstemp(dir=os.path.dirname(p));
with os.fdopen(fd,'w',encoding='utf-8') as f:json.dump(d,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
os.chmod(t,0o600);os.replace(t,p)
PYPORT
                then echo "The configured port was unavailable; the gallery recovered automatically and saved the working port."; else record_start_error "Gallery started on fallback port but settings could not be updated."; fi
            else echo "Gallery started successfully."; fi
            if [ -n "${TUNNEL_TOKEN:-}" ] && [ -x "$APP_DIR/bin/cloudflared" ]; then echo "Starting Cloudflare Tunnel..."; nohup "$APP_DIR/bin/cloudflared" tunnel --token "$TUNNEL_TOKEN" run >> "$APP_DIR/logs/tunnel.log" 2>&1 & echo $! > "$TUNNEL_PID_FILE"; fi
            return 0
        fi
        if [ -f "$LOG_FILE" ]; then record_start_error "Process did not become healthy on port $PORT. Recent output follows."; tail -n 20 "$LOG_FILE" | sed 's/^/[startup] /'; else record_start_error "Process did not become healthy and no log file was produced."; fi
        rm -f "$PID_FILE"; [ "$auto_recover" = "true" ] || break; candidate=$((candidate+1)); use_proot="false"
    done
    echo "Gallery could not start after automatic recovery attempts. Select 'View logs' for the diagnostic output."; return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        start) start ;; stop) stop ;; restart) stop; start ;; status) status ;; logs) logs ;; backup) backup ;; restore) restore "${2:-}" ;; settings) exec python3 "$SCRIPT_DIR/settings_cli.py" ;; discord) configure_discord ;; tunnel) configure_tunnel ;; *) echo "Usage: $0 {start|stop|restart|status|logs|backup|restore|settings|discord|tunnel}"; exit 2 ;; esac
fi
