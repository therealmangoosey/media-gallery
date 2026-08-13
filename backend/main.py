import os
import uuid
import shutil
import datetime
from fastapi import FastAPI, UploadFile, File, Depends, HTTPException, Request, Form, Response
from fastapi.responses import HTMLResponse, FileResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy.orm import Session
from .database import SessionLocal, engine, Image, Report, AdminAction, init_db, get_db
from .security import hash_password, verify_password, create_session, validate_session, delete_session, SESSION_COOKIE_NAME
from .image_processing import validate_image, process_and_save
from .moderation import ContentModerator

# Directories
STAGING_DIR = "uploads/staging"
PUBLIC_DIR = "uploads/public"
QUARANTINE_DIR = "uploads/quarantine"

app = FastAPI()
moderator = ContentModerator()

# Initialize DB
init_db()

# Admin credentials (set via env or installer)
ADMIN_PASSWORD_HASH = os.getenv("ADMIN_PASSWORD_HASH")

# Thresholds
AUTO_APPROVE_THRESHOLD = 0.2
AUTO_REJECT_THRESHOLD = 0.8

@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Content-Security-Policy"] = "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline';"
    return response

def get_admin_user(request: Request):
    session_id = request.cookies.get(SESSION_COOKIE_NAME)
    if not session_id or not validate_session(session_id):
        raise HTTPException(status_code=401, detail="Not authorized")
    return "admin"

# --- Public Routes ---

@app.get("/", response_class=HTMLResponse)
async def home(request: Request, db: Session = Depends(get_db)):
    images = db.query(Image).filter(Image.status == "approved").order_by(Image.created_at.desc()).all()
    # Simple template rendering
    html = "<h1>Gallery</h1>"
    html += '<a href="/upload">Upload Image</a> | <a href="/admin">Admin</a><br><br>'
    for img in images:
        html += f'<div><img src="/i/{img.uuid}.webp" width="300"><br>'
        html += f'<a href="/report/{img.uuid}">Report</a></div><hr>'
    return html

@app.get("/upload", response_class=HTMLResponse)
async def upload_page():
    return """
    <h1>Upload Image</h1>
    <form action="/upload" method="post" enctype="multipart/form-data">
        <input type="file" name="file" accept="image/jpeg,image/png,image/webp">
        <button type="submit">Upload</button>
    </form>
    """

import time

# Simple rate limiting
UPLOAD_LIMITS = {} # ip -> [timestamps]

def check_rate_limit(ip: str):
    now = time.time()
    if ip not in UPLOAD_LIMITS:
        UPLOAD_LIMITS[ip] = []
    # Keep only last 10 minutes
    UPLOAD_LIMITS[ip] = [t for t in UPLOAD_LIMITS[ip] if now - t < 600]
    if len(UPLOAD_LIMITS[ip]) > 10: # 10 uploads per 10 mins
        return False
    UPLOAD_LIMITS[ip].append(now)
    return True

GLOBAL_CONFIG = {"emergency_stop": False}

@app.post("/upload")
async def upload_image(request: Request, file: UploadFile = File(...), db: Session = Depends(get_db)):
    if GLOBAL_CONFIG["emergency_stop"]:
        raise HTTPException(status_code=503, detail="Uploads are currently disabled by the administrator.")
    
    # Basic IP from headers (behind Cloudflare tunnel, it will be 127.0.0.1 unless configured)
    # But cloudflared --original-client-ip helps.
    ip = request.client.host
    if not check_rate_limit(ip):
        raise HTTPException(status_code=429, detail="Too many uploads. Please wait.")
    
    content = await file.read()
    
    # 1. Validate
    is_valid, format_or_err = validate_image(content)
    if not is_valid:
        raise HTTPException(status_code=400, detail=f"Invalid image: {format_or_err}")
    
    image_uuid = str(uuid.uuid4())
    staging_path = os.path.join(STAGING_DIR, f"{image_uuid}.tmp")
    
    # Save original to staging temporarily
    with open(staging_path, "wb") as f:
        f.write(content)
        
    # 2. Process (Strip metadata, normalize)
    processed_filename = f"{image_uuid}.webp"
    processed_path = os.path.join(STAGING_DIR, processed_filename)
    process_and_save(content, processed_path)
    
    # 3. Moderation
    score, reason = moderator.predict(processed_path)
    
    status = "quarantined"
    if score < AUTO_APPROVE_THRESHOLD:
        status = "approved"
        final_path = os.path.join(PUBLIC_DIR, processed_filename)
        shutil.move(processed_path, final_path)
    elif score > AUTO_REJECT_THRESHOLD:
        status = "rejected"
        # Just don't move it to public, maybe delete later
    else:
        # Quarantine
        final_path = os.path.join(QUARANTINE_DIR, processed_filename)
        shutil.move(processed_path, final_path)
        
    # Save to DB
    new_img = Image(
        uuid=image_uuid,
        original_filename=file.filename,
        extension="webp",
        status=status,
        moderation_score=score,
        moderation_reason=reason
    )
    db.add(new_img)
    db.commit()
    
    # Clean up staging original
    if os.path.exists(staging_path):
        os.remove(staging_path)
    if os.path.exists(processed_path): # if it wasn't moved
        os.remove(processed_path)

    return {"message": "Upload successful", "status": status, "id": image_uuid}

