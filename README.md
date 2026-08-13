# Private Media Gallery for Termux

A private-by-design, self-hosted image gallery optimized for Android/Termux.

## Features
- **Privacy-by-Design**: Uses Cloudflare Tunnels (no open ports) and local ML moderation.
- **Security**: Argon2id, strict security headers, and automatic metadata stripping.
- **Easy Moderation**: Mobile-friendly admin dashboard with blurred thumbnails and quarantine queue.
- **FOSS**: Built with FastAPI, SQLite, and TFLite.

## Installation
1. Install Termux from F-Droid.
2. Run the following command:
   ```bash
   git clone https://github.com/therealmangoosey/media-gallery
   cd media-gallery
   bash install.sh
   ```
3. Follow the interactive prompts for your domain, tunnel token, and admin password.

## Management
- **Start**: `bash scripts/manage.sh start`
- **Stop**: `bash scripts/manage.sh stop`
- **Backup**: `bash scripts/manage.sh backup`
- **Restore**: `bash scripts/manage.sh restore <file.gpg>`

## Requirements
- Android 10+
- Termux (unrooted)
- Cloudflare Domain (Free Tier)
- ARM64 CPU (Recommended)
