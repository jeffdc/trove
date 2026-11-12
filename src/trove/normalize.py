from __future__ import annotations

import hashlib
import os
import re
import unicodedata

_UNSAFE_CHARS = re.compile(r'[/\\:*?"<>|]')
_WHITESPACE = re.compile(r"\s")
_MULTI_UNDERSCORE = re.compile(r"_{2,}")
_WINDOWS_RESERVED = re.compile(r"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$", re.IGNORECASE)

_MAX_BASENAME = 200
_TRUNCATED_LEN = 192
_HASH_LEN = 7


def normalize_filename(name: str) -> str:
    """Normalize a filename or camera-model string for safe, portable use.

    Rules applied in order:
    1. Unicode NFC normalization
    2. Split basename / extension
    3. Replace path-unsafe characters with _
    4. Replace whitespace with _
    5. Collapse consecutive underscores
    6. Strip leading/trailing dots and underscores
    7. Prefix Windows reserved names with _
    8. Empty basename → "unnamed"
    9. Long basename → truncate + MD5 hash suffix
    10. Rejoin and return
    """
    # 1. Unicode NFC
    name = unicodedata.normalize("NFC", name)

    # 2. Split basename and extension
    basename, ext = os.path.splitext(name)

    # os.path.splitext treats leading-dot names (e.g. ".jpg") as having no
    # extension.  When that happens, strip leading dots and re-split so that
    # ".jpg" → basename="" ext=".jpg" rather than basename=".jpg" ext="".
    if not ext and basename.startswith("."):
        stripped = basename.lstrip(".")
        if stripped:
            base2, ext2 = os.path.splitext(stripped)
            if ext2:
                basename = base2
                ext = ext2
            else:
                # e.g. "...txt" — no dot left, treat entire stripped part as ext
                basename = ""
                ext = "." + stripped

    # 3. Replace path-unsafe characters
    basename = _UNSAFE_CHARS.sub("_", basename)

    # 4. Replace whitespace
    basename = _WHITESPACE.sub("_", basename)

    # 5. Collapse multiple consecutive underscores
    basename = _MULTI_UNDERSCORE.sub("_", basename)

    # 6. Strip leading/trailing dots and underscores
    basename = basename.strip("._")

    # 7. Windows reserved name check (before empty check — reserved names are non-empty)
    if _WINDOWS_RESERVED.match(basename):
        basename = "_" + basename

    # 8. Empty basename fallback
    if not basename:
        basename = "unnamed"

    # 9. Truncate long basenames with hash suffix
    if len(basename) > _MAX_BASENAME:
        original_hash = hashlib.md5(basename.encode()).hexdigest()[:_HASH_LEN]
        basename = basename[:_TRUNCATED_LEN] + "_" + original_hash

    # 10. Rejoin
    return basename + ext
