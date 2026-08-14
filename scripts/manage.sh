#!/data/data/com.termux/files/usr/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
PID_FILE="$APP_DIR/app.pid"
TUNNEL_PID_FILE="$APP_DIR/tunnel.pid"
LOG_FILE="$APP_DIR/logs/app.log"
ENV_FILE="$APP_DIR/.env"

read_setting() {
  local key="$1" default="$2"
  python3 - "$APP_DIR/settings.json" "$key" "$default" <<'PY'
import json,sys
try:
    with open(sys.argv[1],encoding='utf-8') as f: d=json.load(f)
    for p in sys.argv[2].split('.'): d=d[p]
    print(d)
except Exception: print(sys.argv[3])
PY
}

PORT="$(read_setting server.port 8000)"
[[ "$PORT" =~ ^[0-9]+$ ]] || PORT=8000

health() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1
    return $?
  fi
  python3 - "$PORT" <<'PY'
import sys,urllib.request
try:
    with urllib.request.urlopen(f'http://127.0.0.1:{int(sys.argv[1])}/health',timeout=2) as r:
        raise SystemExit(0 if r.status == 200 else 1)
except Exception:
    raise SystemExit(1)
PY
}

stop() {
  local pid tpid
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      kill "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    echo "Gallery stopped."
  else
    echo "Gallery is not running."
  fi
  if [ -f "$TUNNEL_PID_FILE" ]; then
    tpid="$(cat "$TUNNEL_PID_FILE" 2>/dev/null || true)"
    [[ "$tpid" =~ ^[0-9]+$ ]] && kill "$tpid" 2>/dev/null || true
    rm -f "$TUNNEL_PID_FILE"
  fi
}

start() {
  exec "$SCRIPT_DIR/start_gallery.sh"
}

restart() {
  stop
  start
}

status() {
  local pid=''
  [ -f "$PID_FILE" ] && pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if health; then
    echo "Gallery is running on port $PORT${pid:+ (PID $pid)}."
  else
    echo "Gallery is not running."
    return 1
  fi
}

logs() {
  if [ -f "$LOG_FILE" ]; then tail -n 160 "$LOG_FILE"; else echo "No log file found yet."; fi
}

backup() {
  command -v gpg >/dev/null 2>&1 || { echo "Error: gpg is not installed."; return 1; }
  cd "$APP_DIR" || return 1
  local timestamp backup_file storage_dir backup_pass
  timestamp=$(date +%Y%m%d_%H%M%S)
  backup_file="$APP_DIR/backup_$timestamp.tar.gz"
  storage_dir="$(read_setting server.storage_directory uploads)"
  tar -czf "$backup_file" gallery.db settings.json "$storage_dir" 2>/dev/null || { echo "Backup archive creation failed."; rm -f "$backup_file"; return 1; }
  read -r -s -p "Enter Backup Encryption Password: " backup_pass; echo
  if ! gpg --symmetric --batch --passphrase-fd 0 "$backup_file" <<<"$backup_pass"; then rm -f "$backup_file"; return 1; fi
  rm -f "$backup_file"
  echo "Backup created: ${backup_file}.gpg"
}

restore() {
  local file="${1:-}" backup_pass tmp_file
  [ -n "$file" ] || { echo "Usage: $0 restore <file.gpg>"; return 1; }
  [ -f "$file" ] || { echo "Error: backup file not found: $file"; return 1; }
  read -r -s -p "Enter Backup Decryption Password: " backup_pass; echo
  tmp_file="$APP_DIR/restored.tar.gz"
  gpg --decrypt --batch --passphrase-fd 0 "$file" > "$tmp_file" <<<"$backup_pass" || { rm -f "$tmp_file"; return 1; }
  if tar -tzf "$tmp_file" | grep -Eq '(^/|(^|/)\.\./|(^|/)\.\.$)'; then echo "Error: backup contains unsafe paths."; rm -f "$tmp_file"; return 1; fi
  tar -xzf "$tmp_file" -C "$APP_DIR" || { rm -f "$tmp_file"; return 1; }
  rm -f "$tmp_file"
  echo "Restore complete. Restart the gallery before using restored data."
}

configure_discord() {
  if [ -x "$SCRIPT_DIR/configure_discord.sh" ]; then exec "$SCRIPT_DIR/configure_discord.sh"; fi
  echo "Discord configuration script is unavailable in this Termux installation."; return 1
}

configure_tunnel() {
  if [ -x "$SCRIPT_DIR/configure_tunnel.sh" ]; then exec "$SCRIPT_DIR/configure_tunnel.sh"; fi
  echo "Cloudflare Tunnel configuration script is unavailable in this Termux installation."; return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    start) start;; stop) stop;; restart) restart;; status) status;; logs) logs;; backup) backup;; restore) restore "${2:-}";; settings) exec python3 "$SCRIPT_DIR/settings_cli.py";; discord) configure_discord;; tunnel) configure_tunnel;; *) echo "Usage: $0 {start|stop|restart|status|logs|backup|restore|settings|discord|tunnel}"; exit 2;;
  esac
fi
