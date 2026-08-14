#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$APP_DIR/logs"
LOG_FILE="$LOG_DIR/app.log"
PID_FILE="$APP_DIR/app.pid"
ENV_FILE="$APP_DIR/.env"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE" 2>/dev/null || { echo "ERROR: cannot create $LOG_FILE"; exit 1; }
chmod 600 "$LOG_FILE" 2>/dev/null || true

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" | tee -a "$LOG_FILE"; }
fail() { log "STARTUP ERROR: $*"; return 1; }

read_setting() {
    python3 - "$APP_DIR/settings.json" "$1" "$2" <<'PY'
import json,sys
try:
    with open(sys.argv[1],encoding='utf-8') as f:d=json.load(f)
    for p in sys.argv[2].split('.'): d=d[p]
    print(d)
except Exception: print(sys.argv[3])
PY
}

load_env() {
    [ -f "$ENV_FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue;; esac
        key="${line%%=*}"; value="${line#*=}"
        case "$key" in
            DISCORD_WEBHOOK_URL|TUNNEL_TOKEN|TURNSTILE_SECRET_KEY|GALLERY_SECRET_KEY) ;;
            *) continue;;
        esac
        case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}";;
            \'*\') value="${value#\'}"; value="${value%\'}";;
        esac
        export "$key=$value"
    done < "$ENV_FILE"
}

health() {
    local port="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1
        return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$port" <<'PY'
import sys,urllib.request
try:
    with urllib.request.urlopen(f'http://127.0.0.1:{int(sys.argv[1])}/health',timeout=2) as r:
        raise SystemExit(0 if r.status == 200 else 1)
except Exception: raise SystemExit(1)
PY
        return $?
    fi
    return 1
}

port="$(read_setting server.port 8000)"
[[ "$port" =~ ^[0-9]+$ ]] || port=8000
if [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then port=8000; fi

auto_recover="$(read_setting runtime.auto_recover true)"
use_proot="$(read_setting runtime.use_proot false)"
load_env

if [ ! -s "$APP_DIR/.admin_pass_hash" ]; then
    fail "Missing .admin_pass_hash. Run install.sh first."
    exit 1
fi
export ADMIN_PASSWORD_HASH="$(cat "$APP_DIR/.admin_pass_hash")"

if [ -f "$PID_FILE" ]; then
    old="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null && health "$port"; then
        log "Gallery is already running (PID $old, port $port)."
        exit 0
    fi
    rm -f "$PID_FILE"
fi

start_native() {
    local py="$1" p="$2"
    [ -x "$py" ] || return 1
    log "Testing native Python: $py"
    if ! (cd "$APP_DIR" && "$py" -c 'import fastapi,uvicorn,sqlalchemy,PIL; import backend.main' >>"$LOG_FILE" 2>&1); then
        log "Native preflight failed. The traceback above is the actual import/startup error."
        return 1
    fi
    log "Native preflight passed. Starting Uvicorn on 127.0.0.1:$p"
    rm -f "$PID_FILE"
    (cd "$APP_DIR" && nohup "$py" -m uvicorn backend.main:app --host 127.0.0.1 --port "$p" --no-access-log --no-server-header --log-level info >>"$LOG_FILE" 2>&1 & echo $! >"$PID_FILE")
    return 0
}

start_system_python() {
    local py
    py="$(command -v python3 || true)"
    [ -n "$py" ] || return 1
    start_native "$py" "$port"
}

start_proot() {
    command -v proot-distro >/dev/null 2>&1 || { log "proot-distro is not installed."; return 1; }
    local app_name proot_dir
    app_name="$(basename "$APP_DIR")"
    proot_dir="/root/$app_name"

    log "Testing Debian/proot Python."
    if ! proot-distro login debian --bind "$APP_DIR:$proot_dir" -- env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root ADMIN_PASSWORD_HASH="$ADMIN_PASSWORD_HASH" REPO_DIR="$proot_dir" PORT="$port" /opt/venv/bin/python -c 'import fastapi,uvicorn,sqlalchemy,PIL; import backend.main; print("PRE-FLIGHT OK", flush=True)' >>"$LOG_FILE" 2>&1; then
        log "Debian/proot preflight failed."
        return 1
    fi

    log "Debian/proot preflight passed. Launching persistent proot process on 127.0.0.1:$port"
    rm -f "$PID_FILE"

    # Keep the proot process itself alive. Starting a background child inside a
    # short-lived `proot-distro login` shell causes that child to disappear when
    # the login session exits on Termux.
    nohup proot-distro login debian --bind "$APP_DIR:$proot_dir" -- env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root ADMIN_PASSWORD_HASH="$ADMIN_PASSWORD_HASH" REPO_DIR="$proot_dir" PORT="$port" /opt/venv/bin/python -m uvicorn backend.main:app --host 127.0.0.1 --port "$port" --no-access-log --no-server-header --log-level info >>"$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    log "Persistent proot launcher started with PID $(cat "$PID_FILE")"
    return 0
}

: > "$LOG_FILE"
log "===== startup attempt ====="
log "Configured port: $port | use_proot=$use_proot | auto_recover=$auto_recover"

started=0
if [ "$use_proot" = "true" ] || [ "$use_proot" = "True" ]; then
    start_proot && started=1
    if [ "$started" -eq 0 ] && [ -x "$APP_DIR/.venv/bin/python" ]; then
        log "Proot failed; trying native .venv recovery."
        start_native "$APP_DIR/.venv/bin/python" "$port" && started=1
    fi
else
    if [ -x "$APP_DIR/.venv/bin/python" ]; then
        start_native "$APP_DIR/.venv/bin/python" "$port" && started=1
    fi
    if [ "$started" -eq 0 ]; then
        log "Native .venv unavailable or failed; trying system Python."
        start_system_python && started=1
    fi
    if [ "$started" -eq 0 ] && command -v proot-distro >/dev/null 2>&1; then
        log "Native Python failed; trying Debian/proot recovery."
        start_proot && started=1
    fi
fi

if [ "$started" -eq 0 ]; then
    fail "No usable Python environment could start the application."
    tail -n 40 "$LOG_FILE" 2>/dev/null | sed 's/^/[startup] /'
    exit 1
fi

for _ in $(seq 1 20); do
    if health "$port"; then
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        log "Gallery is healthy on http://127.0.0.1:$port (PID ${pid:-unknown})."
        exit 0
    fi
    sleep 1
done

fail "Process did not become healthy on port $port."
tail -n 40 "$LOG_FILE" 2>/dev/null | sed 's/^/[startup] /'

pid="$(cat "$PID_FILE" 2>/dev/null || true)"
if [[ "$pid" =~ ^[0-9]+$ ]]; then kill "$pid" 2>/dev/null || true; fi
rm -f "$PID_FILE"
exit 1
