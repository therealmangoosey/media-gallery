#!/bin/bash

# Interactive command-line menu for Media Gallery.
#
# Prints an ASCII-art banner and a numbered list of options, reads a numeric
# selection, validates it, and dispatches to the corresponding function (which
# is sourced from manage.sh). After each action the menu is redisplayed until
# the user chooses to exit. Invalid input prints an error and reprompts.

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

# Colors (only when stdout is a terminal, so output stays clean when piped).
if [ -t 1 ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_CYAN=$'\033[36m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_DIM=$'\033[2m'
else
    C_RESET='' C_BOLD='' C_CYAN='' C_GREEN='' C_YELLOW='' C_RED='' C_DIM=''
fi

# Menu entries: "label|function_name"
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
    printf '%s\n' "${C_DIM}Self-hosted, private-by-design image gallery${C_RESET}"
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
    # Only prompt when running interactively (stdin is a terminal).
    if [ -t 0 ]; then
        read -rp "Press Enter to return to the menu..." _dummy
    fi
}

# --- Menu actions -----------------------------------------------------------

do_start() { start; }

do_stop() { stop; }

do_restart() { stop; start; }

do_status() { status; }

do_logs() { logs; }

do_backup() { backup; }

do_restore() {
    local file
    read -rp "Path to backup file (.gpg): " file
    if [ -z "$file" ]; then
        echo "No file provided."
        return 1
    fi
    restore "$file"
}

do_settings() {
    python3 "$SCRIPT_DIR/settings_cli.py"
}

do_discord() { configure_discord; }
do_tunnel() { configure_tunnel; }

do_sec_test() {
    bash "$SCRIPT_DIR/test_security.sh"
}

do_update() {
    bash "$SCRIPT_DIR/update.sh"
}

dispatch() {
    case "$1" in
        1) do_start ;;
        2) do_stop ;;
        3) do_restart ;;
        4) do_status ;;
        5) do_logs ;;
        6) do_backup ;;
        7) do_restore ;;
        8) do_settings ;;
        9) do_discord ;;
        10) do_tunnel ;;
        11) do_sec_test ;;
        *) return 1 ;;
    esac
}

# --- Main loop --------------------------------------------------------------

main() {
    local choice
    while true; do
        show_banner
        show_menu

        read -rp "Selection [0-${#MENU_ITEMS[@]}]: " choice || { echo ""; break; }

        # Validate: must be a non-negative integer within range.
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

        dispatch "$choice" || {
            echo "${C_RED}Error: could not run selection $choice.${C_RESET}"
        }

        pause
    done
}

main "$@"
