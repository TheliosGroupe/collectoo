"""Bulk document upload (M1-20): unpack a zip, link each file to an account by the reference in
its name, store it in the private `documents` bucket and index it in `public.document`.

OCR and structured extraction are deferred (ROADMAP notes). Unmatched or unsupported files are
listed in the batch report so ops can fix the names and upload them again.
"""

from __future__ import annotations

import hashlib
import re
import zipfile
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

MIME = {".pdf": "application/pdf", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg"}
MAX_FILES = 10_000
MAX_UNCOMPRESSED = 2 * 1024**3  # zip-bomb guard: 2 GiB in total


@dataclass
class DocumentMatch:
    name: str
    account_ref: str | None
    sha256: str
    mime: str | None
    data: bytes = field(repr=False)


@dataclass
class ZipResult:
    matched: list[DocumentMatch] = field(default_factory=list)
    unmatched: list[str] = field(default_factory=list)
    unsupported: list[str] = field(default_factory=list)


def find_reference(name: str, refs: set[str]) -> str | None:
    """The longest account reference that appears as a whole token in the file name."""
    stem = PurePosixPath(name).stem
    tokens = set(re.split(r"[^A-Za-z0-9-]+", stem)) | set(re.split(r"[^A-Za-z0-9]+", stem))
    hits = [t for t in tokens if t in refs]
    if not hits:
        upper = stem.upper()
        hits = [r for r in refs if len(r) >= 4 and r.upper() in upper]
    return max(hits, key=len) if hits else None


def read_zip(path: Path, refs: set[str]) -> ZipResult:
    out = ZipResult()
    with zipfile.ZipFile(path) as zf:
        entries = [
            i
            for i in zf.infolist()
            if not i.is_dir() and not PurePosixPath(i.filename).name.startswith(".")
        ]
        if len(entries) > MAX_FILES or sum(i.file_size for i in entries) > MAX_UNCOMPRESSED:
            raise ValueError("zip too large: split it into smaller archives")
        for info in entries:
            name = PurePosixPath(info.filename).name
            mime = MIME.get(PurePosixPath(name).suffix.lower())
            if mime is None:
                out.unsupported.append(name)
                continue
            ref = find_reference(name, refs)
            if ref is None:
                out.unmatched.append(name)
                continue
            data = zf.read(info)
            out.matched.append(
                DocumentMatch(name, ref, hashlib.sha256(data).hexdigest(), mime, data)
            )
    return out
