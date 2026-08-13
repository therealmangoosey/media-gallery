from PIL import Image as PILImage
from PIL import ImageOps
import io
import os
import uuid

ALLOWED_EXTENSIONS = {'.jpg', '.jpeg', '.png', '.webp'}

def validate_image(file_content: bytes):
    try:
        img = PILImage.open(io.BytesIO(file_content))
        img.verify() # Verify it's a valid image
        
        # Check format
        if img.format.lower() not in ['jpeg', 'png', 'webp']:
            return False, "Unsupported format"
            
        # Check dimensions
        if img.width > 5000 or img.height > 5000:
            return False, "Image too large"
            
        return True, img.format.lower()
    except Exception as e:
        return False, str(e)

def process_and_save(file_content: bytes, target_path: str):
    """
    Re-encodes image to strip metadata and normalize.
    """
    img = PILImage.open(io.BytesIO(file_content))
    
    # Auto-orient based on EXIF then strip EXIF
    img = ImageOps.exif_transpose(img)
    
    # Create a new image without metadata
    # We use RGB to ensure compatibility and strip alpha if not needed, 
    # or keep RGBA if the original has it.
    mode = img.mode
    if mode not in ("RGB", "RGBA"):
        img = img.convert("RGB")
        mode = "RGB"

    new_img = PILImage.new(mode, img.size)
    new_img.paste(img)
    
    new_img.save(target_path, "WEBP", quality=85, method=6)
    return True
