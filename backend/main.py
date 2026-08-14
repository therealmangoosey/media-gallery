import hashlib,hmac,logging,os,shutil,threading,time,uuid,json,urllib.parse,urllib.request
from fastapi import Depends,FastAPI,File,HTTPException,Request,UploadFile
from fastapi.responses import FileResponse,HTMLResponse,JSONResponse,RedirectResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session
from starlette.exceptions import HTTPException as StarletteHTTPException
from .config import BASE_DIR,settings
from .database import Image,Report,User,Vote,SessionLocal,get_db,init_db
from .image_processing import detect_media,validate_image,process_and_save
from .moderation import ContentModerator
from .security import *
from .discord_notify import notify_new_image
from .templates import *
logging.basicConfig(level=logging.WARNING); log=logging.getLogger('media-gallery')

def safe_path(rel,default):
 raw=(rel or default).strip().replace('\\','/')
 if not raw or raw.startswith('/') or '..' in raw.split('/'):raw=default
 base=os.path.abspath(BASE_DIR); p=os.path.abspath(os.path.join(base,raw))
 return p if os.path.commonpath((base,p))==base else os.path.join(base,default)
STORAGE_DIR=safe_path(settings.get('server.storage_directory','uploads'),'uploads')
PUBLIC_DIR=safe_path(os.path.join(settings.get('server.storage_directory','uploads'),settings.get('server.public_path','public')),'uploads/public')
QUARANTINE_DIR=safe_path(os.path.join(settings.get('server.storage_directory','uploads'),settings.get('server.quarantine_path','quarantine')),'uploads/quarantine')
STAGING_DIR=safe_path(os.path.join(settings.get('server.storage_directory','uploads'),settings.get('server.staging_path','staging')),'uploads/staging')
STATIC_DIR=os.path.join(BASE_DIR,'static')
for d in (STORAGE_DIR,PUBLIC_DIR,QUARANTINE_DIR,STAGING_DIR,STATIC_DIR):os.makedirs(d,exist_ok=True)
for d in (STORAGE_DIR,PUBLIC_DIR,QUARANTINE_DIR,STAGING_DIR):
 try:os.chmod(d,0o700)
 except OSError:pass

def load_env():
 p=os.path.join(BASE_DIR,'.env')
 if not os.path.exists(p):return
 try:
  with open(p,encoding='utf-8') as f:
   for line in f:
    line=line.strip()
    if line and not line.startswith('#') and '=' in line:
     k,v=line.split('=',1); k=k.strip(); v=v.strip().strip('"').strip("'")
     if k in {'DISCORD_WEBHOOK_URL','TUNNEL_TOKEN','TURNSTILE_SECRET_KEY','GALLERY_SECRET_KEY'} and k not in os.environ:os.environ[k]=v
 except OSError:pass
load_env(); init_db(); app=FastAPI(title='Media Gallery'); app.mount('/static',StaticFiles(directory=STATIC_DIR),name='static'); moderator=ContentModerator()
ADMIN_PASSWORD_HASH=os.getenv('ADMIN_PASSWORD_HASH')
if not ADMIN_PASSWORD_HASH:
 p=os.path.join(BASE_DIR,'.admin_pass_hash')
 if os.path.exists(p):
  try:
   with open(p,encoding='utf-8') as f: ADMIN_PASSWORD_HASH=f.read().strip()
  except OSError: ADMIN_PASSWORD_HASH=None
MODERATION_ENABLED=settings.get_bool('moderation.enabled',True); MODERATION_FAIL_CLOSED=settings.get_bool('moderation.fail_closed',True)
COOKIE_MAX_AGE=60*60*24*30; _EMERGENCY_STOP=False; _STOP_LOCK=threading.Lock()
class Limiter:
 def __init__(self,max_keys=12000):self.h={};self.lock=threading.Lock();self.max=max_keys
 def allow(self,k,n,w):
  now=time.monotonic()
  with self.lock:
   try:n=max(1,int(n));w=max(1,int(w))
   except (TypeError,ValueError):n,w=10,600
   a=[x for x in self.h.get(k,[]) if now-x<w]; ok=len(a)<n
   if ok:a.append(now)
   self.h[k]=a
   if len(self.h)>self.max:
    for key in list(self.h)[:max(1,len(self.h)-self.max)]:self.h.pop(key,None)
   return ok
