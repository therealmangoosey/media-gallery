"""HTML templates.

Plain-Python string builders (no template engine dependency). Every page shares
``_layout`` for a consistent, responsive design. All dynamic values are escaped
to prevent XSS.
"""

from html import escape

from .config import settings


def _e(value) -> str:
    return escape("" if value is None else str(value))


def _site() -> dict:
    return {
        "name": settings.get("site.name", "Media Gallery"),
        "tagline": settings.get("site.tagline", ""),
        "description": settings.get("site.description", ""),
        "emoji": settings.get("site.emoji", "🖼️"),
        "theme": settings.get("site.theme_color", "#7c3aed"),
        "accent": settings.get("site.accent_color", "#a78bfa"),
        "footer": settings.get("site.footer_text", ""),
    }


def _layout(title: str, body: str, active: str = "") -> str:
    site = _site()
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="{_e(site['description'])}">
<meta name="theme-color" content="{_e(site['theme'])}">
<title>{_e(title)} · {_e(site['name'])}</title>
<style>
  :root {{
    --theme: {_e(site['theme'])};
    --accent: {_e(site['accent'])};
  }}
</style>
<link rel="stylesheet" href="/static/style.css">
</head>
<body>
<header class="topbar">
  <a class="brand" href="/"><span class="brand-emoji">{_e(site['emoji'])}</span>
    <span class="brand-text"><strong>{_e(site['name'])}</strong>{f'<small>{_e(site["tagline"])}</small>' if site['tagline'] else ''}</span>
  </a>
  <nav class="topnav">
    <a href="/" class="{'active' if active == 'home' else ''}">Gallery</a>
    <a href="/upload" class="{'active' if active == 'upload' else ''}">Upload</a>
    <a href="/admin" class="{'active' if active == 'admin' else ''}">Admin</a>
  </nav>
</header>
<main>
{body}
</main>
<footer class="footer">
  <p>{_e(site['footer'])}</p>
</footer>
</body>
</html>"""


def _empty_state(title: str, text: str, action_href: str = "", action_label: str = "") -> str:
    action = ""
    if action_href:
        action = f'<a class="btn btn-primary" href="{_e(action_href)}">{_e(action_label)}</a>'
    return f"""<div class="empty">
  <h2>{_e(title)}</h2>
  <p>{_e(text)}</p>
  {action}
</div>"""


def gallery_page(images, page: int, total_pages: int, allow_reports: bool = True) -> str:
    if not images:
        body = _empty_state(
            "Nothing here yet",
            "No approved images to show. Be the first to upload one!",
            "/upload",
            "Upload an image",
        )
    else:
        cards = []
        for img in images:
            uuid = _e(img.uuid)
            report_link = (
                f'<a class="report-link" href="/report/{uuid}">Report</a>'
                if allow_reports
                else ""
            )
            cards.append(
                f"""<figure class="card">
  <a class="card-link" href="/i/{uuid}.webp" target="_blank" rel="noopener">
    <img src="/t/{uuid}.webp" alt="image" loading="lazy" decoding="async">
  </a>
  <figcaption class="card-foot">{report_link}</figcaption>
</figure>"""
            )
        grid = f'<div class="masonry">{"".join(cards)}</div>'

        pager = ""
        if total_pages > 1:
            prev_btn = (
                f'<a class="btn" href="/?page={page - 1}">← Newer</a>'
                if page > 1
                else '<span class="btn btn-disabled">← Newer</span>'
            )
            next_btn = (
                f'<a class="btn" href="/?page={page + 1}">Older →</a>'
                if page < total_pages
                else '<span class="btn btn-disabled">Older →</span>'
            )
            pager = (
                f'<div class="pager">{prev_btn}'
                f'<span class="pager-info">Page {page} of {total_pages}</span>'
                f"{next_btn}</div>"
            )
        body = f'<h1 class="page-title">Gallery</h1>{grid}{pager}'

    return _layout("Gallery", body, active="home")


def upload_page(csrf: str, error: str = "", success: str = "", status: str = "") -> str:
    notice = ""
    if error:
        notice = f'<div class="notice notice-error">{_e(error)}</div>'
    elif success:
        status_label = {
            "approved": "approved and is now live",
            "quarantined": "quarantined for review",
            "rejected": "rejected by moderation",
        }.get(status, status)
        notice = f'<div class="notice notice-success">Upload complete — your image was <strong>{_e(status_label)}</strong>.</div>'

    form = f"""
<h1 class="page-title">Upload an image</h1>
{notice}
<div class="panel">
  <form action="/upload" method="post" enctype="multipart/form-data" class="upload-form">
    <input type="hidden" name="csrf_token" value="{_e(csrf)}">
    <label class="dropzone" for="file">
      <span class="dropzone-icon">⬆️</span>
      <span>Choose a JPEG, PNG, or WebP image</span>
      <input type="file" id="file" name="file" accept="image/jpeg,image/png,image/webp" required>
    </label>
    <p class="hint">Images are re-encoded, stripped of metadata, and screened automatically.</p>
    <button type="submit" class="btn btn-primary btn-block">Upload</button>
  </form>
