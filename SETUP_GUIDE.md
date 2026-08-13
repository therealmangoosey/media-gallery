# 🛡️ Media Gallery: Termux Setup Guide

This guide ensures a private-by-design image gallery hosted from your phone.

## 1. Cloudflare Preparation (Critical for IP Protection)
To keep your home IP address **100% hidden**, we use Cloudflare Tunnels.

1.  **Domain**: Add your domain to Cloudflare.
2.  **Zero Trust**: Go to the Cloudflare Dashboard -> Zero Trust.
3.  **Networks -> Tunnels**:
    *   Click **Create a Tunnel**.
    *   Choose **Cloudflared**.
    *   Name it (e.g., `phone-gallery`).
    *   **Save Tunnel**.
    *   Copy the **Tunnel Token** (the long string of characters).
4.  **Public Hostname**:
    *   Under the Tunnel settings, add a **Public Hostname**.
    *   Subdomain: `gallery` (or leave blank for root).
    *   Domain: `yourdomain.com`.
    *   Service Type: `HTTP`.
    *   URL: `localhost:8000`.

## 2. Termux Installation
On your Android phone, open Termux and run:

```bash
git clone https://github.com/therealmangoosey/media-gallery
cd media-gallery
bash install.sh
```

The installer will:
*   Set up a Debian environment (for high-performance ML).
*   Install security dependencies (Argon2, GPG).
*   Prompt for your **Tunnel Token** and **Admin Password**.
*   **Verify** that the server is locked down to `127.0.0.1`.

> **Troubleshooting — mirror errors:** If you see `File has unexpected size` or a
> checksum mismatch while packages install, the Termux mirror is still syncing
> (not a problem on your end). The installer retries automatically. If it still
> fails, switch mirrors with `termux-change-repo`, pick a different one, then
> run `bash install.sh` again.

## 3. Configuration
After installation, customize the gallery by editing **`settings.json`** in the
repo root (it is created for you; `settings.example.json` documents every
option). Set your site name, tagline, description, colors, upload limits, and
moderation thresholds, then restart the app. See the **Configuration** table in
`README.md` for the full list.

## 4. Running the Gallery
*   **Menu (recommended)**: `bash scripts/menu.sh` — an interactive menu with a banner and numbered options for starting, stopping, backing up, editing settings, and more.
*   **Start**: `bash scripts/manage.sh start`
*   **Stop**: `bash scripts/manage.sh stop`
*   **Status**: `bash scripts/manage.sh status`
*   **Logs**: `bash scripts/manage.sh logs`

## 5. Privacy Verification
Once started, run:
```bash
bash scripts/test_security.sh
```
If it says **[PASS]**, your phone's IP address is not being leaked. Visitors only see Cloudflare's IP.

## 6. Adding the Moderation Model
The gallery "fails closed" (quarantines everything) until a model is provided.
1.  Download a `nsfw_mobile_model.tflite`.
2.  Place it in `media-gallery/models/nsfw_model.tflite`.
3.  Restart the app.

## 7. Security Maintenance
*   **Backups**: Run `bash scripts/manage.sh backup`. It will ask for a password and create a GPG-encrypted file.
*   **Updates**: Use `git pull` and rerun `install.sh`.
*   **Emergency**: If you see abuse, use the **Emergency Stop** button in the Admin Dashboard to freeze all uploads.
