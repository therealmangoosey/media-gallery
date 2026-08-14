# Media Gallery — Termux-only Setup Guide

This guide is for **Termux on Android only**. Do not use Debian/proot-distro, Docker, WSL, desktop Linux, Windows or macOS with this repository.

## 1. Install Termux

Install a current Termux release from the official Termux distribution/F-Droid.

## 2. Install Git

```bash
pkg update
pkg upgrade -y
pkg install git
```

## 3. Get Media Gallery

```bash
git clone https://github.com/therealmangoosey/media-gallery.git
cd media-gallery
```

## 4. Install

```bash
bash install.sh
```

The installer verifies Termux, installs native Termux packages, creates `.venv`, installs Python dependencies, creates the admin password hash and prepares private storage.

## 5. Start

```bash
bash scripts/menu.sh
```

Choose **1 — Start the gallery**.

A successful startup prints:

```text
This device: http://127.0.0.1:PORT
Other devices on this Wi-Fi/network: http://ANDROID-LAN-IP:PORT
Cloudflare Tunnel: off
```

Use the first address on the Android device. Use the second address from another device on the same Wi-Fi.

## 6. Configure

Choose **8 — Open full configuration panel**.

Important settings:

- Server host: `0.0.0.0` for LAN access, `127.0.0.1` for device-only access.
- Server port: any available port from 1024–65535.
- Power mode: Eco/Balanced/Full.
- Upload/media limits.
- Accounts and sign-up.
- Moderation.
- Turnstile.
- Discord.
- Cloudflare Tunnel.

## 7. Cloudflare Tunnel

For remote access, configure the tunnel through option **10**. Do not directly expose the Android port to the public internet unless you understand the networking and security implications.

## 8. Security test

Run option **11**, or:

```bash
bash scripts/test_security.sh
```

Warnings should be reviewed rather than ignored automatically.

## 9. Updating

Use option **12**, or:

```bash
git pull --ff-only origin main
```

Do not delete the database, uploads, secrets or settings when updating.

## 10. Troubleshooting

View logs from option **5**:

```bash
bash scripts/menu.sh
```

If the native Python environment is broken, repair it from Termux with:

```bash
bash install.sh
```

This project intentionally has **no proot/container fallback**. The server uses native Termux networking because Android/proot combinations can produce unsupported socket operations.

If another device cannot connect, confirm that both devices are on the same network and that the Wi-Fi does not isolate clients.
