from __future__ import annotations
import json,logging,os,urllib.error,urllib.parse,urllib.request
from .config import settings
log=logging.getLogger('media-gallery.discord')
def _url():return os.getenv('DISCORD_WEBHOOK_URL','').strip()
def _valid(url):
 try:p=urllib.parse.urlparse(url)
 except ValueError:return False
 return p.scheme=='https' and (p.hostname or '').lower() in {'discord.com','discordapp.com'} and p.path.startswith('/api/webhooks/')
def enabled():return bool(_url()) and _valid(_url())
def notify_new_image(media_path,image_id,original_filename=None,fallback_path=None):
 if not(settings.get_bool('discord.enabled',False) and settings.get_bool('discord.notify_new_photos',True)):return False
 url=_url()
 if not _valid(url):return False
 try:
  path=media_path
  if os.path.getsize(path)>8*1024*1024 and fallback_path and os.path.exists(fallback_path):path=fallback_path
  with open(path,'rb') as f:data=f.read()
  name=os.path.basename(original_filename or os.path.basename(path));name=''.join(ch for ch in name if ch.isprintable() and ch not in '\r\n\\/"')[:100] or f'{image_id}.bin'
  mime='application/octet-stream'
  ext=os.path.splitext(name)[1].lower(); mime={'.webp':'image/webp','.png':'image/png','.jpg':'image/jpeg','.jpeg':'image/jpeg','.mp3':'audio/mpeg','.wav':'audio/wav','.ogg':'audio/ogg','.flac':'audio/flac','.m4a':'audio/mp4','.mp4':'video/mp4','.webm':'video/webm','.mov':'video/quicktime','.avi':'video/x-msvideo'}.get(ext,mime)
  boundary='----MediaGalleryBoundary9d0f3a';payload=json.dumps({'content':f'📦 New media published: `{image_id}`','allowed_mentions':{'parse':[]}}).encode()
  body=(f'--{boundary}\r\nContent-Disposition: form-data; name="payload_json"\r\nContent-Type: application/json\r\n\r\n'.encode()+payload+b'\r\n'+f'--{boundary}\r\nContent-Disposition: form-data; name="files[0]"; filename="{name}"\r\nContent-Type: {mime}\r\n\r\n'.encode()+data+b'\r\n'+f'--{boundary}--\r\n'.encode())
  req=urllib.request.Request(url,data=body,headers={'Content-Type':f'multipart/form-data; boundary={boundary}','User-Agent':'MediaGallery/1.1'},method='POST')
  with urllib.request.urlopen(req,timeout=12) as r:
   return r.status in (200,204)
 except (OSError,urllib.error.URLError,RuntimeError,ValueError) as e:
  log.warning('Discord notification failed for %s: %s',image_id,e);return False