upload_limit=Limiter(); report_limit=Limiter(); login_limit=Limiter(); vote_limit=Limiter(); signup_limit=Limiter()

def client_ip(req):
 host=req.client.host if req.client else 'unknown'
 if settings.get_bool('security.trust_proxy_headers',True) and host in ('127.0.0.1','::1','localhost'):
  cf=req.headers.get('CF-Connecting-IP'); x=req.headers.get('X-Forwarded-For'); return (cf or (x.split(',')[0] if x else host)).strip()
 return host

def cookie_secure(req):
 if settings.get_bool('security.cookie_secure',False):return True
 return req.url.scheme=='https'
def ip_key(req):return hmac.new(get_secret_key().encode(),client_ip(req).encode(),hashlib.sha256).hexdigest()

def render_page(req,fn,status=200):
 token=req.cookies.get(CSRF_COOKIE_NAME) or new_csrf_token(); html=fn(token); r=HTMLResponse(html,status_code=status); r.headers['Cache-Control']='no-store'
 if not req.cookies.get(CSRF_COOKIE_NAME):r.set_cookie(CSRF_COOKIE_NAME,token,httponly=True,samesite='strict',secure=cookie_secure(req),max_age=COOKIE_MAX_AGE,path='/')
 return r
def require_csrf(req,t):
 if not csrf_matches(t,req.cookies.get(CSRF_COOKIE_NAME)):raise HTTPException(403,'Invalid or missing CSRF token.')
def admin_required(req):
 sid=req.cookies.get(SESSION_COOKIE_NAME)
 if sid and validate_session(sid) and session_role(sid)=='admin':return True
 raise HTTPException(303 if req.method=='GET' else 401,headers={'Location':'/login'} if req.method=='GET' else None,detail='Not authorized')
def current_user(req,db):
 sid=req.cookies.get(SESSION_COOKIE_NAME)
 if sid and validate_session(sid) and session_role(sid)=='user':
  try:return db.query(User).filter(User.id==int(session_identity(sid)),User.is_active.is_(True)).first()
  except (TypeError,ValueError):return None
 return None

def turnstile_ok(req,token,action):
 if not settings.get_bool('turnstile.enabled',False):return True
 secret=os.getenv('TURNSTILE_SECRET_KEY','')
 if not secret or not token:return False
 try:
  data=urllib.parse.urlencode({'secret':secret,'response':token,'remoteip':client_ip(req)}).encode()
  with urllib.request.urlopen(urllib.request.Request('https://challenges.cloudflare.com/turnstile/v0/siteverify',data=data),timeout=5) as r:return bool(json.load(r).get('success'))
 except Exception:return False

def vote_key(req):
 sid=req.cookies.get(SESSION_COOKIE_NAME)
 if sid and validate_session(sid) and session_role(sid)=='user':return 'u:'+str(session_identity(sid)),None
 v=req.cookies.get(VOTE_COOKIE_NAME)
 if sid and not validate_session(sid):v=None
 if not valid_vote_id(v):v=signed_vote_id()
 return 'v:'+v.split('.',1)[0],v

def allowed_media(file_name,data):return detect_media(data,file_name)

def configured_media_allowed(media):
 raw=settings.get('uploads.allowed_media','image,audio,video')
 allowed={x.strip().lower() for x in str(raw).split(',') if x.strip()}
 return media in allowed

@app.middleware('http')
async def security_headers(req,call_next):
 r=await call_next(req); r.headers['X-Content-Type-Options']='nosniff'; r.headers['Referrer-Policy']='no-referrer'; r.headers['Permissions-Policy']='geolocation=(), microphone=(), camera=()'; r.headers['Cache-Control']=r.headers.get('Cache-Control','no-store')
 if settings.get_bool('security.hide_server_identity',True):
  if 'server' in r.headers: del r.headers['server']
  if 'x-powered-by' in r.headers: del r.headers['x-powered-by']
 if settings.get_bool('security.hsts_enabled',True) and cookie_secure(req):r.headers['Strict-Transport-Security']='max-age=31536000; includeSubDomains'
 if settings.get_bool('security.frame_deny',True):r.headers['X-Frame-Options']='DENY';fa="frame-ancestors 'none'"
 else:fa=''
 script_src="'self' https://challenges.cloudflare.com" if settings.get_bool('turnstile.enabled',False) else "'self'"; r.headers['Content-Security-Policy']=("default-src 'self'; img-src 'self' data:; media-src 'self'; frame-src 'self' https://challenges.cloudflare.com; style-src 'self' 'unsafe-inline'; script-src "+script_src+"; base-uri 'self'; form-action 'self'; "+fa).strip(); return r

