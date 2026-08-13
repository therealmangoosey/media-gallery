import base64,hashlib,hmac,json,os,secrets,time
from argon2 import PasswordHasher
from argon2.exceptions import Argon2Error,InvalidHashError,VerificationError
from .config import BASE_DIR,settings
SESSION_COOKIE_NAME='session_id'; CSRF_COOKIE_NAME='csrf'; VOTE_COOKIE_NAME='vote_id'
_ph=PasswordHasher(); _SECRET_PATH=os.path.join(BASE_DIR,'.secret_key')
def get_secret_key():
 k=os.environ.get('GALLERY_SECRET_KEY')
 if k:return k
 try:
  if os.path.exists(_SECRET_PATH):
   k=open(_SECRET_PATH,encoding='utf-8').read().strip()
   if k:return k
  k=secrets.token_urlsafe(48); open(_SECRET_PATH,'w',encoding='utf-8').write(k+'\n'); os.chmod(_SECRET_PATH,0o600); return k
 except OSError:return k or secrets.token_urlsafe(48)
def hash_password(p): return _ph.hash(p)
def verify_password(h,p):
 try:return bool(h and p and _ph.verify(h,p))
 except (Argon2Error,InvalidHashError,VerificationError,TypeError,ValueError):return False
def _b64(b):return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _unb64(s):return base64.urlsafe_b64decode(s+'='*(-len(s)%4))
def _sign(s):return _b64(hmac.new(get_secret_key().encode(),s.encode(),hashlib.sha256).digest())
def create_session(user_id='admin',role='admin'):
 ttl=settings.get_int('admin.session_hours',24)*3600
 p={'sub':user_id,'role':role,'jti':secrets.token_urlsafe(18),'exp':int(time.time())+ttl}; b=_b64(json.dumps(p,separators=(',',':')).encode()); return b+'.'+_sign(b)
def _parse(t):
 if not t or '.' not in t:return None
 b,s=t.split('.',1)
 if not hmac.compare_digest(s,_sign(b)):return None
 try:p=json.loads(_unb64(b))
 except Exception:return None
 return p if isinstance(p,dict) and int(p.get('exp',0))>=int(time.time()) else None
_REVOKED=set()
def validate_session(t):return bool(t and t not in _REVOKED and _parse(t))
def session_identity(t):
 p=_parse(t); return p.get('sub') if p else None
def session_role(t):
 p=_parse(t); return p.get('role') if p else None
def delete_session(t):
 if t:_REVOKED.add(t)
 if len(_REVOKED)>10000:_REVOKED.clear()
def new_csrf_token():return secrets.token_urlsafe(32)
def csrf_matches(a,b):return bool(a and b and hmac.compare_digest(a,b))
def signed_vote_id():
 raw=secrets.token_urlsafe(24); return raw+'.'+_sign(raw)
def valid_vote_id(v):
 if not v or '.' not in v:return False
 a,b=v.split('.',1); return hmac.compare_digest(b,_sign(a))
