# 🖼️ Media Gallery

> Lightweight, privacy-first, self-hosted media sharing for small servers and old Android/Termux devices.

[![Security](https://img.shields.io/badge/security-hardened-success)](#security) [![Termux](https://img.shields.io/badge/Android-Termux-blue)](#termux--android) [![Media](https://img.shields.io/badge/media-image--audio--video-purple)](#media-support)

## Contents

- [Overview](#overview)
- [Features](#features)
- [Media support](#media-support)
- [Requirements](#requirements)
- [Installation](#installation)
- [Updating](#updating)
- [First launch](#first-launch)
- [Console control panel](#console-control-panel)
- [Power modes](#power-modes)
- [Accounts and sign-up](#accounts-and-sign-up)
- [Voting and anti-bot protection](#voting-and-anti-bot-protection)
- [Search and tags](#search-and-tags)
- [Moderation](#moderation)
- [Cloudflare Turnstile](#cloudflare-turnstile)
- [Discord webhook](#discord-webhook)
- [Cloudflare Tunnel](#cloudflare-tunnel)
- [Storage isolation](#storage-isolation)
- [Security](#security)
- [Termux & Android](#termux--android)
- [Automatic recovery](#automatic-recovery)
- [Backups](#backups)
- [Troubleshooting](#troubleshooting)
- [Configuration reference](#configuration-reference)

## Overview

Media Gallery is designed to run locally and expose the gallery through a reverse proxy or Cloudflare Tunnel. The application binds to loopback by default, so it does not intentionally publish the device's LAN IP.

The gallery supports community-style posts, voting, tags, search, moderation, accounts, Discord notifications, and common browser-playable image/audio/video formats while keeping the server lightweight.

## Features

- 🖼️ Images with metadata stripping and thumbnails
- 🎵 Audio playback
- 🎬 Video playback
- ⬆️ Upload rate limiting
- 👍 One vote per post per account/browser identity
- 🛡️ Rate limiting + honeypot + optional Turnstile
- 🔎 Search titles, descriptions and tags
- 🏷️ Existing tag discovery
- 🔥 New / Top / Most Active sorting
- 👤 Optional accounts
- 🚫 Sign-up can be disabled without deleting the login system
- 🤖 Optional content moderation with fail-closed behaviour
- 💬 Discord webhook notifications
- ☁️ Cloudflare Tunnel support
- 🔐 CSRF protection, secure cookies, security headers and password hashing
- 📁 Storage restricted to the gallery's own directory
- 📱 Termux/Android-friendly low-resource modes
- ♻️ Automatic startup recovery
- 🧰 Full console configuration, so normal operation does not require editing files

## Media support

The default upload path accepts common browser-friendly formats.

**Images:** JPEG, PNG, WebP. Images are re-encoded to WebP and stripped of EXIF metadata.

**Audio:** MP3, WAV, OGG, FLAC, M4A.

**Video:** MP4, WebM, MOV, AVI and other formats where the browser/device can decode them.

Media is served with the detected MIME type. The application does not execute uploaded files.

## Requirements

### Recommended for Termux

- Android with Termux from [F-Droid](https://f-droid.org/packages/com.termux/) or the official Termux project
- Python 3
- About 200–500 MB free storage for the application/dependencies
- More free storage for uploaded media

### Old Android devices

Start with **Eco** power mode. Native Termux Python is preferred. Debian/proot is available as a fallback when a dependency cannot run natively.

## Installation

### 1. Install Termux

Use a current Termux build rather than an old Play Store build.

Official project: https://github.com/termux/termux-app

### 2. Give Termux storage access

```bash
termux-setup-storage
```

Media Gallery does **not** automatically scan the shared storage folders. Storage permission is only needed if you intentionally use Termux files for backups or deployment.

### 3. Install basic packages

```bash
pkg update
pkg upgrade
pkg install python git curl openssl gnupg
```

### 4. Extract the project

Put the project somewhere inside Termux, for example:

```bash
mkdir -p ~/media-gallery
cd ~/media-gallery
```

Copy/extract the project there.

### 5. Run the installer

```bash
bash install.sh
```

The installer creates the Python environment, generates the local secret, asks for the admin password, and prepares the private media directories.

### 6. Open the control panel

```bash
bash scripts/menu.sh
```

The first screen is the **interactive CLI control panel**. This is the numbered menu you were thinking of.

## Updating

Do **not** delete the folder and re-download, and do **not** run `install.sh` again. The installer asks for a new admin password and is only for first setup.

From the gallery directory:

```bash
cd ~/media-gallery
bash scripts/update.sh
```

Or from the control panel: **Update application (keeps media & accounts)**.

That command only refreshes application code (and Python packages listed in `requirements.txt`). It **does not** delete or overwrite:

| Kept as-is | Why |
|---|---|
| `uploads/` (public, quarantine, staging) | All user media |
| `gallery.db` | Accounts, posts, votes, tags |
| `settings.json` | Site/console configuration |
| `.env` | Webhook, Turnstile, tunnel secrets |
| `.admin_pass_hash` / `.secret_key` | Admin login and session signing |
| `.venv/` | Existing Python environment |
| `logs/`, `models/`, `bin/` | Local logs, optional model, cloudflared |

It never runs `git clean`, never wipes ignored files, and never resets the admin password.

If you installed from a zip instead of git:

```bash
bash scripts/update.sh --from-zip /path/to/media-gallery.zip
```

The zip is overlaid on top of the existing tree with the same data folders excluded. Restart the gallery after a successful update.

## First launch

From the control panel choose:

1. **Start the gallery**
2. **Open full configuration panel**
3. **Power mode → Eco** if the device is old
4. Configure Cloudflare Tunnel if you want a public URL
5. Configure Discord if you want upload notifications
6. Run the security test

The gallery deliberately does not display the loopback address in its own UI.

## Console control panel

Run:

```bash
bash scripts/menu.sh
```

The menu provides:

| Option | Purpose |
|---|---|
| Start | Start the gallery and recover from common startup failures |
| Stop | Stop the gallery and tunnel |
| Restart | Restart the service |
| Status | Check whether it is healthy without printing an IP address |
| Logs | View recent application logs |
| Backup | Create an encrypted backup |
| Restore | Restore a backup after path validation |
| Configuration | Change all supported settings |
| Discord | Configure webhook |
| Cloudflare Tunnel | Configure tunnel token |
| Security test | Run local security checks |
| Update | Refresh app code without touching media or accounts |

## Power modes

The **Power Mode** tool is designed for old Android hardware.

### Eco

- Smaller gallery pages
- Smaller upload limit
- Moderation disabled by default
- Search/voting retained
- Lowest CPU/RAM use

### Balanced

- Normal gallery size
- Moderation enabled
- Voting/search enabled
- Good default for most devices

### Full

- Larger pages and upload limits
- All optional features enabled
- More RAM/CPU use

You can select a power mode and then manually fine-tune individual features.

## Accounts and sign-up

Accounts are controlled separately from sign-up.

You can have:

- Accounts + sign-up enabled
- Accounts enabled + sign-up disabled
- Accounts disabled
- Anonymous uploads enabled or disabled

Disabling sign-up **does not delete existing users** and does not disable the login system.

## Voting and anti-bot protection

Posts can have Reddit-style:

- Upvotes
- Downvotes
- Net score
- One vote per account/browser identity

Additional protections include:

- Per-IP rate limiting
- Signed anonymous vote identity cookies
- Database uniqueness constraints
- Hidden honeypot fields
- Optional Cloudflare Turnstile
- Duplicate-vote rejection

No anti-bot system can make anonymous voting mathematically impossible to abuse. For higher-trust communities, enable Turnstile and require accounts for sensitive actions.

## Search and tags

The gallery can search:

- Titles
- Descriptions
- Tags

Posts can have multiple tags. Existing tags appear as clickable filters at the top of the gallery.

Sort modes:

- **Most recent**
- **Most upvoted**
- **Most active**

## Moderation

Moderation is optional.

When enabled, image uploads can be:

- Automatically approved
- Quarantined for admin review
- Rejected

If the moderation model fails and **fail closed** is enabled, the image is quarantined instead of being published.

Audio/video are not sent through the image moderation model.

For a small/old Android device, Eco mode or disabled moderation is recommended unless you have a lightweight compatible moderation model.

## Cloudflare Turnstile

Turnstile adds an optional human-verification step.

Configure it from:

**Console → Configuration → Cloudflare Turnstile**

Create a Turnstile widget at:

https://dash.cloudflare.com/

You need:

- Site key
- Secret key

The site key is stored in `settings.json`; the secret key is stored in `.env` with restricted permissions.

You can independently protect:

- Sign-up
- Uploads
- Voting

## Discord webhook

Go to:

**Console → Configure Discord webhook**

Paste the Discord webhook URL. **No channel ID is required.** A Discord webhook already belongs to its channel.

When an approved/newly published media item is available, the server sends a notification to that webhook.

Webhook secrets are stored in `.env` and are never printed by the settings viewer.

## Cloudflare Tunnel

For public hosting, use a Cloudflare Tunnel instead of opening an Android port directly.

Create/manage tunnels here:

https://one.dash.cloudflare.com/

Then configure the token through:

**Console → Configure Cloudflare Tunnel**

The application itself binds to loopback. The tunnel is the public-facing component.

## Storage isolation

The application only reads/writes its configured child directories:

```text
uploads/
├── public/
├── quarantine/
└── staging/
```

It does not scan:

- `/sdcard/DCIM`
- `/sdcard/Pictures`
- `/sdcard/Download`
- Other applications' folders

Path traversal and absolute storage paths are rejected.

This means you can have thousands of unrelated photos on the tablet without them appearing in the gallery.

## Security

Security controls include:

- Loopback-only application binding
- No application access-log output by default
- Server identity header suppression
- Content Security Policy
- `X-Content-Type-Options: nosniff`
- `Referrer-Policy: no-referrer`
- HSTS when HTTPS is detected
- Secure/HttpOnly/SameSite cookies
- CSRF protection
- Argon2 password hashing
- Login/signup/upload/vote/report rate limiting
- Upload size limits
- Image decompression-bomb protection
- Image re-encoding
- EXIF removal
- Private media directories
- Signed sessions
- Session revocation on logout
- Safe backup restore path checks
- Discord URL validation
- Turnstile verification
- Fail-closed moderation option

Run the built-in audit with:

```bash
bash scripts/test_security.sh
```

## Termux & Android

The project is designed to prefer native Termux Python because proot adds overhead.

If native dependencies cannot run, the console can use Debian/proot mode.

For an old Samsung Tab A:

1. Use **Eco** mode.
2. Keep the gallery page size around 20–40.
3. Avoid unnecessary image moderation.
4. Keep video files reasonably sized.
5. Disable features you do not need.
6. Use Cloudflare Tunnel rather than exposing the device directly.
7. Keep Android battery optimization disabled for Termux if you expect the server to stay running.

Android itself may still kill background processes. The application cannot override Android's process-management rules.

## Automatic recovery

The startup manager can recover from common failures.

If the configured local port is unavailable, it tries nearby ports and saves the working port when recovery is enabled.

If the native virtual environment cannot start, it can fall back to another available Python runtime/proot path.

If recovery still fails, the app does not silently pretend it is running. The console reports failure and points you to the local logs.

## Backups

Backups contain only the gallery database, settings and configured gallery storage.

They do **not** sweep the Android device for unrelated files.

Backups can be encrypted with GPG:

```bash
bash scripts/menu.sh
# choose Backup
```

## Troubleshooting

### Gallery will not start

Run:

```bash
bash scripts/menu.sh
```

Choose **Status**, then **Logs**.

Try:

```bash
python3 -m py_compile backend/*.py
bash -n scripts/manage.sh
bash scripts/test_security.sh
```

### Old Android / dependency problems

Switch to:

**Configuration → Runtime → Use Debian/proot mode → Yes**

Then restart.

### Uploads are quarantined

If moderation is enabled, this is expected when the model is unavailable or errors. Either provide a compatible moderation model or disable moderation in the configuration panel.

### Turnstile does not work

Check:

- Site key is correct
- Secret key is correct
- The hostname is registered in the Turnstile dashboard
- Turnstile is enabled in the console

### Discord does not receive notifications

Check the webhook in:

**Configuration → Discord webhook**

Then restart the gallery. The webhook must be a Discord webhook URL and the webhook itself must still exist.

## Configuration reference

All normal configuration is available through the numbered console panel. The important groups are:

- Site / appearance
- Server / storage
- Upload limits
- Gallery/search/tags/voting
- Moderation
- Accounts
- Turnstile
- Discord
- Security
- Runtime/recovery
- Power mode

Manual editing of `settings.json` is intentionally unnecessary for normal use.

## License / project notes

This project is intended for self-hosted/private deployments. Review your local laws, hosting provider rules, and the rules of any community where you publish user-generated content.