@app.get('/health')
async def health():return {'status':'ok'}
@app.get('/',response_class=HTMLResponse)
async def home(req:Request,page:int=1,sort:str='new',q:str='',tag:str='',db:Session=Depends(get_db)):
 sort=sort if sort in ('new','top','hot') else 'new'; page=max(1,page); ps=max(8,min(settings.get_int('gallery.page_size',40),100)); query=db.query(Image).filter(Image.status=='approved')
 if q:query=query.filter((Image.title.ilike(f'%{q[:80]}%'))|(Image.description.ilike(f'%{q[:80]}%'))|(Image.tags.ilike(f'%{q[:80]}%')))
 if tag:query=query.filter(Image.tags.ilike(f'%,{tag[:40]},%'))
 if sort=='top':query=query.order_by((Image.upvotes-Image.downvotes).desc(),Image.created_at.desc())
 elif sort=='hot':query=query.order_by((Image.upvotes+Image.downvotes).desc(),Image.created_at.desc())
 else:query=query.order_by(Image.created_at.desc(),Image.id.desc())
 total=query.count(); pages=max(1,(total+ps-1)//ps); page=min(page,pages); images=query.offset((page-1)*ps).limit(ps).all()
 tags=[]
 if settings.get_bool('gallery.allow_tags',True):
  rows=db.query(Image.tags).filter(Image.status=='approved').limit(5000).all(); s=set()
  for (raw,) in rows:
   for t in (raw or '').split(','):
    if t:s.add(t)
  tags=sorted(s)[:100]
 return render_page(req,lambda csrf:gallery_page(images,page,pages,settings.get_bool('gallery.allow_reports',True),sort,q,tag,tags,settings.get_bool('gallery.allow_voting',True),settings.get_bool('gallery.allow_search',True),csrf))

@app.get('/upload',response_class=HTMLResponse)
async def upload_get(req:Request):
 if not settings.get_bool('uploads.enabled',True):return render_page(req,lambda c:message_page('Uploads disabled','The administrator has disabled uploads.'))
 return render_page(req,lambda c:upload_page(c))

@app.post('/upload')
async def upload(req:Request,file:UploadFile=File(...),db:Session=Depends(get_db)):
 global _EMERGENCY_STOP
 if not settings.get_bool('uploads.enabled',True) or _EMERGENCY_STOP:raise HTTPException(503,'Uploads are currently disabled.')
 form=await req.form(); require_csrf(req,form.get('csrf_token'))
 if not upload_limit.allow('u:'+ip_key(req),settings.get_int('uploads.rate_limit_count',10),settings.get_int('uploads.rate_limit_window_seconds',600)):raise HTTPException(429,'Too many uploads. Please wait.')
 if settings.get_bool('turnstile.enabled',False) and settings.get_bool('turnstile.protect_upload',False) and not turnstile_ok(req,form.get('cf-turnstile-response'),'upload'):raise HTTPException(403,'Verification failed. Please try again.')
 user=current_user(req,db)
 if not user and not settings.get_bool('accounts.allow_anonymous_posts',True):return RedirectResponse('/user-login?next=/upload',303)
 try:maxb=max(1,int(settings.get_float('uploads.max_file_mb',50)*1024*1024))
 except (TypeError,ValueError):maxb=50*1024*1024
 data=await file.read(maxb+1)
 if len(data)>maxb:raise HTTPException(413,'File is too large.')
 if not data:raise HTTPException(400,'Empty file.')
 media,mime,ext=allowed_media(file.filename or '',data)
 if not media or not configured_media_allowed(media):raise HTTPException(400,'This media type is not allowed by the current configuration.')
 title=str(form.get('title') or '').strip()[:120]; desc=str(form.get('description') or '').strip()[:settings.get_int('gallery.max_description',1000)]
 rawtags=str(form.get('tags') or ''); tags=[]
 for t in rawtags.split(','):
  t=' '.join(t.strip().lower().split())
  if t and t not in tags and len(t)<=40:tags.append(t)
  if len(tags)>=settings.get_int('gallery.max_tags',8):break
 uid=str(uuid.uuid4()); tmp=os.path.join(STAGING_DIR,uid+'.tmp'); main_tmp=os.path.join(STAGING_DIR,uid+'.bin'); thumb_tmp=os.path.join(STAGING_DIR,uid+'.thumb.webp')
 try:
  with open(tmp,'wb') as f:f.write(data)
  if media=='image':
   ok,reason=validate_image(data)
   if not ok:raise HTTPException(400,reason)
   process_and_save(data,main_tmp,thumb_tmp); stored_ext='webp'; final_name=uid+'.webp'
  else:
   with open(main_tmp,'wb') as f:f.write(data)
   stored_ext=ext; final_name=uid+'.'+ext
  score=0.0; reason='Moderation disabled'; status='approved'
  if MODERATION_ENABLED and media=='image':
   try:score,reason=moderator.predict(main_tmp)
   except Exception:
    score,reason=0.5,'Moderation error'
   status='quarantined'
   if not MODERATION_FAIL_CLOSED and not moderator.loaded:status='approved';reason='Moderation unavailable; fail-closed disabled'
   elif score<settings.get_float('moderation.auto_approve_threshold',.2):status='approved'
   elif score>settings.get_float('moderation.auto_reject_threshold',.8):status='rejected'
  if status!='rejected':
   d=PUBLIC_DIR if status=='approved' else QUARANTINE_DIR
   shutil.move(main_tmp,os.path.join(d,final_name))
   if media=='image' and os.path.exists(thumb_tmp):shutil.move(thumb_tmp,os.path.join(d,uid+'.thumb.webp'))
  img=Image(uuid=uid,original_filename=(file.filename or 'upload')[:255],extension=stored_ext,media_type=media,mime_type=mime,status=status,moderation_score=score,moderation_reason=reason,title=title,description=desc,tags=','+','.join(tags)+',',user_id=user.id if user else None)
  db.add(img);db.commit()
  if status=='approved' and settings.get_bool('discord.enabled',False) and settings.get_bool('discord.notify_new_photos',True):
   p=os.path.join(PUBLIC_DIR,final_name); thumb=os.path.join(PUBLIC_DIR,uid+'.thumb.webp') if media=='image' else None
   threading.Thread(target=notify_new_image,args=(p,uid,file.filename,thumb),daemon=True).start()
  return JSONResponse({'message':'Upload successful','status':status,'id':uid})
 except HTTPException:db.rollback();raise
 except Exception:
  db.rollback();log.exception('Upload processing failed for %s',uid);raise
 finally:
  for p in (tmp,main_tmp,thumb_tmp):
   try:os.remove(p)
   except OSError:pass

@app.get('/media/{image_uuid}')
async def media(image_uuid:str,db:Session=Depends(get_db)):
 img=db.query(Image).filter(Image.uuid==image_uuid,Image.status=='approved').first()
 if not img:raise HTTPException(404,'Media not found')
 p=os.path.join(PUBLIC_DIR,img.uuid+'.'+img.extension)
 if not os.path.exists(p):raise HTTPException(404,'Media not found')
 r=FileResponse(p,media_type=img.mime_type);r.headers['Cache-Control']='public, max-age=31536000, immutable';return r
@app.get('/i/{filename}')
async def image_compat(filename:str,db:Session=Depends(get_db)):return await media(filename.split('.')[0],db)
@app.get('/t/{filename}')
async def thumb(filename:str,db:Session=Depends(get_db)):
 img=db.query(Image).filter(Image.uuid==filename.split('.')[0],Image.status=='approved').first()
 if not img or img.media_type!='image':raise HTTPException(404,'Thumbnail not found')
 p=os.path.join(PUBLIC_DIR,img.uuid+'.thumb.webp');p=p if os.path.exists(p) else os.path.join(PUBLIC_DIR,img.uuid+'.webp')
 return FileResponse(p,media_type='image/webp')

@app.post('/vote/{image_uuid}')
async def vote(req:Request,image_uuid:str,db:Session=Depends(get_db)):
 if not settings.get_bool('gallery.allow_voting',True):raise HTTPException(404,'Not found')
 form=await req.form();require_csrf(req,form.get('csrf_token'));val=form.get('value');honeypot=form.get('website') or ''
 if honeypot:raise HTTPException(400,'Invalid vote')
 if val not in ('1','-1'):raise HTTPException(400,'Invalid vote')
 if not vote_limit.allow('v:'+ip_key(req),20,600):raise HTTPException(429,'Too many votes. Please slow down.')
 if settings.get_bool('turnstile.enabled',False) and settings.get_bool('turnstile.protect_voting',True) and not turnstile_ok(req,form.get('cf-turnstile-response'),'vote'):raise HTTPException(403,'Verification failed. Please try again.')
 img=db.query(Image).filter(Image.uuid==image_uuid,Image.status=='approved').first()
 if not img:raise HTTPException(404,'Not found')
 key,newcookie=vote_key(req)
 if db.query(Vote).filter(Vote.image_id==img.id,Vote.voter_key==key).first():raise HTTPException(409,'You have already voted on this post.')
 try:
  db.add(Vote(image_id=img.id,voter_key=key,value=int(val)));img.upvotes+=1 if val=='1' else 0;img.downvotes+=1 if val=='-1' else 0;db.commit()
 except IntegrityError:db.rollback();raise HTTPException(409,'You have already voted on this post.')
 r=RedirectResponse('/',303)
 if newcookie:r.set_cookie(VOTE_COOKIE_NAME,newcookie,httponly=True,samesite='lax',secure=cookie_secure(req),max_age=COOKIE_MAX_AGE,path='/')
 return r

@app.get('/report/{image_uuid}',response_class=HTMLResponse)
async def report_get(req:Request,image_uuid:str,db:Session=Depends(get_db)):
 if not settings.get_bool('gallery.allow_reports',True):raise HTTPException(404,'Not found')
 if not db.query(Image).filter(Image.uuid==image_uuid,Image.status=='approved').first():raise HTTPException(404,'Not found')
 return render_page(req,lambda c:report_page(image_uuid,c))
@app.post('/report/{image_uuid}')
async def report(req:Request,image_uuid:str,db:Session=Depends(get_db)):
 if not settings.get_bool('gallery.allow_reports',True):raise HTTPException(404,'Not found')
 form=await req.form();require_csrf(req,form.get('csrf_token'))
 if not report_limit.allow('r:'+ip_key(req),5,600):raise HTTPException(429,'Too many reports.')
 reason=form.get('reason') or '';details=str(form.get('details') or '')[:2000]
 if reason not in {'sexual','violence','hate','illegal','privacy','other'}:raise HTTPException(400,'Invalid report reason.')
 img=db.query(Image).filter(Image.uuid==image_uuid).first()
 if not img:raise HTTPException(404,'Not found')
 db.add(Report(image_id=img.id,reason=reason,details=details,ip_hash=ip_key(req)));img.reports_count+=1;db.commit();return RedirectResponse('/',303)

@app.get('/signup',response_class=HTMLResponse)
async def signup_get(req:Request):
 if not(settings.get_bool('accounts.enabled',True) and settings.get_bool('accounts.signup_enabled',True)):raise HTTPException(404,'Not found')
 return render_page(req,lambda c:signup_page(c,turnstile=settings.get_bool('turnstile.enabled',False) and settings.get_bool('turnstile.protect_signup',True)))
@app.post('/signup')
async def signup(req:Request,db:Session=Depends(get_db)):
 if not(settings.get_bool('accounts.enabled',True) and settings.get_bool('accounts.signup_enabled',True)):raise HTTPException(404,'Not found')
 if not signup_limit.allow('s:'+ip_key(req),5,3600):raise HTTPException(429,'Too many sign-up attempts.')
 form=await req.form();require_csrf(req,form.get('csrf_token'))
 if settings.get_bool('turnstile.enabled',False) and settings.get_bool('turnstile.protect_signup',True) and not turnstile_ok(req,form.get('cf-turnstile-response'),'signup'):return render_page(req,lambda c:signup_page(c,'Verification failed.',True),400)
 u=str(form.get('username') or '').strip().lower();p=str(form.get('password') or '');cp=str(form.get('confirm_password') or '')
 try:u=_validate_username(u);_validate_signup_password(p)
 except ValueError as e:return render_page(req,lambda c:signup_page(c,str(e)),400)
 if p!=cp:return render_page(req,lambda c:signup_page(c,'Passwords do not match.'),400)
 if db.query(User).filter(User.username==u).first():return render_page(req,lambda c:signup_page(c,'That username is already taken.'),409)
 user=User(username=u,password_hash=hash_password(p));db.add(user);db.commit();sid=create_session(str(user.id),'user');r=RedirectResponse('/account',303);r.set_cookie(SESSION_COOKIE_NAME,sid,httponly=True,samesite='strict',secure=cookie_secure(req),max_age=COOKIE_MAX_AGE,path='/');return r

def _validate_username(u):
 import re
 if not re.fullmatch(r'[a-z0-9_]{3,24}',u):raise ValueError('Username must be 3–24 letters, numbers or underscores.')
 return u
def _validate_signup_password(p):
 if not 10<=len(p)<=128:raise ValueError('Password must be 10–128 characters.')
 if len(set(p))<4:raise ValueError('Choose a less repetitive password.')

@app.get('/account',response_class=HTMLResponse)
async def account(req:Request,db:Session=Depends(get_db)):
 u=current_user(req,db)
 if not u:return RedirectResponse('/user-login?next=/account',303)
 return render_page(req,lambda c:user_account_page(u.username,c))
@app.post('/account/logout')
async def account_logout(req:Request):
 f=await req.form();require_csrf(req,f.get('csrf_token'));delete_session(req.cookies.get(SESSION_COOKIE_NAME,''));r=RedirectResponse('/',303);r.delete_cookie(SESSION_COOKIE_NAME,path='/');return r
@app.get('/login',response_class=HTMLResponse)
async def login_get(req:Request):return render_page(req,lambda c:login_page(c))
@app.post('/login')
async def login(req:Request):
 if not login_limit.allow('a:'+ip_key(req),10,600):raise HTTPException(429,'Too many login attempts.')
 f=await req.form();require_csrf(req,f.get('csrf_token'));p=str(f.get('password') or '')
 if not ADMIN_PASSWORD_HASH:raise HTTPException(503,'Admin password is not configured.')
 if not verify_password(ADMIN_PASSWORD_HASH,p):return render_page(req,lambda c:login_page(c,'Invalid password.'),401)
 sid=create_session('admin','admin');r=RedirectResponse('/admin',303);r.set_cookie(SESSION_COOKIE_NAME,sid,httponly=True,samesite='strict',secure=cookie_secure(req),max_age=COOKIE_MAX_AGE,path='/');return r
@app.get('/user-login',response_class=HTMLResponse)
async def user_login_get(req:Request):
 if not settings.get_bool('accounts.enabled',True):raise HTTPException(404,'Not found')
 return render_page(req,lambda c:user_login_page(c))
@app.post('/user-login')
async def user_login(req:Request,db:Session=Depends(get_db)):
 if not settings.get_bool('accounts.enabled',True):raise HTTPException(404,'Not found')
 if not login_limit.allow('u:'+ip_key(req),8,600):raise HTTPException(429,'Too many login attempts.')
 f=await req.form();require_csrf(req,f.get('csrf_token'));u=str(f.get('username') or '').strip().lower();p=str(f.get('password') or '');user=db.query(User).filter(User.username==u,User.is_active.is_(True)).first()
 if not user or not verify_password(user.password_hash,p):return render_page(req,lambda c:user_login_page(c,'Invalid username or password.'),401)
 sid=create_session(str(user.id),'user');r=RedirectResponse('/account',303);r.set_cookie(SESSION_COOKIE_NAME,sid,httponly=True,samesite='strict',secure=cookie_secure(req),max_age=COOKIE_MAX_AGE,path='/');return r
@app.post('/logout')
async def logout(req:Request):
 f=await req.form();require_csrf(req,f.get('csrf_token'));delete_session(req.cookies.get(SESSION_COOKIE_NAME,''));r=RedirectResponse('/',303);r.delete_cookie(SESSION_COOKIE_NAME,path='/');return r

@app.get('/admin',response_class=HTMLResponse)
async def admin(req:Request,db:Session=Depends(get_db)):
 admin_required(req);q=db.query(Image).filter(Image.status=='quarantined').order_by(Image.created_at.desc()).all();r=db.query(Image).filter(Image.status=='approved',Image.reports_count>0).order_by(Image.reports_count.desc()).all();return render_page(req,lambda c:admin_page(q,r,c,_EMERGENCY_STOP,settings.get_bool('moderation.blur_quarantine_thumbnails',True)))
def admin_file(img,thumb=False):
 name=img.uuid+('.thumb.webp' if thumb else '.'+img.extension);d=PUBLIC_DIR if img.status=='approved' else QUARANTINE_DIR;p=os.path.join(d,name);return p if os.path.exists(p) else ''
@app.get('/admin/view/{uid}')
async def admin_view(req:Request,uid:str,db:Session=Depends(get_db)):
 admin_required(req);img=db.query(Image).filter(Image.uuid==uid).first();p=admin_file(img) if img else ''
 if not p:raise HTTPException(404,'Not found')
 return FileResponse(p,media_type=img.mime_type)
@app.get('/admin/thumb/{uid}')
async def admin_thumb(req:Request,uid:str,db:Session=Depends(get_db)):
 admin_required(req);img=db.query(Image).filter(Image.uuid==uid).first();p=admin_file(img,True) if img else ''
 if not p:p=admin_file(img) if img else ''
 if not p:raise HTTPException(404,'Not found')
 return FileResponse(p,media_type='image/webp' if img.media_type=='image' else img.mime_type)
def move_status(img,new,db):
 if new not in ('approved','quarantined'):return
 src=QUARANTINE_DIR if new=='approved' else PUBLIC_DIR;dst=PUBLIC_DIR if new=='approved' else QUARANTINE_DIR
 for name in (img.uuid+'.'+img.extension,img.uuid+'.thumb.webp'):
  s=os.path.join(src,name);d=os.path.join(dst,name)
  if os.path.exists(s):shutil.move(s,d)
 img.status=new;db.commit()
 if new=='approved' and settings.get_bool('discord.enabled',False) and settings.get_bool('discord.notify_new_photos',True):threading.Thread(target=notify_new_image,args=(os.path.join(PUBLIC_DIR,img.uuid+'.'+img.extension),img.uuid,img.original_filename,os.path.join(PUBLIC_DIR,img.uuid+'.thumb.webp') if img.media_type=='image' else None),daemon=True).start()
@app.post('/admin/approve/{uid}')
async def approve(req:Request,uid:str,db:Session=Depends(get_db)):
 admin_required(req);f=await req.form();require_csrf(req,f.get('csrf_token'));img=db.query(Image).filter(Image.uuid==uid).first()
 if img and img.status=='quarantined':move_status(img,'approved',db)
 return RedirectResponse('/admin',303)
@app.post('/admin/reject/{uid}')
async def reject(req:Request,uid:str,db:Session=Depends(get_db)):
 admin_required(req);f=await req.form();require_csrf(req,f.get('csrf_token'));img=db.query(Image).filter(Image.uuid==uid).first()
 if img:
  for d in (PUBLIC_DIR,QUARANTINE_DIR):
   for n in (img.uuid+'.'+img.extension,img.uuid+'.thumb.webp'):
    try:os.remove(os.path.join(d,n))
    except OSError:pass
  img.status='rejected';db.commit()
 return RedirectResponse('/admin',303)
@app.post('/admin/emergency_toggle')
async def emergency(req:Request):
 global _EMERGENCY_STOP
 admin_required(req);f=await req.form();require_csrf(req,f.get('csrf_token'))
 with _STOP_LOCK:_EMERGENCY_STOP=not _EMERGENCY_STOP
 return RedirectResponse('/admin',303)

@app.exception_handler(StarletteHTTPException)
async def http_error(req,exc):
 if 300<=exc.status_code<400 and exc.headers and exc.headers.get('Location'):return RedirectResponse(exc.headers['Location'],exc.status_code)
 if req.method=='GET':return render_page(req,lambda c:message_page(str(exc.status_code),str(exc.detail)),exc.status_code)
 return JSONResponse(status_code=exc.status_code,content={'detail':str(exc.detail)})
@app.exception_handler(Exception)
async def err(req,exc):
 log.exception('Unhandled application error')
 if req.method=='GET':return render_page(req,lambda c:message_page('Something went wrong','The server recovered the request safely. Please try again. It did not expose internal details.'),500)
 return JSONResponse(500,{'detail':'Internal server error. Please retry.'})
