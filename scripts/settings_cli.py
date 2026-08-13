#!/usr/bin/env python3
import json,os,re,tempfile,getpass
from pathlib import Path
APP=Path(__file__).resolve().parents[1]; SETTINGS=APP/'settings.json'; EX=APP/'settings.example.json'; ENV=APP/'.env'
def load():
 d=json.loads(EX.read_text());
 if SETTINGS.exists():
  try:r=json.loads(SETTINGS.read_text());
  except Exception:r={}
  def m(a,b):
   for k,v in b.items():a[k]=m(a[k],v) if isinstance(a.get(k),dict) and isinstance(v,dict) else v
  m(d,r)
 return d
def save(d):
 fd,p=tempfile.mkstemp(dir=APP,prefix='settings.',suffix='.tmp');
 with os.fdopen(fd,'w') as f:json.dump(d,f,indent=2,ensure_ascii=False);f.write('\n');f.flush();os.fsync(f.fileno())
 os.chmod(p,0o600);os.replace(p,SETTINGS)
def get(d,path):
 for k in path.split('.'):d=d[k]
 return d
def setv(d,path,v):
 n=d;p=path.split('.')
 for k in p[:-1]:n=n[k]
 n[p[-1]]=v
def ask(label,current,kind='text'):
 while True:
  raw=input(f'{label} [{current}]: ').strip()
  if raw=='':return current
  if kind=='bool':
   if raw.lower() in ('y','yes','1','true','on'):return True
   if raw.lower() in ('n','no','0','false','off'):return False
  elif kind=='int':
   try:return int(raw)
   except:pass
  elif kind=='float':
   try:
    x=float(raw)
    if 0<=x<=1:return x
   except:pass
  else:return raw
  print('Invalid value.')
def env_get(k):
 if not ENV.exists():return ''
 for l in ENV.read_text().splitlines():
  if l.startswith(k+'='):return l.split('=',1)[1].strip().strip("'")
 return ''
def env_set(k,v):
 lines=[];found=False
 if ENV.exists():
  for l in ENV.read_text().splitlines():
   if l.startswith(k+'=') or l.startswith('# '+k+'='):found=True
   else:lines.append(l)
 if v:lines.append(f"{k}='{v}'")
 ENV.write_text('\n'.join(lines)+'\n');os.chmod(ENV,0o600)
def group(d,title,fields):
 print('\n'+title)
 for path,label,kind in fields:setv(d,path,ask(label,get(d,path),kind))
def power(d):
 modes={'eco':{'page_size':20,'max_file_mb':20,'moderation':False,'voting':True,'search':True},'balanced':{'page_size':40,'max_file_mb':50,'moderation':True,'voting':True,'search':True},'full':{'page_size':80,'max_file_mb':100,'moderation':True,'voting':True,'search':True}}
 cur=get(d,'runtime.power_mode');mode=ask('Power mode (eco/balanced/full)',cur)
 if mode not in modes:return print('Choose eco, balanced or full.')
 setv(d,'runtime.power_mode',mode);x=modes[mode];setv(d,'gallery.page_size',x['page_size']);setv(d,'uploads.max_file_mb',x['max_file_mb']);setv(d,'moderation.enabled',x['moderation']);setv(d,'gallery.allow_voting',x['voting']);setv(d,'gallery.allow_search',x['search']);print('Power profile applied. You can fine-tune settings afterwards.')
