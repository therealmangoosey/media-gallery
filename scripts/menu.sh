#!/bin/bash

# Interactive command-line menu for Media Gallery.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"

# Reuse the management functions (start, stop, status, logs, backup, restore…).
# shellcheck disable=SC1091
. "$SCRIPT_DIR/manage.sh"

BANNER='#   # ##### ####  #####   #          ####   #   #     #     ##### ####  #   #
## ## #     #   #   #    # #        #      # #  #     #     #     #   #  # #
# # # ####  #   #   #   #####       #  ## ##### #     #     ####  ####    #
#   # #     #   #   #   #   #       #   # #   # #     #     #     #  #    #
#   # ##### ####  ##### #   #        #### #   # ##### ##### ##### #   #   #'

if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'
else
    C_RESET='' C_BOLD='' C_CYAN='' C_GREEN='' C_YELLOW='' C_RED='' C_DIM=''
fi

MENU_ITEMS=(
    "Start the gallery|do_start"
    "Stop the gallery|do_stop"
    "Restart the gallery|do_restart"
    "Show status|do_status"
    "View logs|do_logs"
    "Create encrypted backup|do_backup"
    "Restore from backup|do_restore"
    "Open full configuration panel|do_settings"
    "Configure Discord webhook|do_discord"
    "Configure Cloudflare Tunnel|do_tunnel"
    "Run security test|do_sec_test"
    "Update application (keeps media & accounts)|do_update"
)

EXIT_CHOICE=0

show_banner() {
    printf '%s\n' "${C_CYAN}${C_BOLD}${BANNER}${C_RESET}"
    printf '%s\n' "${C_DIM}Self-hosted, private-by-design media gallery${C_RESET}"
}

show_menu() {
    echo ""
    local i label
    for i in "${!MENU_ITEMS[@]}"; do
        label="${MENU_ITEMS[$i]%%|*}"
        printf '  %s%2d%s) %s\n' "${C_GREEN}" "$((i + 1))" "${C_RESET}" "$label"
    done
    printf '  %s%2d%s) %s\n' "${C_RED}" "$EXIT_CHOICE" "${C_RESET}" "Exit"
    echo ""
}

pause() {
    if [ -t 0 ]; then
        read -rp "Press Enter to return to the menu..." _dummy || true
    fi
}

run_action() {
    local name="$1"
    if ! type "$name" >/dev/null 2>&1; then
        echo "${C_RED}Error: action '$name' is unavailable.${C_RESET}"
        return 1
    fi
    "$name"
}

do_start() { start; }
do_stop() { stop; }
do_restart() { stop; start; }
do_status() { status; }
do_logs() { logs; }
do_backup() { backup; }
do_restore() {
    local file=''
    if [ -t 0 ]; then
        read -rp "Path to backup file (.gpg): " file || return 1
    fi
    if [ -z "$file" ]; then
        echo "No file provided."
        return 1
    fi
    restore "$file"
}
do_settings() { python3 "$SCRIPT_DIR/settings_cli.py"; }
do_discord() { configure_discord; }
do_tunnel() { configure_tunnel; }
do_sec_test() { bash "$SCRIPT_DIR/test_security.sh"; }
do_update() { bash "$SCRIPT_DIR/update.sh"; }

dispatch() {
    local choice="$1" index=$((choice - 1)) item fn
    if [ "$index" -lt 0 ] || [ "$index" -ge "${#MENU_ITEMS[@]}" ]; then
        return 1
    fi
    item="${MENU_ITEMS[$index]}"
    fn="${item#*|}"
    run_action "$fn"
}

main() {
    local choice=''
    while true; do
        show_banner
        show_menu

        if ! read -rp "Selection [0-${#MENU_ITEMS[@]}]: " choice; then
            echo ""
            break
        fi

        if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
            echo "${C_YELLOW}Invalid input: '$choice' is not a number.${C_RESET}"
            pause
            continue
        fi

        if [ "$choice" -eq "$EXIT_CHOICE" ]; then
            echo "Goodbye!"
            break
        fi

        if [ "$choice" -gt "${#MENU_ITEMS[@]}" ]; then
            echo "${C_YELLOW}Invalid selection: $choice is out of range (1-${#MENU_ITEMS[@]}).${C_RESET}"
            pause
            continue
        fi

        if ! dispatch "$choice"; then
            echo "${C_RED}Error: selection $choice failed.${C_RESET}"
        fi
        pause
    done
}

main "$@"
