"""Image validation and (re-)encoding.

Every upload is re-encoded to WebP. This strips EXIF/GPS metadata, auto-orients
photos, normalizes the pixel format, and produces a compact file plus a small
thumbnail so the gallery loads quickly.
"""

import io

from PIL import Image as PILImage
from PIL import ImageOps

ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}
ALLOWED_FORMATS = {"jpeg", "png", "webp"}

# Reject anything above these limits before decoding further. This prevents
# decompression-bomb / memory-exhaustion attacks via a hostile image.
MAX_DIMENSION = 12000
MAX_PIXELS = 40_000_000  # 40 MP

# Enforce Pillow's own guard at the same limit as a second line of defense
# (in case a crafted header lies about dimensions until decode time).
PILImage.MAX_IMAGE_PIXELS = MAX_PIXELS

THUMBNAIL_MAX = 480
QUALITY = 82


def validate_image(file_content: bytes):
    """Return (ok, format_name_or_error)."""
    try:
        img = PILImage.open(io.BytesIO(file_content))
        fmt = (img.format or "").lower()
        if fmt not in ALLOWED_FORMATS:
            return False, "Unsupported format"

        width, height = img.size
        if width > MAX_DIMENSION or height > MAX_DIMENSION:
            return False, f"Image too large ({width}x{height})"
        if width * height > MAX_PIXELS:
            return False, "Image has too many pixels"

        # Verify the whole image actually decodes (catches truncated/corrupt
        # files that only look valid in the header).
        img.verify()
        return True, fmt
    except Exception as exc:  # noqa: BLE001 - any decode error is a reject
        return False, f"Invalid image data: {exc}"


def _reencode(img: PILImage.Image, target_path: str, max_side: int | None = None):
    img = ImageOps.exif_transpose(img)

    # Flatten exotic modes (P, LA, CMYK, I, F...) to RGB/RGBA.
    if img.mode not in ("RGB", "RGBA"):
        has_alpha = img.mode in ("LA", "PA") or (
            img.mode == "P" and "transparency" in img.info
        )
        img = img.convert("RGBA" if has_alpha else "RGB")

    if max_side:
        img.thumbnail((max_side, max_side), PILImage.LANCZOS)

    img.save(target_path, "WEBP", quality=QUALITY, method=6)


def process_and_save(file_content: bytes, main_path: str, thumb_path: str | None = None):
    """Re-encode to WebP, writing the full image and (optionally) a thumbnail."""
    img = PILImage.open(io.BytesIO(file_content))
    _reencode(img, main_path)
    if thumb_path:
        _reencode(img.copy(), thumb_path, max_side=THUMBNAIL_MAX)
    return True
