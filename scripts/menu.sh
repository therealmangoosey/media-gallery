#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
. "$SCRIPT_DIR/manage.sh"
BANNER='#   # ##### ####  #####   #          ####   #   #     #     ##### ####  #   #
## ## #     #   #   #    # #        #      # #  #     #     #     #   #  # #
# # # ####  #   #   #   #####       #  ## ##### #     #     ####  ####    #
#   # #     #   #   #   #   #       #   # #   # #     #     #     #  #    #
#   # ##### ####  ##### #   #        #### #   # ##### ##### ##### #   #   #'
if [ -t 1 ]; then C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; else C_RESET='' C_BOLD='' C_CYAN='' C_GREEN='' C_YELLOW='' C_RED='' C_DIM=''; fi
MENU_ITEMS=("Start the gallery|do_start" "Stop the gallery|do_stop" "Restart the gallery|do_restart" "Show status|do_status" "View logs|do_logs" "Create encrypted backup|do_backup" "Restore from backup|do_restore" "Open full configuration panel|do_settings" "Configure Discord webhook|do_discord" "Configure Cloudflare Tunnel|do_tunnel" "Run security test|do_sec_test" "Update application (keeps media & accounts)|do_update")
EXIT_CHOICE=0
show_banner() { printf '%s\n' "${C_CYAN}${C_BOLD}${BANNER}${C_RESET}"; printf '%s\n' "${C_DIM}Self-hosted, private-by-design media gallery${C_RESET}"; }
show_menu() { echo ""; local i label; for i in "${!MENU_ITEMS[@]}"; do label="${MENU_ITEMS[$i]%%|*}"; printf '  %s%2d%s) %s\n' "$C_GREEN" "$((i+1))" "$C_RESET" "$label"; done; printf '  %s%2d%s) %s\n' "$C_RED" 0 "$C_RESET" Exit; echo ""; }
pause() { if [ -t 0 ]; then read -rp "Press Enter to return to the menu..." _dummy || true; fi; }
run_action() { local name="$1"; type "$name" >/dev/null 2>&1 || { echo "${C_RED}Error: action '$name' is unavailable.${C_RESET}"; return 1; }; "$name"; }
device_ip() { ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }
show_connections() {
  local port ip tunnel
  port="$(python3 - "$APP_DIR/settings.json" <<'PY' 2>/dev/null || echo 8000
import json,sys
try:
 with open(sys.argv[1],encoding='utf-8') as f: print(json.load(f).get('server',{}).get('port',8000))
except Exception: print(8000)
PY
)"
  ip="$(device_ip || true)"
  echo ""
  echo "================ Connection Info ================"
  echo "Own device:   http://127.0.0.1:${port}"
  if [ -n "$ip" ]; then echo "Other devices on your network: http://${ip}:${port}"; else echo "Other devices on your network: http://<tablet-LAN-IP>:${port}"; fi
  tunnel="$(grep '^TUNNEL_URL=' "$APP_DIR/.env" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  if [ -n "$tunnel" ]; then echo "Cloudflare Tunnel: $tunnel"; else echo "Cloudflare Tunnel: off (enable it in option 10)"; fi
  echo "=================================================="
}
do_start() { bash "$SCRIPT_DIR/start_gallery.sh" && show_connections; }
do_stop() { stop; }
do_restart() { stop; do_start; }
do_status() { status; show_connections; }
do_logs() { logs; }
do_backup() { backup; }
do_restore() { local file=''; if [ -t 0 ]; then read -rp "Path to backup file (.gpg): " file || return 1; fi; [ -n "$file" ] || { echo "No file provided."; return 1; }; restore "$file"; }
do_settings() { python3 "$SCRIPT_DIR/settings_cli.py"; }
do_discord() { echo "Discord configuration is not available in this build."; return 1; }
do_tunnel() { bash "$SCRIPT_DIR/configure_tunnel.sh"; }
do_sec_test() { bash "$SCRIPT_DIR/test_security.sh"; }
do_update() { bash "$SCRIPT_DIR/update.sh"; }
dispatch() { local choice="$1" index=$((choice-1)) item fn; [ "$index" -ge 0 ] && [ "$index" -lt "${#MENU_ITEMS[@]}" ] || return 1; item="${MENU_ITEMS[$index]}"; fn="${item#*|}"; run_action "$fn"; }
main() { local choice=''; while true; do show_banner; show_menu; if ! read -rp "Selection [0-${#MENU_ITEMS[@]}]: " choice; then echo ""; break; fi; if [[ ! "$choice" =~ ^[0-9]+$ ]]; then echo "${C_YELLOW}Invalid input: '$choice' is not a number.${C_RESET}"; pause; continue; fi; if [ "$choice" -eq 0 ]; then echo "Goodbye!"; break; fi; if [ "$choice" -gt "${#MENU_ITEMS[@]}" ]; then echo "${C_YELLOW}Invalid selection: $choice is out of range (1-${#MENU_ITEMS[@]}).${C_RESET}"; pause; continue; fi; if ! dispatch "$choice"; then echo "${C_RED}Error: selection $choice failed.${C_RESET}"; fi; pause; done; }
main "$@"