@app.get("/i/{filename}")
async def get_image(filename: str, db: Session = Depends(get_db)):
    uuid_str = filename.split(".")[0]
    img = db.query(Image).filter(Image.uuid == uuid_str).first()
    if not img or img.status != "approved":
        raise HTTPException(status_code=404)
    
    return FileResponse(os.path.join(PUBLIC_DIR, filename))

# --- Report Routes ---
@app.get("/report/{image_uuid}", response_class=HTMLResponse)
async def report_page(image_uuid: str):
    return f"""
    <h1>Report Image</h1>
    <form action="/report/{image_uuid}" method="post">
        <select name="reason">
            <option value="sexual">Sexual Content</option>
            <option value="violence">Violence/Gore</option>
            <option value="hate">Hate Speech</option>
            <option value="illegal">Illegal/CSAM</option>
            <option value="privacy">Privacy</option>
            <option value="other">Other</option>
        </select><br>
        <textarea name="details" placeholder="Details..."></textarea><br>
        <button type="submit">Submit Report</button>
    </form>
    """

@app.post("/report/{image_uuid}")
async def submit_report(image_uuid: str, reason: str = Form(...), details: str = Form(None), db: Session = Depends(get_db)):
    img = db.query(Image).filter(Image.uuid == image_uuid).first()
    if not img:
        raise HTTPException(status_code=404)
    
    report = Report(image_id=img.id, reason=reason, details=details)
    db.add(report)
    img.reports_count += 1
    db.commit()
    return {"message": "Report submitted"}

# --- Admin Routes ---

@app.get("/login", response_class=HTMLResponse)
async def login_page():
    return """
    <form action="/login" method="post">
        <input type="password" name="password">
        <button type="submit">Login</button>
    </form>
    """

@app.post("/login")
async def login(password: str = Form(...)):
    if verify_password(ADMIN_PASSWORD_HASH, password):
        session_id = create_session("admin")
        response = RedirectResponse(url="/admin", status_code=303)
        response.set_cookie(key=SESSION_COOKIE_NAME, value=session_id, httponly=True, samesite="strict")
        return response
    return "Invalid password"

@app.get("/admin", response_class=HTMLResponse)
async def admin_dashboard(db: Session = Depends(get_db), admin = Depends(get_admin_user)):
    quarantined = db.query(Image).filter(Image.status == "quarantined").all()
    reported = db.query(Image).filter(Image.reports_count > 0).all()
    
    html = "<h1>Admin Dashboard</h1>"
    status_text = "DISABLED" if GLOBAL_CONFIG["emergency_stop"] else "ENABLED"
    html += f'<p>Upload Status: <b>{status_text}</b> <a href="/admin/emergency_toggle">Toggle Emergency Stop</a></p>'
    html += "<h2>Quarantine Queue</h2>"
    for img in quarantined:
        html += f'<div>Score: {img.moderation_score}<br>'
        html += f'<img src="/admin/view/{img.uuid}" style="filter: blur(10px);" onclick="this.style.filter=\'none\'" width="200"><br>'
        html += f'<a href="/admin/approve/{img.uuid}">Approve</a> | <a href="/admin/reject/{img.uuid}">Reject</a></div><hr>'
    
    html += "<h2>Reported Images</h2>"
    for img in reported:
        html += f'<div>Reports: {img.reports_count}<br>'
        html += f'<img src="/i/{img.uuid}.webp" width="200"><br>'
        html += f'<a href="/admin/reject/{img.uuid}">Remove</a></div><hr>'
    
    return html

@app.get("/admin/view/{image_uuid}")
async def admin_view_image(image_uuid: str, db: Session = Depends(get_db), admin = Depends(get_admin_user)):
    img = db.query(Image).filter(Image.uuid == image_uuid).first()
    if not img: raise HTTPException(status_code=404)
    
    path = ""
    if img.status == "quarantined": path = os.path.join(QUARANTINE_DIR, f"{img.uuid}.webp")
    elif img.status == "approved": path = os.path.join(PUBLIC_DIR, f"{img.uuid}.webp")
    
    if os.path.exists(path):
        return FileResponse(path)
    raise HTTPException(status_code=404)

@app.get("/admin/approve/{image_uuid}")
async def approve_image(image_uuid: str, db: Session = Depends(get_db), admin = Depends(get_admin_user)):
    img = db.query(Image).filter(Image.uuid == image_uuid).first()
    if img and img.status == "quarantined":
        src = os.path.join(QUARANTINE_DIR, f"{img.uuid}.webp")
        dst = os.path.join(PUBLIC_DIR, f"{img.uuid}.webp")
        if os.path.exists(src):
            shutil.move(src, dst)
        img.status = "approved"
        db.commit()
    return RedirectResponse(url="/admin", status_code=303)

@app.get("/admin/emergency_toggle")
async def emergency_toggle(admin = Depends(get_admin_user)):
    GLOBAL_CONFIG["emergency_stop"] = not GLOBAL_CONFIG["emergency_stop"]
    return RedirectResponse(url="/admin", status_code=303)
