"""Supabase Storage access for the worker (service key; never shipped to a browser)."""

from __future__ import annotations

from pathlib import Path
from typing import Protocol
from urllib.parse import quote

import httpx


class Storage(Protocol):
    def download(self, bucket: str, path: str, dest: Path) -> Path: ...

    def upload(self, bucket: str, path: str, data: bytes, content_type: str = ...) -> None: ...

    def remove(self, bucket: str, paths: list[str]) -> None: ...


class SupabaseStorage:
    def __init__(self, url: str, secret_key: str, timeout_s: float = 120.0) -> None:
        self._base = url.rstrip("/") + "/storage/v1/object"
        self._headers = {"apikey": secret_key}
        self._timeout = timeout_s
        self._client = httpx.Client()  # kept alive (thread-safe): receipts upload many small files

    def download(self, bucket: str, path: str, dest: Path) -> Path:
        url = f"{self._base}/{quote(bucket)}/{quote(path)}"
        with httpx.stream("GET", url, headers=self._headers, timeout=self._timeout) as resp:
            resp.raise_for_status()
            with dest.open("wb") as fh:
                for chunk in resp.iter_bytes(1 << 20):
                    fh.write(chunk)
        return dest

    def upload(
        self, bucket: str, path: str, data: bytes, content_type: str = "application/octet-stream"
    ) -> None:
        url = f"{self._base}/{quote(bucket)}/{quote(path)}"
        resp = self._client.post(
            url,
            headers={**self._headers, "Content-Type": content_type, "x-upsert": "true"},
            content=data,
            timeout=self._timeout,
        )
        resp.raise_for_status()

    def remove(self, bucket: str, paths: list[str]) -> None:
        """Delete objects; paths already gone are ignored (safe to retry)."""
        for start in range(0, len(paths), 1000):
            resp = httpx.request(
                "DELETE",
                f"{self._base}/{quote(bucket)}",
                headers=self._headers,
                json={"prefixes": paths[start : start + 1000]},
                timeout=self._timeout,
            )
            resp.raise_for_status()
