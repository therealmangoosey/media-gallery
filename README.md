# 🖼️ Media Gallery

> A lightweight, privacy-first, self-hosted media gallery built **specifically for Termux on Android**.

**Supported platform: Termux on Android.** This project is intentionally **not** a generic Linux, Windows, macOS, Docker, Raspberry Pi, Debian, or proot application.

[![Platform](https://img.shields.io/badge/platform-Termux%20%2B%20Android-blue)](#requirements) [![Media](https://img.shields.io/badge/media-image%20%7C%20audio%20%7C%20video-purple)](#media-support) [![Security](https://img.shields.io/badge/security-hardened-success)](#security)

## Contents

- [What this is](#what-this-is)
- [What it runs on](#what-it-runs-on)
- [Features](#features)
- [Media support](#media-support)
- [Requirements](#requirements)
- [Installation](#installation)
- [First launch](#first-launch)
- [Connecting from devices](#connecting-from-devices)
- [Cloudflare Tunnel](#cloudflare-tunnel)
- [Control panel](#control-panel)
- [Configuration](#configuration)
- [Power and performance](#power-and-performance)
- [Accounts and voting](#accounts-and-voting)
- [Moderation](#moderation)
- [Discord](#discord)
- [Storage](#storage)
- [Security](#security)
- [Backups](#backups)
- [Updating](#updating)
- [Troubleshooting](#troubleshooting)
- [Termux notes](#termux-notes)

## What this is

Media Gallery turns an Android device running Termux into a small self-hosted media gallery. It can host images, audio and video, with accounts, uploads, search, tags, voting, moderation, Discord notifications and optional Cloudflare Tunnel access.

The application is designed around **native Termux Python and Android networking**. It does not require a Linux container or compatibility layer.

## What it runs on

### ✅ Supported

- Android devices running current Termux
- Termux's native Python environment
- ARM/ARM64 Android devices and other architectures supported by Termux's Python packages
- Local Wi-Fi/LAN access
- Optional Cloudflare Tunnel for remote/public access

### ❌ Not supported

- Windows
- macOS
- ordinary desktop Linux
- Docker/Podman
- WSL
- Debian/proot-distro
- generic VPS/server installations
- running the project outside Termux

If you want a generic Linux server, this repository is deliberately the wrong project.

## Features

- 🖼️ Images with metadata stripping and thumbnails
- 🎵 Audio playback
- 🎬 Video playback
- ⬆️ Upload limits and rate limiting
- 👍 Voting and anti-abuse protections
- 🔎 Search, tags and sorting
- 👤 Optional accounts and sign-up
- 🛡️ Optional image moderation with fail-closed mode
- 💬 Discord webhook notifications
- ☁️ Cloudflare Tunnel support
- 🔐 CSRF protection, secure cookies, password hashing and security headers
- 📁 Isolated gallery storage
- 📱 Termux-friendly low-resource power modes
- ♻️ Automatic native-Termux dependency recovery
- 🧰 Numbered terminal control panel
- 📡 Automatic connection information after startup

## Media support

**Images:** JPEG, PNG and WebP. Images are re-encoded to WebP and metadata is stripped.

**Audio:** MP3, WAV, OGG, FLAC and M4A, subject to browser/device codec support.

**Video:** MP4, WebM, MOV, AVI and other browser-decodable formats.

Uploaded files are treated as data. The application does not execute uploaded media.

## Requirements

You need:

- An Android device
- Current Termux from the official Termux distribution/F-Droid
- Python 3 supplied by Termux
- Git
- curl
- OpenSSL/GPG packages for the supported features
- Free storage for the application, Python packages and your media

For older Android hardware, Eco mode is recommended.

## Installation

### 1. Install Termux

Install a current Termux build. Do not use an obsolete Termux package.

Official project: https://github.com/termux/termux-app

### 2. Clone the project inside Termux

```bash
git clone https://github.com/therealmangoosey/media-gallery.git
cd media-gallery
```

### 3. Run the installer

```bash
bash install.sh
```

The installer:

1. Verifies that it is actually running inside Termux.
2. Installs the required Termux packages.
3. Creates the project's native Python `.venv`.
4. Installs the Python dependencies.
5. Creates the admin password hash.
6. Creates private media directories.
7. Creates a Termux-safe default configuration.
8. Optionally installs the Cloudflare Tunnel binary when your Android CPU is supported.
9. Runs the local security checks.

**No proot, Debian container or other runtime is installed.**

## First launch

Start the control panel:

```bash
bash scripts/menu.sh
```

Choose:

```text
1) Start the gallery
```

On a successful start the terminal prints connection information similar to:

```text
================ Connection Info ================
This device: http://127.0.0.1:8000
Other devices on this Wi-Fi/network: http://192.168.1.42:8000
Cloudflare Tunnel: off
==================================================
```

Your actual IP and port will be shown by the application.

## Connecting from devices

### This Android device

Use the **This device** address printed after startup, normally:

```text
http://127.0.0.1:PORT
```

### Another device on the same Wi-Fi/network

Use the **Other devices on this Wi-Fi/network** address printed after startup:

```text
http://ANDROID-LAN-IP:PORT
```

The other device must be able to reach the Android device on the same network. Some guest Wi-Fi networks intentionally block device-to-device traffic.

### Remote/public access

Use Cloudflare Tunnel instead of forwarding an Android port directly to the internet. When the tunnel is configured, the startup output reports its public URL/status.

## Cloudflare Tunnel

Cloudflare Tunnel is optional. It provides remote access without requiring you to expose an Android port directly through your router.

Configure it from:

**Control panel → Configure Cloudflare Tunnel**

The tunnel token is kept in `.env` with restrictive permissions. The local gallery still handles authentication and authorization.

## Control panel

Run:

```bash
bash scripts/menu.sh
```

The numbered console provides:

| Option | Purpose |
|---|---|
| 1 | Start gallery |
| 2 | Stop gallery |
| 3 | Restart gallery |
| 4 | Status |
| 5 | Logs |
| 6 | Encrypted backup |
| 7 | Restore backup |
| 8 | Full configuration |
| 9 | Discord webhook |
| 10 | Cloudflare Tunnel |
| 11 | Security test |
| 12 | Update application |
| 0 | Exit |

Normal operation should not require manually editing JSON or shell scripts.

## Configuration

The main configuration is `settings.json` and should normally be changed through the control panel.

Important groups include:

- Site/appearance
- Server host and port
- Storage paths
- Upload limits
- Gallery/search/tags/voting
- Moderation
- Accounts
- Turnstile
- Discord
- Security
- Runtime/power mode

### Server address

The default server host is `0.0.0.0` so another device on the same LAN can reach the gallery. The startup screen tells you the exact LAN URL.

If you only want the gallery on the Android device, configure the server host as `127.0.0.1`.

### Port

Choose any available unprivileged port from 1024–65535. For example:

```text
8000
49152
8080
```

After changing it, restart the gallery.

## Power and performance

### Eco

Best for older Android devices. Uses smaller pages and conservative limits.

### Balanced

Recommended default. Normal gallery features and reasonable resource use.

### Full

For stronger Android devices. Allows larger workloads and optional features at higher CPU/RAM cost.

Android can still suspend or kill background Termux processes. No application can guarantee that Android will keep a background process alive forever.

## Accounts and voting

Accounts and sign-up are independently configurable. Existing accounts are not deleted when sign-up is disabled.

Voting uses account/browser identity protections, database uniqueness and rate limiting. Anonymous voting is inherently harder to protect than authenticated voting, so enable accounts and Turnstile for higher-trust communities.

## Moderation

Optional image moderation can approve, quarantine or reject images. With fail-closed enabled, moderation failures quarantine content rather than automatically publishing it.

Audio/video are not sent through the image moderation model.

On older devices, disable moderation or use a lightweight compatible model if performance is poor.

## Discord

Configure a Discord webhook from the control panel. The webhook URL is stored as a secret and is not printed by the normal settings display.

## Storage

The gallery only uses its own storage directories:

```text
uploads/
├── public/
├── quarantine/
└── staging/
```

It does not automatically scan Android's shared photo/download directories or other applications' data.

Path traversal and unsafe storage paths are rejected.

## Security

The project includes:

- Restricted private media directories
- Password hashing with Argon2
- Signed sessions
- Secure/HttpOnly/SameSite cookies
- CSRF protection
- Rate limiting
- Upload size limits
- Image decompression-bomb protection
- Image re-encoding and metadata stripping
- Path traversal protections
- Security headers
- Optional Turnstile
- Fail-closed moderation
- Safe backup path validation
- Secret/config file permissions
- Cloudflare Tunnel support

Run:

```bash
bash scripts/test_security.sh
```

A warning is not automatically a failure. Read each warning and correct it when it represents a configuration you actually need.

## Backups

Backups contain gallery data only. They do not sweep the Android device.

Use:

```bash
bash scripts/menu.sh
```

then choose **6 — Create encrypted backup**.

## Updating

For a Git checkout:

```bash
cd ~/media-gallery
git pull --ff-only origin main
```

Then restart the gallery.

You can also use **Update application** from the control panel.

Do not delete `uploads/`, `gallery.db`, `.env`, `.admin_pass_hash`, `.secret_key` or `settings.json` when updating.

## Troubleshooting

### Start fails

Run:

```bash
bash scripts/menu.sh
```

Choose **5 — View logs**.

The startup process performs a native Termux Python preflight before launching Uvicorn. Missing Python dependencies are automatically repaired from `requirements.txt` where possible.

### Do not install proot to fix a startup error

This project is intentionally Termux-only. If native Python fails, the correct recovery path is to repair the Termux environment:

```bash
bash install.sh
```

If you need to preserve an existing deployment, back up your data first and use the application's update/recovery procedures rather than installing another runtime.

### Other devices cannot connect

Check:

1. Both devices are on the same Wi-Fi/network.
2. The URL printed under **Other devices on this Wi-Fi/network** is correct.
3. The network does not use client isolation/guest isolation.
4. The Android device is not asleep or killing Termux.
5. The configured port is available.

### Cloudflare does not connect

Check the tunnel token, `bin/cloudflared`, the Cloudflare hostname and the tunnel log at `logs/tunnel.log`.

### Uploads fail

Check the configured maximum upload size, allowed media types, storage permissions and moderation settings.

## Termux notes

- Keep the repository inside Termux's private home directory.
- Do not put the application in `/sdcard` as its primary runtime directory.
- Use `termux-setup-storage` only when you intentionally need shared-storage access.
- Keep Termux exempt from Android battery optimization if the server needs to remain available.
- Use a sensible page size on older devices.
- Avoid huge simultaneous video uploads.
- Keep regular encrypted backups.

## Project policy

This repository is intentionally maintained as a **Termux-on-Android project**. Cross-platform compatibility is not a goal. Keeping the runtime narrow lets the startup, networking, dependency and recovery code target the actual environment it is meant to run in.

## License / deployment notes

This is self-hosting software for user-generated media. Follow applicable laws, hosting/network rules and community rules when deploying it.
