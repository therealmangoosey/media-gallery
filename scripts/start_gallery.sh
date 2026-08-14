#!/data/data/com.termux/files/usr/bin/bash
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
listen_host="$(read_setting server.host 0.0.0.0)"; case "$listen_host" in 0.0.0.0|127.0.0.1|localhost) ;; *) listen_host=0.0.0.0;; esac
auto_recover="$(read_setting runtime.auto_recover true)"
load_env
[ -s "$APP_DIR/.admin_pass_hash" ] || { fail "Missing .admin_pass_hash. Run install.sh first."; exit 1; }
export ADMIN_PASSWORD_HASH="$(cat "$APP_DIR/.admin_pass_hash")"
if [ -f "$PID_FILE" ]; then old="$(cat "$PID_FILE" 2>/dev/null || true)"; if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null && health "$port"; then log "Gallery is already running (PID $old, port $port)."; exit 0; fi; rm -f "$PID_FILE"; fi
install_native_deps(){
  local py="$1"
  log "Preparing the native Termux build toolchain for Python dependencies."
  command -v pkg >/dev/null 2>&1 || { log "Termux pkg command is unavailable."; return 1; }
  if ! command -v rustc >/dev/null 2>&1 || ! command -v cargo >/dev/null 2>&1; then
    log "pydantic-core requires a native Rust build on Termux; installing rust, clang and pkg-config."
    pkg update >>"$LOG_FILE" 2>&1 || true
    pkg install -y --fix-missing rust clang pkg-config >>"$LOG_FILE" 2>&1 || return 1
  fi
  "$py" -m pip --version >/dev/null 2>&1 || return 1
  log "Installing missing Termux dependencies from requirements.txt."
  if (cd "$APP_DIR" && "$py" -m pip install -r requirements.txt >>"$LOG_FILE" 2>&1); then return 0; fi
  log "Retrying dependency installation without build isolation."
  (cd "$APP_DIR" && "$py" -m pip install --no-build-isolation -r requirements.txt >>"$LOG_FILE" 2>&1)
}
native_preflight(){ local py="$1"; (cd "$APP_DIR" && PYTHONPATH="$APP_DIR${PYTHONPATH:+:$PYTHONPATH}" "$py" -c 'import fastapi,uvicorn,sqlalchemy,PIL; import backend.main; print("PRE-FLIGHT OK", flush=True)'); }
start_native(){ local py="$1" p="$2"; [ -x "$py" ] || return 1; log "Testing Termux Python: $py"; if ! native_preflight "$py" >>"$LOG_FILE" 2>&1; then log "Termux dependencies/import are unavailable; attempting automatic repair."; install_native_deps "$py" || return 1; native_preflight "$py" >>"$LOG_FILE" 2>&1 || return 1; fi; log "Termux preflight passed. Starting Uvicorn on $listen_host:$p"; rm -f "$PID_FILE"; (cd "$APP_DIR" && nohup env PYTHONPATH="$APP_DIR${PYTHONPATH:+:$PYTHONPATH}" "$py" -m uvicorn backend.main:app --host "$listen_host" --port "$p" --no-access-log --no-server-header --log-level info >>"$LOG_FILE" 2>&1 & echo $! >"$PID_FILE"); }
: > "$LOG_FILE"; log "===== startup attempt ====="; log "Termux-only runtime | host: $listen_host | port: $port | auto_recover=$auto_recover"
started=0
if [ -x "$APP_DIR/.venv/bin/python" ]; then start_native "$APP_DIR/.venv/bin/python" "$port" && started=1; fi
if [ "$started" -eq 0 ]; then log "Project .venv unavailable; trying Termux system Python."; py="$(command -v python3 || true)"; [ -n "$py" ] && start_native "$py" "$port" && started=1; fi
[ "$started" -eq 1 ] || { fail "No usable Termux Python environment could start the application. Run install.sh to repair the environment."; tail -n 100 "$LOG_FILE" | sed 's/^/[startup] /'; exit 1; }
healthy=0
for _ in $(seq 1 20); do if health "$port"; then healthy=1; pid="$(cat "$PID_FILE" 2>/dev/null || true)"; log "Gallery is healthy on http://127.0.0.1:$port (PID ${pid:-unknown})."; break; fi; sleep 1; done
if [ "$healthy" -ne 1 ]; then fail "Termux process did not become healthy on port $port."; tail -n 100 "$LOG_FILE" | sed 's/^/[startup] /'; pid="$(cat "$PID_FILE" 2>/dev/null || true)"; [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true; rm -f "$PID_FILE"; exit 1; fi
get_ip(){ ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}'; }
ip="$(get_ip || true)"; echo ""; echo "================ Connection Info ================"; echo "This device: http://127.0.0.1:$port"; if [ -n "$ip" ]; then echo "Other devices on this Wi-Fi/network: http://$ip:$port"; else echo "Other devices on this Wi-Fi/network: http://<tablet-LAN-IP>:$port"; fi; if [ -n "${TUNNEL_URL:-}" ]; then echo "Cloudflare Tunnel: $TUNNEL_URL"; elif [ -n "${TUNNEL_TOKEN:-}" ]; then echo "Cloudflare Tunnel: enabled"; else echo "Cloudflare Tunnel: off"; fi; echo "=================================================="
if [ -n "${TUNNEL_TOKEN:-}" ] && [ -x "$APP_DIR/bin/cloudflared" ]; then nohup "$APP_DIR/bin/cloudflared" tunnel --token "$TUNNEL_TOKEN" run >> "$APP_DIR/logs/tunnel.log" 2>&1 & echo $! > "$APP_DIR/tunnel.pid"; fi
exit 0
