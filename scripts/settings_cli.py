#!/usr/bin/env python3
import json,os,re,tempfile,getpass
from pathlib import Path
APP=Path(__file__).resolve().parents[1]; SETTINGS=APP/'settings.json'; EX=APP/'settings.example.json'; ENV=APP/'.env'

def load():
 try:d=json.loads(EX.read_text(encoding='utf-8'))
 except Exception:d={}
 if not isinstance(d,dict):d={}
 if SETTINGS.exists():
  try:r=json.loads(SETTINGS.read_text(encoding='utf-8'))
  except Exception:r={}
  def m(a,b):
   if not isinstance(a,dict) or not isinstance(b,dict):return
   for k,v in b.items():
    if isinstance(v,dict) and isinstance(a.get(k),dict):m(a[k],v)
    else:a[k]=v
  m(d,r)
 return d

def save(d):
 fd=None;p=None
 try:
  fd,p=tempfile.mkstemp(dir=APP,prefix='settings.',suffix='.tmp')
  with os.fdopen(fd,'w',encoding='utf-8') as f:
   fd=None;json.dump(d,f,indent=2,ensure_ascii=False);f.write('\n');f.flush();os.fsync(f.fileno())
  os.chmod(p,0o600);os.replace(p,SETTINGS);print('Saved. Restart to apply server/runtime changes.');return True
 except (OSError,TypeError,ValueError) as e:
  if fd is not None:
   try:os.close(fd)
   except OSError:pass
  if p:
   try:os.unlink(p)
   except OSError:pass
  print(f'Could not save settings: {e}');return False

def get(d,path,default=None):
 try:
  for k in path.split('.'):d=d[k]
  return d
 except (KeyError,TypeError):return default

def setv(d,path,v):
 n=d;p=path.split('.')
 for k in p[:-1]:
  if not isinstance(n.get(k),dict):n[k]={}
  n=n[k]
 n[p[-1]]=v

def ask(label,current,kind='text',minimum=None,maximum=None):
 while True:
  try:raw=input(f'{label} [{current}]: ').strip()
  except (EOFError,KeyboardInterrupt):print('\nCancelled.');raise
  if raw=='':return current
  if kind=='bool':
   if raw.lower() in ('y','yes','1','true','on'):return True
   if raw.lower() in ('n','no','0','false','off'):return False
  elif kind=='int':
   try:
    x=int(raw)
    if (minimum is None or x>=minimum) and (maximum is None or x<=maximum):return x
   except ValueError:pass
  elif kind=='float':
   try:
    x=float(raw)
    if (minimum is None or x>=minimum) and (maximum is None or x<=maximum):return x
   except ValueError:pass
  else:return raw
  print('Invalid value. Please try again.')

def env_get(k):
 if not ENV.exists():return ''
 try:
  for l in ENV.read_text(encoding='utf-8').splitlines():
   if l.startswith(k+'='):return l.split('=',1)[1].strip().strip("'")
 except OSError:pass
 return ''

def env_set(k,v):
 try:
  lines=[];found=False
  if ENV.exists():
   for l in ENV.read_text(encoding='utf-8').splitlines():
    if l.startswith(k+'=') or l.startswith('# '+k+'='):found=True
    else:lines.append(l)
  if v:lines.append(f"{k}='{v.replace(chr(39),chr(39)+chr(92)+chr(39)+chr(39))}'")
  tmp=ENV.with_suffix(ENV.suffix+'.tmp')
  tmp.write_text('\n'.join(lines)+'\n',encoding='utf-8');os.chmod(tmp,0o600);os.replace(tmp,ENV);return True
 except OSError as e:print(f'Could not save secret: {e}');return False

def group(d,title,fields):
 print('\n'+title)
 for path,label,kind,minimum,maximum in fields:setv(d,path,ask(label,get(d,path),kind,minimum,maximum))

def power(d):
 modes={'eco':{'page_size':20,'max_file_mb':20,'moderation':False,'voting':True,'search':True},'balanced':{'page_size':40,'max_file_mb':50,'moderation':True,'voting':True,'search':True},'full':{'page_size':80,'max_file_mb':100,'moderation':True,'voting':True,'search':True}}
 cur=get(d,'runtime.power_mode','balanced');mode=ask('Power mode (eco/balanced/full)',cur)
 if mode not in modes:return print('Choose eco, balanced or full.')
 setv(d,'runtime.power_mode',mode);x=modes[mode];setv(d,'gallery.page_size',x['page_size']);setv(d,'uploads.max_file_mb',x['max_file_mb']);setv(d,'moderation.enabled',x['moderation']);setv(d,'gallery.allow_voting',x['voting']);setv(d,'gallery.allow_search',x['search']);print('Power profile applied. You can fine-tune settings afterwards.')

