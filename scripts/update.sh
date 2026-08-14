#!/bin/bash
# In-place update of Media Gallery application code.
# Never deletes or overwrites local data: media, accounts, secrets, settings.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APP_DIR"

# Local runtime data — never removed, never overwritten by git/zip extract.
PRESERVE=(
    uploads
    gallery.db
    gallery.db-wal
    gallery.db-shm
    settings.json
    .env
    .admin_pass_hash
    .secret_key
    .venv
    logs
    models
    bin
    app.pid
    tunnel.pid
    backups
)

echo "--- Media Gallery update ---"
echo "Directory: $APP_DIR"
echo
echo "This updates application code only."
echo "It will NOT touch media, accounts, passwords, settings, or secrets:"
for p in "${PRESERVE[@]}"; do
    echo "  keep  $p"
done
echo

was_running=0
if [ -f app.pid ] && kill -0 "$(cat app.pid)" 2>/dev/null; then
    was_running=1
    echo "Stopping the gallery while files are updated..."
    bash "$SCRIPT_DIR/manage.sh" stop || true
fi

update_from_git() {
    command -v git >/dev/null 2>&1 || return 1
    [ -d .git ] || return 1

    # Refuse commands that wipe untracked/ignored data.
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "Updating tracked source from git (ignored data files stay on disk)..."
        git fetch --prune origin
        local branch
        branch="$(git rev-parse --abbrev-ref HEAD)"
        local target="origin/main"
        if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
            target="origin/$branch"
        elif git show-ref --verify --quiet refs/remotes/origin/main; then
            target="origin/main"
        elif git show-ref --verify --quiet refs/remotes/origin/master; then
            target="origin/master"
        fi

        # Fast-forward only: never rewrite local history, never git clean.
        if git merge-base --is-ancestor HEAD "$target" 2>/dev/null; then
            git merge --ff-only "$target"
        else
            echo "Cannot fast-forward to $target."
            echo "Your local commits diverged. Data files are still untouched."
            echo "Resolve with a normal git merge when you are ready, or stay on this revision."
            return 1
        fi
        return 0
    fi
    return 1
}

update_from_zip() {
    local zip_path="${1:-}"
    if [ -z "$zip_path" ]; then
        return 1
    fi
    if [ ! -f "$zip_path" ]; then
        echo "Zip not found: $zip_path"
        return 1
    fi
    command -v unzip >/dev/null 2>&1 || { echo "unzip is required for zip updates (pkg install unzip)."; return 1; }

    echo "Overlaying code from $zip_path (data directories excluded)..."
    local tmp
    tmp="$(mktemp -d "$APP_DIR/.update-unpack.XXXXXX")"
    # shellcheck disable=SC2064
    trap 'rm -rf "$tmp"' RETURN

    unzip -q "$zip_path" -d "$tmp"

    # Zip may contain a single top-level folder.
    local src="$tmp"
    local tops=()
    while IFS= read -r -d '' d; do
        tops+=("$d")
    done < <(find "$tmp" -mindepth 1 -maxdepth 1 -print0)
    if [ "${#tops[@]}" -eq 1 ] && [ -d "${tops[0]}" ]; then
        src="${tops[0]}"
    fi

    # Copy only non-preserved paths. Never --delete.
    local exclude_args=()
    local p
    for p in "${PRESERVE[@]}"; do
        exclude_args+=(--exclude="$p" --exclude="$p/*")
    done

    if command -v rsync >/dev/null 2>&1; then
        rsync -a "${exclude_args[@]}" "$src"/ "$APP_DIR"/
    else
        # Fallback: copy files one by one, skip preserve names.
        (
            cd "$src"
            find . -type f -print0
        ) | while IFS= read -r -d '' rel; do
            rel="${rel#./}"
            skip=0
            for p in "${PRESERVE[@]}"; do
                case "$rel" in
                    "$p"|"$p"/*) skip=1; break ;;
                esac
            done
            [ "$skip" -eq 1 ] && continue
            mkdir -p "$APP_DIR/$(dirname "$rel")"
            cp -f "$src/$rel" "$APP_DIR/$rel"
        done
    fi
    rm -rf "$tmp"
    trap - RETURN
    echo "Zip overlay complete."
}

refreshed=0
if [ "${1:-}" = "--from-zip" ] && [ -n "${2:-}" ]; then
    update_from_zip "$2" && refreshed=1
elif update_from_git; then
    refreshed=1
elif [ -n "${1:-}" ] && [ -f "${1:-}" ]; then
    update_from_zip "$1" && refreshed=1
else
    echo "No git remote update was applied."
    echo "If you installed from a zip, run:"
    echo "  bash scripts/update.sh --from-zip /path/to/media-gallery.zip"
    echo "Your media and accounts were not changed."
fi

if [ -f requirements.txt ]; then
    echo
    echo "Refreshing Python packages (this does not reset the admin password)..."
    USE_PROOT="false"
    if [ -f settings.json ] && command -v python3 >/dev/null 2>&1; then
        USE_PROOT="$(python3 - settings.json <<'PY'
import json,sys
try:
    print(json.load(open(sys.argv[1],encoding="utf-8")).get("runtime",{}).get("use_proot", False))
except Exception:
    print(False)
PY
)"
    fi
    if [ "$USE_PROOT" = "True" ] && command -v proot-distro >/dev/null 2>&1; then
        # /opt/venv only exists inside the Debian proot container, never in
        # Termux itself, so refreshing it means logging back into Debian.
        PROOT_DIR="/root/$(basename "$APP_DIR")"
        proot-distro login debian --bind "$APP_DIR:$PROOT_DIR" -- env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root REPO_DIR="$PROOT_DIR" bash -c '
            [ -f /opt/venv/bin/pip ] || { echo "Python environment missing inside Debian; rerun install.sh" >&2; exit 1; }
            /opt/venv/bin/pip install -r "$REPO_DIR/requirements.txt"
        ' || echo "pip update had errors inside Debian; existing venv and data were left in place."
    elif [ -x .venv/bin/pip ]; then
        .venv/bin/pip install -r requirements.txt || echo "pip update had errors; existing venv and data were left in place."
    else
        echo "No virtualenv found; skipped package refresh."
    fi
fi

echo
echo "Update finished. Media in uploads/, gallery.db (accounts/posts/votes),"
echo "settings.json, .env, and password/secret files were left as they were."

if [ "$was_running" -eq 1 ]; then
    echo "Restarting the gallery..."
    bash "$SCRIPT_DIR/manage.sh" start || true
fi

[ "$refreshed" -eq 1 ]
exit $?
