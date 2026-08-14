#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$APP_DIR/logs"; LOG_FILE="$LOG_DIR/app.log"; PID_FILE="$APP_DIR/app.pid"; ENV_FILE="$APP_DIR/.env"
mkdir -p "$LOG_DIR"; touch "$LOG_FILE" 2>/dev/null || { echo "ERROR: cannot create $LOG_FILE"; exit 1; }; chmod 600 "$LOG_FILE" 2>/dev/null || true
log(){ printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" | tee -a "$LOG_FILE"; }
fail(){ log "STARTUP ERROR: $*"; return 1; }
read_setting(){ python3 - "$APP_DIR/settings.json" "$1" "$2" <<'PY'
import json,sys
try:
 with open(sys.argv[1],encoding='utf-8') as f:d=json.load(f)
 for p in sys.argv[2].split('.'): d=d[p]
 print(d)
except Exception: print(sys.argv[3])
PY
}
load_env(){ [ -f "$ENV_FILE" ] || return 0; while IFS= read -r line || [ -n "$line" ]; do case "$line" in ''|\#*) continue;; esac; key="${line%%=*}"; value="${line#*=}"; case "$key" in DISCORD_WEBHOOK_URL|TUNNEL_TOKEN|TUNNEL_URL|TURNSTILE_SECRET_KEY|GALLERY_SECRET_KEY) ;; *) continue;; esac; case "$value" in \"*\") value="${value#\"}"; value="${value%\"}";; \'*\') value="${value#\'}"; value="${value%\'}";; esac; export "$key=$value"; done < "$ENV_FILE"; }
health(){ local port="$1"; if command -v curl >/dev/null 2>&1; then curl -fsS --max-time 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1; return $?; fi; python3 - "$port" <<'PY'
import sys,urllib.request
try:
 with urllib.request.urlopen(f'http://127.0.0.1:{int(sys.argv[1])}/health',timeout=2) as r: raise SystemExit(0 if r.status==200 else 1)
except Exception: raise SystemExit(1)
PY
}
port="$(read_setting server.port 8000)"; [[ "$port" =~ ^[0-9]+$ ]] || port=8000; [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || port=8000
auto_recover="$(read_setting runtime.auto_recover true)"; use_proot="$(read_setting runtime.use_proot false)"; listen_host="$(read_setting server.listen_host 0.0.0.0)"
case "$listen_host" in 0.0.0.0|127.0.0.1|localhost) ;; *) listen_host=0.0.0.0;; esac
load_env
[ -s "$APP_DIR/.admin_pass_hash" ] || { fail "Missing .admin_pass_hash. Run install.sh first."; exit 1; }
export ADMIN_PASSWORD_HASH="$(cat "$APP_DIR/.admin_pass_hash")"
if [ -f "$PID_FILE" ]; then old="$(cat "$PID_FILE" 2>/dev/null || true)"; if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null && health "$port"; then log "Gallery is already running (PID $old, port $port)."; exit 0; fi; rm -f "$PID_FILE"; fi
install_native_deps(){ local py="$1"; log "Installing missing native dependencies from requirements.txt."; "$py" -m pip --version >/dev/null 2>&1 || return 1; (cd "$APP_DIR" && "$py" -m pip install -r requirements.txt >>"$LOG_FILE" 2>&1); }
native_preflight(){ local py="$1"; (cd "$APP_DIR" && PYTHONPATH="$APP_DIR${PYTHONPATH:+:$PYTHONPATH}" "$py" -c 'import fastapi,uvicorn,sqlalchemy,PIL; import backend.main; print("PRE-FLIGHT OK", flush=True)'); }
start_native(){ local py="$1" p="$2"; [ -x "$py" ] || return 1; log "Testing native Python: $py"; if ! native_preflight "$py" >>"$LOG_FILE" 2>&1; then log "Native dependencies/import are unavailable; attempting repair."; install_native_deps "$py" || return 1; native_preflight "$py" >>"$LOG_FILE" 2>&1 || return 1; fi; log "Native preflight passed. Starting Uvicorn on $listen_host:$p"; rm -f "$PID_FILE"; (cd "$APP_DIR" && nohup env PYTHONPATH="$APP_DIR${PYTHONPATH:+:$PYTHONPATH}" "$py" -m uvicorn backend.main:app --host "$listen_host" --port "$p" --no-access-log --no-server-header --log-level info >>"$LOG_FILE" 2>&1 & echo $! >"$PID_FILE"); }
start_proot(){ command -v proot-distro >/dev/null 2>&1 || { log "proot-distro is not installed."; return 1; }; local app_name proot_dir; app_name="$(basename "$APP_DIR")"; proot_dir="/root/$app_name"; log "Testing Debian/proot Python and verifying the bound application directory."; if ! proot-distro login debian --bind "$APP_DIR:$proot_dir" -- env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root ADMIN_PASSWORD_HASH="$ADMIN_PASSWORD_HASH" REPO_DIR="$proot_dir" PORT="$port" LISTEN_HOST="$listen_host" /bin/bash -c 'set -e; test -f "$REPO_DIR/backend/main.py"; test -x /opt/venv/bin/python; cd "$REPO_DIR"; PYTHONPATH="$REPO_DIR" /opt/venv/bin/python -c "import fastapi,uvicorn,sqlalchemy,PIL; import backend.main; print(\"PRE-FLIGHT OK\", flush=True)"' >>"$LOG_FILE" 2>&1; then log "Debian/proot preflight failed."; return 1; fi; log "Debian/proot preflight passed. Launching persistent proot process on $listen_host:$port"; rm -f "$PID_FILE"; nohup proot-distro login debian --bind "$APP_DIR:$proot_dir" -- env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root ADMIN_PASSWORD_HASH="$ADMIN_PASSWORD_HASH" REPO_DIR="$proot_dir" PORT="$port" LISTEN_HOST="$listen_host" /bin/bash -c 'cd "$REPO_DIR" && exec env PYTHONPATH="$REPO_DIR" /opt/venv/bin/python -m uvicorn backend.main:app --host "$LISTEN_HOST" --port "$PORT" --no-access-log --no-server-header --log-level info' >>"$LOG_FILE" 2>&1 & echo $! > "$PID_FILE"; log "Persistent proot launcher started with PID $(cat "$PID_FILE")"; }
: > "$LOG_FILE"; log "===== startup attempt ====="; log "Configured host: $listen_host | port: $port | use_proot=$use_proot | auto_recover=$auto_recover"
started=0
if [ "$use_proot" = "true" ] || [ "$use_proot" = "True" ]; then start_proot && started=1; if [ "$started" -eq 0 ] && [ -x "$APP_DIR/.venv/bin/python" ]; then log "Proot failed; trying native .venv recovery."; start_native "$APP_DIR/.venv/bin/python" "$port" && started=1; fi; else [ -x "$APP_DIR/.venv/bin/python" ] && start_native "$APP_DIR/.venv/bin/python" "$port" && started=1; if [ "$started" -eq 0 ]; then log "Native .venv unavailable or failed; trying system Python."; py="$(command -v python3 || true)"; [ -n "$py" ] && start_native "$py" "$port" && started=1; fi; if [ "$started" -eq 0 ] && command -v proot-distro >/dev/null 2>&1; then log "Native Python failed; trying Debian/proot recovery."; start_proot && started=1; fi; fi
[ "$started" -eq 1 ] || { fail "No usable Python environment could start the application."; tail -n 60 "$LOG_FILE" | sed 's/^/[startup] /'; exit 1; }
for _ in $(seq 1 20); do if health "$port"; then pid="$(cat "$PID_FILE" 2>/dev/null || true)"; log "Gallery is healthy on http://127.0.0.1:$port (PID ${pid:-unknown})."; break; fi; sleep 1; done
if ! health "$port"; then fail "Process did not become healthy on port $port."; tail -n 60 "$LOG_FILE" | sed 's/^/[startup] /'; pid="$(cat "$PID_FILE" 2>/dev/null || true)"; [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true; rm -f "$PID_FILE"; exit 1; fi
get_ip(){ ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}'; }
ip="$(get_ip || true)"; echo ""; echo "================ Connection Info ================"; echo "Own device: http://127.0.0.1:$port"; if [ -n "$ip" ]; then echo "Other devices on your network: http://$ip:$port"; else echo "Other devices on your network: http://<tablet-LAN-IP>:$port"; fi; if [ -n "${TUNNEL_URL:-}" ]; then echo "Cloudflare Tunnel: $TUNNEL_URL"; elif [ -n "${TUNNEL_TOKEN:-}" ]; then echo "Cloudflare Tunnel: enabled (use your configured Cloudflare hostname)"; else echo "Cloudflare Tunnel: off"; fi; echo "=================================================="
if [ -n "${TUNNEL_TOKEN:-}" ] && [ -x "$APP_DIR/bin/cloudflared" ]; then nohup "$APP_DIR/bin/cloudflared" tunnel --token "$TUNNEL_TOKEN" run >> "$APP_DIR/logs/tunnel.log" 2>&1 & echo $! > "$APP_DIR/tunnel.pid"; fi
exit 0
