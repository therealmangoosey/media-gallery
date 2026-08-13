import hashlib
import hmac
import logging
import os
import shutil
import threading
import time
import uuid

from fastapi import Depends, FastAPI, File, HTTPException, Request, UploadFile
from fastapi.responses import (
    FileResponse,
    HTMLResponse,
    JSONResponse,
    RedirectResponse,
)
from fastapi.staticfiles import StaticFiles
from sqlalchemy.orm import Session
from starlette.exceptions import HTTPException as StarletteHTTPException

from .config import BASE_DIR, settings
from .database import Image, Report, get_db, init_db
from .image_processing import process_and_save, validate_image
from .moderation import ContentModerator
from .security import (
    CSRF_COOKIE_NAME,
    SESSION_COOKIE_NAME,
    create_session,
    csrf_matches,
    get_secret_key,
    new_csrf_token,
    validate_session,
    verify_password,
)
from .templates import (
    admin_page,
    gallery_page,
    login_page,
    message_page,
    report_page,
    upload_page,
)

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("media-gallery")

# --- Directories (absolute, so they work regardless of the process CWD) ---
STAGING_DIR = os.path.join(BASE_DIR, "uploads", "staging")
PUBLIC_DIR = os.path.join(BASE_DIR, "uploads", "public")
QUARANTINE_DIR = os.path.join(BASE_DIR, "uploads", "quarantine")
STATIC_DIR = os.path.join(BASE_DIR, "static")

for _dir in (STAGING_DIR, PUBLIC_DIR, QUARANTINE_DIR, STATIC_DIR):
    os.makedirs(_dir, exist_ok=True)