def main():
 d=load()
 while True:
  print('\n=== Media Gallery Control Panel ===');print('1) Power mode\n2) Site appearance\n3) Server + storage\n4) Uploads\n5) Gallery / search / voting\n6) Moderation\n7) Accounts\n8) Cloudflare Turnstile\n9) Discord webhook\n10) Security\n11) Runtime / recovery\n12) Show settings\n13) Save\n0) Back')
  try:c=input('Select: ').strip()
  except (EOFError,KeyboardInterrupt):print('\nLeaving control panel.');return
  try:
   if c=='0':return
   if c=='1':power(d)
   elif c=='2':group(d,'Site',[('site.name','Site name','text',None,None),('site.tagline','Tagline','text',None,None),('site.description','Description','text',None,None),('site.emoji','Logo emoji','text',None,None),('site.theme_color','Theme colour','text',None,None),('site.accent_color','Accent colour','text',None,None),('site.footer_text','Footer','text',None,None)])
   elif c=='3':
    group(d,'Server',[('server.port','Local port','int',1024,65535),('server.storage_directory','Storage directory','text',None,None),('server.public_path','Public directory','text',None,None),('server.quarantine_path','Quarantine directory','text',None,None),('server.staging_path','Staging directory','text',None,None)]);print('Storage paths must be simple child directories; traversal is rejected by the server.')
   elif c=='4':group(d,'Uploads',[('uploads.enabled','Uploads enabled','bool',None,None),('uploads.max_file_mb','Max file size MB','int',1,2048),('uploads.rate_limit_count','Uploads per window','int',1,10000),('uploads.rate_limit_window_seconds','Rate window seconds','int',1,86400),('uploads.allowed_media','Allowed media (image,audio,video)','text',None,None)])
   elif c=='5':group(d,'Gallery',[('gallery.page_size','Items per page','int',8,100),('gallery.allow_reports','Reports enabled','bool',None,None),('gallery.allow_voting','Voting enabled','bool',None,None),('gallery.allow_search','Search enabled','bool',None,None),('gallery.allow_tags','Tags enabled','bool',None,None),('gallery.max_description','Max description length','int',0,10000),('gallery.max_tags','Max tags per post','int',0,50)])
   elif c=='6':group(d,'Moderation',[('moderation.enabled','Moderation enabled','bool',None,None),('moderation.fail_closed','Fail closed if moderation breaks','bool',None,None),('moderation.auto_approve_threshold','Auto approve threshold','float',0,1),('moderation.auto_reject_threshold','Auto reject threshold','float',0,1),('moderation.blur_quarantine_thumbnails','Blur quarantine thumbnails','bool',None,None)])
   elif c=='7':group(d,'Accounts',[('accounts.enabled','Login system enabled','bool',None,None),('accounts.signup_enabled','New sign-ups enabled','bool',None,None),('accounts.allow_anonymous_posts','Anonymous uploads enabled','bool',None,None),('admin.session_hours','Admin session hours','int',1,720)])
   elif c=='8':
    setv(d,'turnstile.enabled',ask('Turnstile enabled',get(d,'turnstile.enabled',False),'bool'));setv(d,'turnstile.site_key',ask('Turnstile site key',get(d,'turnstile.site_key','')));setv(d,'turnstile.protect_signup',ask('Protect sign-up',get(d,'turnstile.protect_signup',True),'bool'));setv(d,'turnstile.protect_upload',ask('Protect uploads',get(d,'turnstile.protect_upload',False),'bool'));setv(d,'turnstile.protect_voting',ask('Protect voting',get(d,'turnstile.protect_voting',True),'bool'));secret=getpass.getpass('Turnstile secret (blank keeps current): ');env_set('TURNSTILE_SECRET_KEY',secret) if secret else None
   elif c=='9':
    setv(d,'discord.enabled',ask('Discord enabled',get(d,'discord.enabled',False),'bool'));setv(d,'discord.notify_new_photos',ask('Notify new published media',get(d,'discord.notify_new_photos',True),'bool'));s=getpass.getpass('Webhook URL (blank keeps current): ');env_set('DISCORD_WEBHOOK_URL',s) if s else None
   elif c=='10':group(d,'Security',[('security.cookie_secure','Force secure cookies','bool',None,None),('security.trust_proxy_headers','Trust local proxy headers','bool',None,None),('security.hsts_enabled','HSTS','bool',None,None),('security.frame_deny','Block iframe embedding','bool',None,None),('security.hide_server_identity','Hide server headers','bool',None,None),('security.disable_access_logs','Disable access logs','bool',None,None),('security.max_request_mb','Max request MB','int',1,2048)])
   elif c=='11':group(d,'Runtime',[('runtime.use_proot','Use Debian/proot mode','bool',None,None),('runtime.auto_recover','Auto-recover startup failures','bool',None,None)])
   elif c=='12':print(json.dumps(d,indent=2,ensure_ascii=False));print('Secrets are stored in .env and never displayed.')
   elif c=='13':save(d)
   else:print('Invalid selection.')
  except (EOFError,KeyboardInterrupt):print('\nCancelled. Returning to main control panel.')
  except Exception as e:print(f'Action failed safely: {e}')

if __name__=='__main__':main()
