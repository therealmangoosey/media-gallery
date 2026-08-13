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

## 3. Running the Gallery
*   **Start**: `bash scripts/manage.sh start`
*   **Stop**: `bash scripts/manage.sh stop`
*   **Status**: `bash scripts/manage.sh status`

## 4. Privacy Verification
Once started, run:
```bash
bash scripts/test_security.sh
```
If it says **[PASS]**, your phone's IP address is not being leaked. Visitors only see Cloudflare's IP.

## 5. Adding the Moderation Model
The gallery "fails closed" (quarantines everything) until a model is provided.
1.  Download a `nsfw_mobile_model.tflite`.
2.  Place it in `media-gallery/models/nsfw_model.tflite`.
3.  Restart the app.

## 6. Security Maintenance
*   **Backups**: Run `bash scripts/manage.sh backup`. It will ask for a password and create a GPG-encrypted file.
*   **Updates**: Use `git pull` and rerun `install.sh`.
*   **Emergency**: If you see abuse, use the **Emergency Stop** button in the Admin Dashboard to freeze all uploads.
