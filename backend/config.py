import json, os
from copy import deepcopy

BASE_DIR=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SETTINGS_PATH=os.path.join(BASE_DIR,'settings.json')
DEFAULTS={
 'site':{'name':'Media Gallery','tagline':'Fast, self-hosted media sharing','description':'A lightweight self-hosted gallery for images, audio and video.','emoji':'🖼️','theme_color':'#7c3aed','accent_color':'#a78bfa','footer_text':'Self-hosted · Powered by Media Gallery'},
 'server':{'port':8000,'storage_directory':'uploads','public_path':'public','quarantine_path':'quarantine','staging_path':'staging'},
 'uploads':{'enabled':True,'max_file_mb':50,'rate_limit_count':10,'rate_limit_window_seconds':600,'allowed_media':'image,audio,video'},
 'gallery':{'page_size':40,'allow_reports':True,'allow_voting':True,'allow_search':True,'allow_tags':True,'default_sort':'new','max_description':1000,'max_tags':8},
 'moderation':{'enabled':True,'fail_closed':True,'auto_approve_threshold':0.2,'auto_reject_threshold':0.8,'blur_quarantine_thumbnails':True},
 'admin':{'session_hours':24},
 'accounts':{'enabled':True,'signup_enabled':True,'allow_anonymous_posts':True},
 'turnstile':{'enabled':False,'site_key':'','protect_signup':True,'protect_upload':False,'protect_voting':True},
 'discord':{'enabled':False,'notify_new_photos':True},
 'security':{'cookie_secure':False,'trust_proxy_headers':True,'hsts_enabled':True,'frame_deny':True,'hide_server_identity':True,'disable_access_logs':True,'max_request_mb':55},
 'runtime':{'use_proot':False,'power_mode':'balanced','auto_recover':True},
}

def merge(a,b):
 r=deepcopy(a)
 for k,v in b.items(): r[k]=merge(r[k],v) if isinstance(r.get(k),dict) and isinstance(v,dict) else deepcopy(v)
 return r

def load_data():
 data=deepcopy(DEFAULTS); invalid=False
 try:
  if os.path.exists(SETTINGS_PATH):
   with open(SETTINGS_PATH,encoding='utf-8') as f: raw=json.load(f)
   if isinstance(raw,dict): data=merge(data,raw)
   else: invalid=True
  else:
   _write_defaults(data)
 except (OSError,json.JSONDecodeError,TypeError):
  invalid=True
  # Keep the application bootable even if settings.json was partially written
  # or manually corrupted. Do not overwrite the user's file during import.
 data['_invalid']=invalid
 return data

def _write_defaults(data):
 try:
  import tempfile
  fd,tmp=tempfile.mkstemp(dir=BASE_DIR,prefix='settings.',suffix='.tmp')
  with os.fdopen(fd,'w',encoding='utf-8') as f:
   json.dump(data,f,indent=2,ensure_ascii=False); f.write('\n'); f.flush(); os.fsync(f.fileno())
  os.chmod(tmp,0o600); os.replace(tmp,SETTINGS_PATH)
 except OSError:
  try: os.unlink(tmp)
  except Exception: pass

class Settings:
 def __init__(self): self._data=load_data(); self.invalid=self._data.pop('_invalid',False)
 def get(self,key,default=None):
  n=self._data
  for p in key.split('.'):
   if not isinstance(n,dict) or p not in n:return default
   n=n[p]
  return n
 def get_int(self,key,default=0):
  try:return int(self.get(key,default))
  except (TypeError,ValueError):return default
 def get_float(self,key,default=0.0):
  try:return float(self.get(key,default))
  except (TypeError,ValueError):return default
 def get_bool(self,key,default=False):
  v=self.get(key,default)
  return v.strip().lower() in ('1','true','yes','on') if isinstance(v,str) else bool(v)

settings=Settings()