</div>"""
    return _layout("Upload", form, active="upload")


def report_page(image_uuid: str, csrf: str) -> str:
    form = f"""
<h1 class="page-title">Report image</h1>
<div class="panel">
  <form action="/report/{_e(image_uuid)}" method="post">
    <input type="hidden" name="csrf_token" value="{_e(csrf)}">
    <label class="field">
      <span>Reason</span>
      <select name="reason" required>
        <option value="sexual">Sexual content</option>
        <option value="violence">Violence / gore</option>
        <option value="hate">Hate speech</option>
        <option value="illegal">Illegal / CSAM</option>
        <option value="privacy">Privacy violation</option>
        <option value="other">Other</option>
      </select>
    </label>
    <label class="field">
      <span>Details (optional)</span>
      <textarea name="details" rows="3" placeholder="Anything the moderators should know…"></textarea>
    </label>
    <button type="submit" class="btn btn-danger btn-block">Submit report</button>
  </form>
</div>"""
    return _layout("Report", form)


def login_page(csrf: str, error: str = "") -> str:
    notice = f'<div class="notice notice-error">{_e(error)}</div>' if error else ""
    form = f"""
<h1 class="page-title">Admin sign in</h1>
{notice}
<div class="panel panel-narrow">
  <form action="/login" method="post">
    <input type="hidden" name="csrf_token" value="{_e(csrf)}">
    <label class="field">
      <span>Password</span>
      <input type="password" name="password" autocomplete="current-password" required autofocus>
    </label>
    <button type="submit" class="btn btn-primary btn-block">Sign in</button>
  </form>
</div>"""
    return _layout("Admin", form, active="admin")


def _admin_image_block(img, quarantine: bool, blur: bool) -> str:
    uuid = _e(img.uuid)
    score = _e(img.moderation_score if img.moderation_score is not None else "—")
    reason = _e(img.moderation_reason or "")
    blur_class = " thumb-blur" if (quarantine and blur) else ""
    thumb = f'<img class="thumb{blur_class}" src="/admin/thumb/{uuid}" alt="thumbnail" loading="lazy">'
    return f"""
<div class="admin-card">
  {thumb}
  <div class="admin-card-meta">
    <span class="meta-line">Score: <strong>{score}</strong></span>
    {f'<span class="meta-line">Reason: {reason}</span>' if reason else ''}
    <span class="meta-line">Reports: {img.reports_count}</span>
    <div class="admin-actions">
      <form method="post" action="/admin/approve/{uuid}"><button class="btn btn-approve btn-sm" type="submit">Approve</button></form>
      <form method="post" action="/admin/reject/{uuid}"><button class="btn btn-danger btn-sm" type="submit">Reject</button></form>
    </div>
  </div>
</div>"""


def admin_page(quarantined, reported, csrf: str, emergency_stop: bool, blur: bool = True) -> str:
    stop_status = (
        '<span class="badge badge-off">EMERGENCY STOP: ON</span>'
        if emergency_stop
        else '<span class="badge badge-on">Uploads enabled</span>'
    )

    if quarantined:
        q = "".join(_admin_image_block(i, quarantine=True, blur=blur) for i in quarantined)
    else:
        q = _empty_state("Queue clear", "No images waiting for review.")

    if reported:
        r = "".join(_admin_image_block(i, quarantine=False, blur=blur) for i in reported)
    else:
        r = _empty_state("No reports", "No images have been reported.")

    body = f"""
<div class="admin-head">
  <h1 class="page-title">Admin dashboard</h1>
  <div class="admin-status">
    {stop_status}
    <form method="post" action="/admin/emergency_toggle">
      <input type="hidden" name="csrf_token" value="{_e(csrf)}">
      <button class="btn btn-sm" type="submit">{'Re-enable uploads' if emergency_stop else 'Emergency stop'}</button>
    </form>
    <form method="post" action="/logout">
      <input type="hidden" name="csrf_token" value="{_e(csrf)}">
      <button class="btn btn-sm btn-ghost" type="submit">Sign out</button>
    </form>
  </div>
</div>
<section>
  <h2 class="section-title">Quarantine queue <span class="count">{len(quarantined)}</span></h2>
  <div class="admin-grid">{q}</div>
</section>
<section>
  <h2 class="section-title">Reported images <span class="count">{len(reported)}</span></h2>
  <div class="admin-grid">{r}</div>
</section>"""
    return _layout("Admin", body, active="admin")


def message_page(title: str, text: str) -> str:
    body = f'<div class="empty">{_empty_state(title, text)}</div>'
    return _layout(title, body)