def _load_env_file():
    """Load a simple KEY=VALUE .env file without external dependencies."""
    env_path = os.path.join(BASE_DIR, ".env")
    if not os.path.exists(env_path):
        return
    with open(env_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key and key not in os.environ:
                os.environ[key] = value


_load_env_file()

app = FastAPI(title="Media Gallery")
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

moderator = ContentModerator()
init_db()

# --- Admin credentials (env, .env, or the installer's .admin_pass_hash) ---
ADMIN_PASSWORD_HASH = os.getenv("ADMIN_PASSWORD_HASH")
if not ADMIN_PASSWORD_HASH:
    hash_file = os.path.join(BASE_DIR, ".admin_pass_hash")
    if os.path.exists(hash_file):
        with open(hash_file, encoding="utf-8") as f:
            ADMIN_PASSWORD_HASH = f.read().strip() or None

# --- Derived configuration ---
AUTO_APPROVE_THRESHOLD = settings.get_float("moderation.auto_approve_threshold", 0.2)
AUTO_REJECT_THRESHOLD = settings.get_float("moderation.auto_reject_threshold", 0.8)
COOKIE_SECURE = settings.get_bool("security.cookie_secure", False)
COOKIE_MAX_AGE = 60 * 60 * 24 * 30  # 30 days

# Per-process "emergency stop" flag. Kept in memory so it resets on restart
# (a fresh process starts uploads re-enabled, which is the safer default).
_EMERGENCY_STOP = False
_STOP_LOCK = threading.Lock()


# --- Security helpers -------------------------------------------------------

def _hash_client_ip(ip: str) -> str:
    """Keyed HMAC-SHA256 of a client IP, for storing in the reports table.

    Storing raw IP addresses is a privacy leak (and can be brute-forced if
    plain-hashed); a keyed hash keeps the record useful for correlation/rate
    analysis without exposing the address in plaintext.
    """
    return hmac.new(get_secret_key().encode(), ip.encode(), hashlib.sha256).hexdigest()


def client_ip(request: Request) -> str:
    """Resolve the real client IP, honoring proxy headers only from loopback."""
    host = request.client.host if request.client else ""
    trust_proxy = settings.get_bool("security.trust_proxy_headers", True)
    if trust_proxy and host in ("127.0.0.1", "::1", "localhost"):
        cf = request.headers.get("CF-Connecting-IP")
        if cf:
            return cf.strip()
        xff = request.headers.get("X-Forwarded-For")
        if xff:
            return xff.split(",")[0].strip()
    return host or "unknown"


class RateLimiter:
    """Minimal in-memory sliding-window rate limiter with bounded memory."""

    def __init__(self, max_keys: int = 20000):
        self._hits = {}
        self._lock = threading.Lock()
        self._max_keys = max_keys

    def allow(self, key: str, limit: int, window: float) -> bool:
        now = time.monotonic()
        with self._lock:
            times = self._hits.get(key, [])
            times = [t for t in times if now - t < window]
            if len(times) >= limit:
                self._hits[key] = times
                return False
            times.append(now)
            self._hits[key] = times
            if len(self._hits) > self._max_keys:
                self._prune(now)
            return True

    def _prune(self, now: float):
        # Drop keys whose newest hit is stale, then trim arbitrary keys if
        # still oversized (defensive bound on memory growth).
        stale = [k for k, v in self._hits.items() if not v or now - v[-1] > 3600]
        for k in stale:
            self._hits.pop(k, None)
        while len(self._hits) > self._max_keys:
            self._hits.pop(next(iter(self._hits)), None)


upload_limiter = RateLimiter()
report_limiter = RateLimiter()
login_limiter = RateLimiter()


@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Permissions-Policy"] = "geolocation=(), microphone=(), camera=()"
    response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"

    frame_deny = settings.get_bool("security.frame_deny", True)
    if frame_deny:
        response.headers["X-Frame-Options"] = "DENY"
        frame_ancestors = "frame-ancestors 'none'"
    else:
        frame_ancestors = ""
    response.headers["Content-Security-Policy"] = (
        "default-src 'self'; img-src 'self' data:; "
        "style-src 'self' 'unsafe-inline'; "
        "script-src 'self'; base-uri 'self'; form-action 'self'; "
        f"{frame_ancestors}"
    ).rstrip()
    return response


def require_csrf(request: Request, form_token: str | None) -> None:
    if not csrf_matches(form_token, request.cookies.get(CSRF_COOKIE_NAME)):
        raise HTTPException(status_code=403, detail="Invalid or missing CSRF token.")


def render_page(request: Request, content_fn, status_code: int = 200) -> HTMLResponse:
    """Render a page, ensuring a CSRF cookie exists and matches the forms.

    The CSRF cookie is only set when it is missing, so repeated visits don't
    emit duplicate Set-Cookie headers (which also trips some HTTP clients).
    """
    token = request.cookies.get(CSRF_COOKIE_NAME) or new_csrf_token()
    html = content_fn(token)
    response = HTMLResponse(html, status_code=status_code)
    response.headers["Cache-Control"] = "no-store"
    if not request.cookies.get(CSRF_COOKIE_NAME):
        response.set_cookie(
            CSRF_COOKIE_NAME,
            token,
            httponly=True,
            samesite="strict",
            secure=COOKIE_SECURE,
            max_age=COOKIE_MAX_AGE,
            path="/",
        )
    return response


def get_admin_user(request: Request):
    sid = request.cookies.get(SESSION_COOKIE_NAME)
    if sid and validate_session(sid):
        return "admin"
    if request.method == "GET":
        # Redirect unauthenticated visitors to the login page.
        raise HTTPException(status_code=303, headers={"Location": "/login"})
    raise HTTPException(status_code=401, detail="Not authorized")


# --- Static / image serving -------------------------------------------------

def _image_response(path: str, immutable: bool) -> FileResponse:
    response = FileResponse(path)
    if immutable:
        response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
    else:
        response.headers["Cache-Control"] = "private, no-store"
    return response


# --- Public routes ----------------------------------------------------------

@app.get("/", response_class=HTMLResponse)
async def home(request: Request, page: int = 1, db: Session = Depends(get_db)):
    page = max(page, 1)
    page_size = max(settings.get_int("gallery.page_size", 60), 1)

    total = db.query(Image).filter(Image.status == "approved").count()
    total_pages = max((total + page_size - 1) // page_size, 1)
    if page > total_pages:
        page = total_pages

    images = (
        db.query(Image)
        .filter(Image.status == "approved")
        .order_by(Image.created_at.desc(), Image.id.desc())
        .offset((page - 1) * page_size)
        .limit(page_size)
        .all()
    )

    allow_reports = settings.get_bool("gallery.allow_reports", True)
    return render_page(
        request,
        lambda csrf: gallery_page(images, page, total_pages, allow_reports),
    )


@app.get("/upload", response_class=HTMLResponse)
async def upload_page_get(request: Request):
    if not settings.get_bool("uploads.enabled", True):
        return render_page(request, lambda csrf: message_page("Uploads disabled", "Uploads are currently disabled by the administrator."))
    return render_page(request, lambda csrf: upload_page(csrf))


@app.post("/upload")
async def upload_image(request: Request, file: UploadFile = File(...), db: Session = Depends(get_db)):
    if not settings.get_bool("uploads.enabled", True) or _EMERGENCY_STOP:
        raise HTTPException(status_code=503, detail="Uploads are currently disabled by the administrator.")

    require_csrf(request, (await _read_form_csrf(request)))

    ip = client_ip(request)
    limit = settings.get_int("uploads.rate_limit_count", 10)
    window = settings.get_float("uploads.rate_limit_window_seconds", 600)
    if not upload_limiter.allow(ip, limit, window):
        raise HTTPException(status_code=429, detail="Too many uploads. Please wait a few minutes.")

    max_bytes = int(settings.get_float("uploads.max_file_mb", 20) * 1024 * 1024)
    content = await file.read(max_bytes + 1)
    if len(content) > max_bytes:
        raise HTTPException(status_code=413, detail=f"File too large (max {settings.get_float('uploads.max_file_mb', 20):.0f} MB).")
    if not content:
        raise HTTPException(status_code=400, detail="Empty file.")

    is_valid, fmt_or_err = validate_image(content)
    if not is_valid:
        raise HTTPException(status_code=400, detail=f"Invalid image: {fmt_or_err}")

    image_uuid = str(uuid.uuid4())
    staging_tmp = os.path.join(STAGING_DIR, f"{image_uuid}.tmp")
    processed_path = os.path.join(STAGING_DIR, f"{image_uuid}.webp")
    thumb_path = os.path.join(STAGING_DIR, f"{image_uuid}.thumb.webp")

    try:
        with open(staging_tmp, "wb") as f:
            f.write(content)
        process_and_save(content, processed_path, thumb_path)

        try:
            score, reason = moderator.predict(processed_path)
        except Exception:  # noqa: BLE001 — fail closed
            score, reason = 0.5, "Moderation error"

        status = "quarantined"
        final_main = os.path.join(QUARANTINE_DIR, f"{image_uuid}.webp")
        final_thumb = os.path.join(QUARANTINE_DIR, f"{image_uuid}.thumb.webp")
        if score < AUTO_APPROVE_THRESHOLD:
            status = "approved"
            final_main = os.path.join(PUBLIC_DIR, f"{image_uuid}.webp")
            final_thumb = os.path.join(PUBLIC_DIR, f"{image_uuid}.thumb.webp")
        elif score > AUTO_REJECT_THRESHOLD:
            status = "rejected"

        if status != "rejected":
            shutil.move(processed_path, final_main)
            shutil.move(thumb_path, final_thumb)

        new_img = Image(
            uuid=image_uuid,
            original_filename=file.filename,
            extension="webp",
            status=status,
            moderation_score=score,
            moderation_reason=reason,
        )
        db.add(new_img)
        db.commit()
        log.info("Upload %s -> %s (score=%.3f)", image_uuid, status, score)
    finally:
        for p in (staging_tmp, processed_path, thumb_path):
            if os.path.exists(p):
                try:
                    os.remove(p)
                except OSError:
                    pass

    return JSONResponse(
        {"message": "Upload successful", "status": status, "id": image_uuid}
    )


async def _read_form_csrf(request: Request) -> str | None:
    """Read the csrf_token field from a multipart or urlencoded form body."""
    form = await request.form()
    return form.get("csrf_token")


@app.get("/i/{filename}")
async def get_image(filename: str, db: Session = Depends(get_db)):
    uuid_str = filename.split(".")[0]
    img = db.query(Image).filter(Image.uuid == uuid_str).first()
    if not img or img.status != "approved":
        raise HTTPException(status_code=404, detail="Image not found")
    # Build the path from the stored record, never from raw URL input.
    safe_path = os.path.join(PUBLIC_DIR, f"{img.uuid}.{img.extension}")
    if not os.path.exists(safe_path):
        raise HTTPException(status_code=404, detail="Image not found")
    return _image_response(safe_path, immutable=True)


@app.get("/t/{filename}")
async def get_thumbnail(filename: str, db: Session = Depends(get_db)):
    uuid_str = filename.split(".")[0]
    img = db.query(Image).filter(Image.uuid == uuid_str).first()
    if not img or img.status != "approved":
        raise HTTPException(status_code=404, detail="Image not found")
    safe_path = os.path.join(PUBLIC_DIR, f"{img.uuid}.thumb.webp")
    if not os.path.exists(safe_path):
        # Fall back to the full image if a thumbnail is missing.
        safe_path = os.path.join(PUBLIC_DIR, f"{img.uuid}.{img.extension}")
    if not os.path.exists(safe_path):
        raise HTTPException(status_code=404, detail="Image not found")
    return _image_response(safe_path, immutable=True)


# --- Report routes ----------------------------------------------------------

@app.get("/report/{image_uuid}", response_class=HTMLResponse)
async def report_page_get(request: Request, image_uuid: str, db: Session = Depends(get_db)):
    if not settings.get_bool("gallery.allow_reports", True):
        raise HTTPException(status_code=404, detail="Not found")
    img = db.query(Image).filter(Image.uuid == image_uuid, Image.status == "approved").first()
    if not img:
        raise HTTPException(status_code=404, detail="Image not found")
    return render_page(request, lambda csrf: report_page(image_uuid, csrf))


@app.post("/report/{image_uuid}")
async def submit_report(request: Request, image_uuid: str, db: Session = Depends(get_db)):
    if not settings.get_bool("gallery.allow_reports", True):
        raise HTTPException(status_code=404, detail="Not found")

    form = await request.form()
    require_csrf(request, form.get("csrf_token"))

    ip = client_ip(request)
    if not report_limiter.allow(ip, 5, 600):
        raise HTTPException(status_code=429, detail="Too many reports. Please slow down.")

    reason = form.get("reason") or ""
    details = form.get("details") or ""
    if not reason:
        raise HTTPException(status_code=400, detail="A reason is required.")

    img = db.query(Image).filter(Image.uuid == image_uuid).first()
    if not img:
        raise HTTPException(status_code=404, detail="Image not found")

    db.add(
        Report(
            image_id=img.id,
            reason=reason[:200],
            details=(details or "")[:2000] or None,
            ip_hash=_hash_client_ip(ip),
        )
    )
    img.reports_count = (img.reports_count or 0) + 1
    db.commit()
    return JSONResponse({"message": "Report submitted. Thank you."})


# --- Auth routes ------------------------------------------------------------

@app.get("/login", response_class=HTMLResponse)
async def login_page_get(request: Request):
    return render_page(request, lambda csrf: login_page(csrf))


@app.post("/login")
async def login(request: Request):
    ip = client_ip(request)
    if not login_limiter.allow(ip, 20, 600):
        raise HTTPException(status_code=429, detail="Too many login attempts. Please wait.")

    form = await request.form()
    require_csrf(request, form.get("csrf_token"))

    password = form.get("password") or ""
    if not ADMIN_PASSWORD_HASH:
        raise HTTPException(status_code=503, detail="Admin password is not configured. Run install.sh first.")

    if verify_password(ADMIN_PASSWORD_HASH, password):
        session_id = create_session("admin")
        response = RedirectResponse(url="/admin", status_code=303)
        response.set_cookie(
            SESSION_COOKIE_NAME,
            session_id,
            httponly=True,
            samesite="strict",
            secure=COOKIE_SECURE,
            max_age=COOKIE_MAX_AGE,
            path="/",
        )
        return response

    return render_page(request, lambda csrf: login_page(csrf, error="Invalid password."))


@app.post("/logout")
async def logout(request: Request):
    form = await request.form()
    require_csrf(request, form.get("csrf_token"))
    response = RedirectResponse(url="/", status_code=303)
    response.delete_cookie(SESSION_COOKIE_NAME, path="/")
    return response


# --- Admin routes -----------------------------------------------------------

@app.get("/admin", response_class=HTMLResponse)
async def admin_dashboard(request: Request, db: Session = Depends(get_db), _admin=Depends(get_admin_user)):
    quarantined = (
        db.query(Image)
        .filter(Image.status == "quarantined")
        .order_by(Image.created_at.desc())
        .all()
    )
    reported = (
        db.query(Image)
        .filter(Image.status == "approved", Image.reports_count > 0)
        .order_by(Image.reports_count.desc())
        .all()
    )
    blur = settings.get_bool("moderation.blur_quarantine_thumbnails", True)
    return render_page(
        request,
        lambda csrf: admin_page(quarantined, reported, csrf, _EMERGENCY_STOP, blur=blur),
    )


def _locate_admin_file(img: Image, thumb: bool = False) -> str:
    name = f"{img.uuid}.thumb.webp" if thumb else f"{img.uuid}.{img.extension}"
    if img.status == "approved":
        path = os.path.join(PUBLIC_DIR, name)
    elif img.status == "quarantined":
        path = os.path.join(QUARANTINE_DIR, name)
    else:
        path = ""
    return path if (path and os.path.exists(path)) else ""


@app.get("/admin/view/{image_uuid}")
async def admin_view_image(image_uuid: str, db: Session = Depends(get_db), _admin=Depends(get_admin_user)):
    img = db.query(Image).filter(Image.uuid == image_uuid).first()
    if not img:
        raise HTTPException(status_code=404, detail="Not found")
    path = _locate_admin_file(img, thumb=False)
    if not path:
        raise HTTPException(status_code=404, detail="File not found")
    return _image_response(path, immutable=False)


@app.get("/admin/thumb/{image_uuid}")
async def admin_thumb_image(image_uuid: str, db: Session = Depends(get_db), _admin=Depends(get_admin_user)):
    img = db.query(Image).filter(Image.uuid == image_uuid).first()
    if not img:
        raise HTTPException(status_code=404, detail="Not found")
    path = _locate_admin_file(img, thumb=True)
    if not path:
        # Fall back to the full image if a thumbnail is missing.
        path = _locate_admin_file(img, thumb=False)
    if not path:
        raise HTTPException(status_code=404, detail="File not found")
    return _image_response(path, immutable=False)


def _move_status(img: Image, new_status: str, db: Session):
    """Move an image's files between quarantine and public, then update DB."""
    src_name = f"{img.uuid}.webp"
    src_thumb = f"{img.uuid}.thumb.webp"
    if new_status == "approved":
        src_dir, dst_dir = QUARANTINE_DIR, PUBLIC_DIR
    elif new_status == "quarantined":
        src_dir, dst_dir = PUBLIC_DIR, QUARANTINE_DIR
    else:
        return

    for name in (src_name, src_thumb):
        src = os.path.join(src_dir, name)
        if os.path.exists(src):
            dst = os.path.join(dst_dir, name)
            shutil.move(src, dst)
    img.status = new_status
    db.commit()


@app.post("/admin/approve/{image_uuid}")
async def approve_image(request: Request, image_uuid: str, db: Session = Depends(get_db), _admin=Depends(get_admin_user)):
    form = await request.form()
    require_csrf(request, form.get("csrf_token"))
    img = db.query(Image).filter(Image.uuid == image_uuid).first()
    if img and img.status == "quarantined":
        _move_status(img, "approved", db)
        log.info("Approved %s", image_uuid)
    return RedirectResponse(url="/admin", status_code=303)


@app.post("/admin/reject/{image_uuid}")
async def reject_image(request: Request, image_uuid: str, db: Session = Depends(get_db), _admin=Depends(get_admin_user)):
    form = await request.form()
    require_csrf(request, form.get("csrf_token"))
    img = db.query(Image).filter(Image.uuid == image_uuid).first()
    if img:
        # Delete the underlying files from wherever they live.
        for dir_name, thumb in ((PUBLIC_DIR, False), (QUARANTINE_DIR, False), (PUBLIC_DIR, True), (QUARANTINE_DIR, True)):
            name = f"{img.uuid}.thumb.webp" if thumb else f"{img.uuid}.webp"
            path = os.path.join(dir_name, name)
            if os.path.exists(path):
                try:
                    os.remove(path)
                except OSError:
                    pass
        img.status = "rejected"
        db.commit()
        log.info("Rejected %s", image_uuid)
    return RedirectResponse(url="/admin", status_code=303)


@app.post("/admin/emergency_toggle")
async def emergency_toggle(request: Request, _admin=Depends(get_admin_user)):
    global _EMERGENCY_STOP
    form = await request.form()
    require_csrf(request, form.get("csrf_token"))
    with _STOP_LOCK:
        _EMERGENCY_STOP = not _EMERGENCY_STOP
    log.info("Emergency stop set to %s", _EMERGENCY_STOP)
    return RedirectResponse(url="/admin", status_code=303)


# --- Error handling ---------------------------------------------------------

@app.exception_handler(StarletteHTTPException)
async def http_exception_handler(request: Request, exc: StarletteHTTPException):
    if 300 <= exc.status_code < 400 and exc.headers and exc.headers.get("Location"):
        return RedirectResponse(exc.headers["Location"], status_code=exc.status_code)
    if request.method == "GET":
        return render_page(
            request,
            lambda csrf: message_page(f"{exc.status_code}", str(exc.detail)),
            status_code=exc.status_code,
        )
    return JSONResponse(status_code=exc.status_code, content={"detail": str(exc.detail)})


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    log.exception("Unhandled error on %s %s", request.method, request.url.path)
    if request.method == "GET":
        return render_page(request, lambda csrf: message_page("500", "Something went wrong. Please try again."))
    return JSONResponse(status_code=500, content={"detail": "Internal server error."})
