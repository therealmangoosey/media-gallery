#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$APP_DIR/.env"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE" 2>/dev/null || true
set_env() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)" || return 1
  awk -v k="$key" -v v="$value" 'BEGIN{done=0} $0 ~ "^" k "=" {print k "=" v; done=1; next} {print} END{if(!done) print k "=" v}' "$ENV_FILE" > "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$ENV_FILE"
}
echo "Cloudflare Tunnel configuration"
echo ""
if [ -x "$APP_DIR/bin/cloudflared" ]; then echo "cloudflared: installed"; else echo "cloudflared: not installed (install it before starting the tunnel)"; fi
printf 'Cloudflare Tunnel token (leave blank to disable): '
IFS= read -r token || true
if [ -z "$token" ]; then
  sed -i '/^TUNNEL_TOKEN=/d;/^TUNNEL_URL=/d' "$ENV_FILE" 2>/dev/null || true
  echo "Cloudflare Tunnel disabled."
  exit 0
fi
printf 'Public Cloudflare URL/domain (optional, e.g. https://gallery.example.com): '
IFS= read -r url || true
case "$url" in https://*|http://*|'') ;; *) echo "Invalid URL. Use http:// or https://, or leave blank."; exit 1;; esac
set_env TUNNEL_TOKEN "$token" || { echo "Could not save tunnel token."; exit 1; }
if [ -n "$url" ]; then set_env TUNNEL_URL "$url" || exit 1; else sed -i '/^TUNNEL_URL=/d' "$ENV_FILE"; fi
echo "Cloudflare Tunnel settings saved. Restart the gallery to apply them."
