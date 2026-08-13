# Security Audit & Threat Model

## Scope

This audit covers the web application, uploads, accounts, voting, storage, console controls, Discord integration, Turnstile integration and Termux launcher.

## High-risk areas addressed

- Uploaded content is treated as untrusted data.
- Image files are decoded with Pillow limits against decompression bombs.
- Images are re-encoded before publication, removing EXIF metadata.
- Audio/video are restricted to recognised common media signatures/extensions and are stored as data, never executed.
- Storage paths cannot escape the application directory.
- Public media is addressed from database UUIDs, not arbitrary filesystem paths.
- Admin/user sessions are signed and logout revokes the current token.
- Passwords use Argon2.
- State-changing forms require CSRF tokens.
- Voting has a database uniqueness constraint in addition to application checks.
- Rate limits bound login, signup, uploads, reports and voting.
- Anonymous voting uses a signed browser identity; accounts provide stronger identity.
- Optional Turnstile provides external bot/human verification.
- Discord webhooks are kept in `.env` and never exposed in the settings display.
- CSP and security headers reduce browser-side attack surface.
- Backup restore rejects unsafe archive paths.
- The application binds to loopback by default.
- Access logs are disabled by the launcher by default.

## Privacy

The gallery does not intentionally scan Android shared photo folders. Only the configured gallery storage directory is used.

Client IPs used for rate limiting/report correlation are keyed-HMAC values rather than stored as raw IP addresses.

## Residual risks

No software can guarantee that an IP address is never observable. The operating system, reverse proxy, Cloudflare, network infrastructure, DNS provider, and hosting platform can still know network information. This application simply avoids displaying or unnecessarily logging the server's bind address.

Anonymous vote cookies can be cleared by a determined attacker. Turnstile and account-required voting should be enabled for higher-risk communities.

Browser media codecs determine which audio/video formats visitors can actually play.

## Recommended production configuration

- Use HTTPS through Cloudflare Tunnel or another trusted reverse proxy.
- Enable Turnstile for sign-up and voting.
- Keep moderation enabled for public user-generated image galleries.
- Keep `fail_closed` enabled.
- Use strong unique admin credentials.
- Keep `.env`, `.secret_key`, `.admin_pass_hash` and `gallery.db` private.
- Run the security test after configuration changes.
- Back up the database and media regularly.