def main():
 d=load()
 while 1:
  print('\n=== Media Gallery Control Panel ===');print('1) Power mode\n2) Site appearance\n3) Server + storage\n4) Uploads\n5) Gallery / search / voting\n6) Moderation\n7) Accounts\n8) Cloudflare Turnstile\n9) Discord webhook\n10) Security\n11) Runtime / recovery\n12) Show settings\n13) Save\n0) Back')
  c=input('Select: ').strip()
  if c=='0':return
  if c=='1':power(d)
  elif c=='2':group(d,'Site',[('site.name','Site name','text'),('site.tagline','Tagline','text'),('site.description','Description','text'),('site.emoji','Logo emoji','text'),('site.theme_color','Theme colour','text'),('site.accent_color','Accent colour','text'),('site.footer_text','Footer','text')])
  elif c=='3':
   group(d,'Server',[('server.port','Local port','int'),('server.storage_directory','Storage directory','text'),('server.public_path','Public directory','text'),('server.quarantine_path','Quarantine directory','text'),('server.staging_path','Staging directory','text')]);print('Storage paths must remain simple child directories; the app rejects traversal and never scans Android photo folders.')
  elif c=='4':group(d,'Uploads',[('uploads.enabled','Uploads enabled','bool'),('uploads.max_file_mb','Max file size MB','int'),('uploads.rate_limit_count','Uploads per window','int'),('uploads.rate_limit_window_seconds','Rate window seconds','int')])
  elif c=='5':group(d,'Gallery',[('gallery.page_size','Items per page','int'),('gallery.allow_reports','Reports enabled','bool'),('gallery.allow_voting','Voting enabled','bool'),('gallery.allow_search','Search enabled','bool'),('gallery.allow_tags','Tags enabled','bool'),('gallery.max_description','Max description length','int'),('gallery.max_tags','Max tags per post','int')])
  elif c=='6':group(d,'Moderation',[('moderation.enabled','Moderation enabled','bool'),('moderation.fail_closed','Fail closed if moderation breaks','bool'),('moderation.auto_approve_threshold','Auto approve threshold','float'),('moderation.auto_reject_threshold','Auto reject threshold','float'),('moderation.blur_quarantine_thumbnails','Blur quarantine thumbnails','bool')])
  elif c=='7':group(d,'Accounts',[('accounts.enabled','Login system enabled','bool'),('accounts.signup_enabled','New sign-ups enabled','bool'),('accounts.allow_anonymous_posts','Anonymous uploads enabled','bool'),('admin.session_hours','Admin session hours','int')])
  elif c=='8':
   en=ask('Turnstile enabled',get(d,'turnstile.enabled'),'bool');setv(d,'turnstile.enabled',en);setv(d,'turnstile.site_key',ask('Turnstile site key',get(d,'turnstile.site_key')));setv(d,'turnstile.protect_signup',ask('Protect sign-up',get(d,'turnstile.protect_signup'),'bool'));setv(d,'turnstile.protect_upload',ask('Protect uploads',get(d,'turnstile.protect_upload'),'bool'));setv(d,'turnstile.protect_voting',ask('Protect voting',get(d,'turnstile.protect_voting'),'bool'));secret=getpass.getpass('Turnstile secret (blank keeps current): ');env_set('TURNSTILE_SECRET_KEY',secret) if secret else None
  elif c=='9':
   en=ask('Discord enabled',get(d,'discord.enabled'),'bool');setv(d,'discord.enabled',en);setv(d,'discord.notify_new_photos',ask('Notify new published media',get(d,'discord.notify_new_photos'),'bool'));s=getpass.getpass('Webhook URL (blank keeps current): ');env_set('DISCORD_WEBHOOK_URL',s) if s else None
  elif c=='10':group(d,'Security',[('security.cookie_secure','Force secure cookies','bool'),('security.trust_proxy_headers','Trust local proxy headers','bool'),('security.hsts_enabled','HSTS','bool'),('security.frame_deny','Block iframe embedding','bool'),('security.hide_server_identity','Hide server headers','bool'),('security.disable_access_logs','Disable access logs','bool'),('security.max_request_mb','Max request MB','int')])
  elif c=='11':group(d,'Runtime',[('runtime.use_proot','Use Debian/proot mode','bool'),('runtime.auto_recover','Auto-recover startup failures','bool')])
  elif c=='12':print(json.dumps(d,indent=2,ensure_ascii=False));print('Secrets are stored in .env and never displayed.')
  elif c=='13':save(d);print('Saved. Restart to apply server/runtime changes.')
  else:print('Invalid selection.')
if __name__=='__main__':main()
