# Private Media Gallery for Termux

A private-by-design, self-hosted image gallery optimized for Android/Termux.
Fast, mobile-friendly, and easy to configure — no accounts required for
visitors, with a full moderation dashboard for you.

## Features

- **Privacy-by-Design**: Served through Cloudflare Tunnels (no open ports) with
  local ML moderation, so nothing sensitive ever leaves your phone.
- **Security**: Argon2id password hashing, signed admin sessions, CSRF
  protection, rate limiting, strict security headers, and automatic metadata
  stripping (EXIF/GPS removed on every upload).
- **Easy Moderation**: Mobile-friendly admin dashboard with blurred quarantine
  thumbnails, one-tap approve/reject, reporting, and an emergency stop.
- **Fast**: Images are re-encoded to WebP with auto-generated thumbnails,
  lazy-loaded, cached, and paginated.
- **Fully configurable**: Everything user-facing (name, tagline, colors, upload
  limits, moderation thresholds, and more) is set in a single `settings.json`.
- **FOSS**: Built with FastAPI, SQLite, and TFLite.

## Installation

1. Install [Termux](https://f-droid.org/packages/com.termux/) from F-Droid.
2. Run:
   ```bash
   git clone https://github.com/therealmangoosey/media-gallery
   cd media-gallery
   bash install.sh
   ```
3. Follow the prompts for your domain, tunnel token, and admin password.

## Configuration

All user-facing settings live in `settings.json` (created for you on first run,
or copy `settings.example.json` to `settings.json`). Restart the app after
editing.

| Key | Description |
| --- | --- |
| `site.name` | Site title shown in the header and browser tab |
| `site.tagline` | Short subtitle under the title |
| `site.description` | Meta description (SEO / link previews) |
| `site.emoji` | Logo emoji in the header |
| `site.theme_color` / `site.accent_color` | Accent colors (any CSS color) |
| `site.footer_text` | Text in the page footer |
| `uploads.enabled` | `false` disables all uploads |
| `uploads.max_file_mb` | Maximum accepted file size |
| `uploads.rate_limit_count` / `uploads.rate_limit_window_seconds` | Upload rate limit |
| `gallery.page_size` | Images per page |
| `gallery.allow_reports` | `false` hides the report button |
| `moderation.auto_approve_threshold` / `auto_reject_threshold` | NSFW score cutoffs |
| `moderation.blur_quarantine_thumbnails` | Blur thumbnails in the admin queue |
| `admin.session_hours` | How long an admin stays signed in |
| `security.cookie_secure` | Set `true` when serving over HTTPS |

A few values can also be set via environment variables (which override the
file): `GALLERY_SITE_NAME`, `GALLERY_MAX_FILE_MB`, `GALLERY_UPLOADS_ENABLED`,
`GALLERY_AUTO_APPROVE_THRESHOLD`, `GALLERY_AUTO_REJECT_THRESHOLD`,
`GALLERY_COOKIE_SECURE`, and `GALLERY_SECRET_KEY`.

## Management

```bash
bash scripts/menu.sh              # interactive menu (recommended)
bash scripts/manage.sh start      # start the app (+ Cloudflare tunnel)
bash scripts/manage.sh stop       # stop the app
bash scripts/manage.sh restart    # restart
bash scripts/manage.sh status     # is it running?
bash scripts/manage.sh logs       # tail the app log
bash scripts/manage.sh backup     # create a GPG-encrypted backup
bash scripts/manage.sh restore <file.gpg>
```

## The moderation model

The gallery "fails closed" — until a model is provided, every upload is
quarantined for review (never auto-approved).

1. Download an `nsfw_mobile_model.tflite`.
2. Place it at `models/nsfw_model.tflite`.
3. Restart the app.

## Requirements

- Android 10+
- Termux (unrooted)
- Cloudflare Domain (Free Tier)
- ARM64 CPU (Recommended)
