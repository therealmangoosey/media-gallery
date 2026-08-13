import io
from PIL import Image as PILImage,ImageOps
ALLOWED_IMAGE={'jpeg':'image/jpeg','png':'image/png','webp':'image/webp'}
MAX_DIMENSION=12000; MAX_PIXELS=40_000_000; THUMBNAIL_MAX=480; QUALITY=82
PILImage.MAX_IMAGE_PIXELS=MAX_PIXELS
def validate_image(data):
 try:
  im=PILImage.open(io.BytesIO(data)); fmt=(im.format or '').lower()
  if fmt not in ALLOWED_IMAGE:return False,'Unsupported image format'
  w,h=im.size
  if w>MAX_DIMENSION or h>MAX_DIMENSION or w*h>MAX_PIXELS:return False,'Image dimensions are too large'
  im.verify(); return True,fmt
 except Exception as e:return False,f'Invalid image data: {e}'
def process_and_save(data,main_path,thumb_path=None):
 im=PILImage.open(io.BytesIO(data)); im=ImageOps.exif_transpose(im)
 if im.mode not in ('RGB','RGBA'): im=im.convert('RGBA' if 'A' in im.getbands() else 'RGB')
 im.save(main_path,'WEBP',quality=QUALITY,method=4)
 if thumb_path:
  t=im.copy(); t.thumbnail((THUMBNAIL_MAX,THUMBNAIL_MAX),PILImage.Resampling.LANCZOS); t.save(thumb_path,'WEBP',quality=78,method=3)
def detect_media(data,filename):
 ext=filename.rsplit('.',1)[-1].lower() if '.' in filename else ''
 if data.startswith(b'\xff\xd8\xff'):return 'image','image/jpeg','jpg'
 if data.startswith(b'\x89PNG\r\n\x1a\n'):return 'image','image/png','png'
 if data.startswith(b'RIFF') and data[8:12]==b'WEBP':return 'image','image/webp','webp'
 if data.startswith(b'ID3') or (len(data)>2 and data[0]==0xff and (data[1]&0xe0)==0xe0):return 'audio','audio/mpeg',ext or 'mp3'
 if data.startswith(b'RIFF') and data[8:12]==b'WAVE':return 'audio','audio/wav','wav'
 if data.startswith(b'OggS'):return 'audio','audio/ogg','ogg'
 if data.startswith(b'fLaC'):return 'audio','audio/flac','flac'
 if len(data)>12 and data[4:8]==b'ftyp':
  brand=data[8:12]
  if brand in (b'M4A ',b'M4B '):return 'audio','audio/mp4','m4a'
  return 'video','video/mp4','mp4'
 if data.startswith(b'\x1aE\xdf\xa3'):return 'video','video/webm','webm'
 if data.startswith(b'RIFF') and data[8:12]==b'AVI ':return 'video','video/x-msvideo','avi'
 if ext in ('m4a','mp3','wav','ogg','flac'):return 'audio',{'m4a':'audio/mp4','mp3':'audio/mpeg','wav':'audio/wav','ogg':'audio/ogg','flac':'audio/flac'}[ext],ext
 if ext in ('mp4','webm','mov','avi','mkv'):return 'video',{'mp4':'video/mp4','webm':'video/webm','mov':'video/quicktime','avi':'video/x-msvideo','mkv':'video/x-matroska'}[ext],ext
 return None,None,None
