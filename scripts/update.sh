#!/data/data/com.termux/files/usr/bin/bash
# In-place update of Media Gallery application code.
# Never deletes or overwrites local data: media, accounts, secrets, settings.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APP_DIR"

if [ -z "${TERMUX_VERSION:-}" ] || [ "${PREFIX:-}" != "/data/data/com.termux/files/usr" ]; then
    echo "ERROR: Media Gallery is Termux-only."
    exit 1
fi

PRESERVE=(uploads gallery.db gallery.db-wal gallery.db-shm settings.json .env .admin_pass_hash .secret_key .venv logs models bin app.pid tunnel.pid backups)

echo "--- Media Gallery update (Termux-only) ---"
echo "Directory: $APP_DIR"
echo "Application code will be updated; media, accounts, settings and secrets are preserved."

was_running=0
if [ -f app.pid ] && kill -0 "$(cat app.pid)" 2>/dev/null; then
    was_running=1
    bash "$SCRIPT_DIR/manage.sh" stop || true
fi

update_from_git() {
    command -v git >/dev/null 2>&1 || return 1
    [ -d .git ] || return 1
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    git fetch --prune origin
    local branch target
    branch="$(git rev-parse --abbrev-ref HEAD)"
    target="origin/main"
    git show-ref --verify --quiet "refs/remotes/origin/$branch" && target="origin/$branch"
    if ! git merge-base --is-ancestor HEAD "$target" 2>/dev/null; then
        echo "Cannot fast-forward to $target. Local commits were not rewritten."
        return 1
    fi
    git merge --ff-only "$target"
}

update_from_zip() {
    local zip_path="${1:-}"
    [ -f "$zip_path" ] || return 1
    command -v unzip >/dev/null 2>&1 || { echo "unzip is required for zip updates (pkg install unzip)."; return 1; }
    local tmp src rel skip p
    tmp="$(mktemp -d "$APP_DIR/.update-unpack.XXXXXX")"
    unzip -q "$zip_path" -d "$tmp"
    src="$tmp"
    local -a tops=()
    while IFS= read -r -d '' d; do tops+=("$d"); done < <(find "$tmp" -mindepth 1 -maxdepth 1 -print0)
    if [ "${#tops[@]}" -eq 1 ] && [ -d "${tops[0]}" ]; then src="${tops[0]}"; fi
    if command -v rsync >/dev/null 2>&1; then
        local -a args=()
        for p in "${PRESERVE[@]}"; do args+=(--exclude="$p" --exclude="$p/*"); done
        rsync -a "${args[@]}" "$src"/ "$APP_DIR"/
    else
        (cd "$src" && find . -type f -print0) | while IFS= read -r -d '' rel; do
            rel="${rel#./}"; skip=0
            for p in "${PRESERVE[@]}"; do case "$rel" in "$p"|"$p"/*) skip=1; break;; esac; done
            [ "$skip" -eq 1 ] && continue
            mkdir -p "$APP_DIR/$(dirname "$rel")"; cp -f "$src/$rel" "$APP_DIR/$rel"
        done
    fi
    rm -rf "$tmp"
}

refreshed=0
if [ "${1:-}" = "--from-zip" ] && [ -n "${2:-}" ]; then update_from_zip "$2" && refreshed=1
elif update_from_git; then refreshed=1
elif [ -n "${1:-}" ] && [ -f "$1" ]; then update_from_zip "$1" && refreshed=1
else echo "No source update was applied."; exit 1; fi

# Re-run the Termux-only installer dependency/bootstrap path. It preserves
# application data and recreates only the Python environment when required.
if [ -f install.sh ]; then
    echo
    echo "Refreshing native Termux dependencies..."
    bash install.sh || { echo "Dependency refresh failed; application data was preserved."; exit 1; }
fi

if [ "$was_running" -eq 1 ]; then
    echo "Restarting the gallery..."
    bash "$SCRIPT_DIR/manage.sh" start || true
fi

echo "Update finished. Media, accounts, settings and secrets were preserved."
exit 0
