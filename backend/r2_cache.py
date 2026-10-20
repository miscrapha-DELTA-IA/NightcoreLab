"""Small, private Cloudflare R2 cache using S3 Signature V4 and httpx.

No boto3, media buffering, or credentials in logs. A failed R2 operation must
never block the existing local download path.
"""

from __future__ import annotations

import asyncio
import base64
from collections import OrderedDict
from dataclasses import dataclass
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
import hashlib
import hmac
import os
from pathlib import Path
import re
import time
import unicodedata
from urllib.parse import quote, urlsplit
import xml.etree.ElementTree as ET

import httpx

TTL_SECONDS = 7 * 24 * 3600
SIGNED_URL_SECONDS = 3600
_EMPTY_HASH = hashlib.sha256(b"").hexdigest()
_NS = "http://s3.amazonaws.com/doc/2006-03-01/"


def _first(env: dict[str, str], *names: str) -> str:
    return next((env[name].strip() for name in names if env.get(name, "").strip()), "")


@dataclass(frozen=True)
class R2Config:
    endpoint: str
    bucket: str
    access_key: str
    secret_key: str

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> R2Config | None:
        env = os.environ if env is None else env
        access = _first(env, "R2_ACCESS_KEY_ID", "AWS_ACCESS_KEY_ID", "S3_ACCESS_KEY_ID", "ACCESS_KEY_ID")
        secret = _first(env, "R2_SECRET_ACCESS_KEY", "AWS_SECRET_ACCESS_KEY", "S3_SECRET_ACCESS_KEY", "SECRET_ACCESS_KEY")
        raw = _first(env, "R2_ENDPOINT_URL", "R2_ACCOUNT_ID", "S3_ENDPOINT_URL", "AWS_ENDPOINT_URL")
        if not (access and secret and raw):
            return None
        bucket = (env.get("R2_BUCKET_NAME") or "gnarly-cache").strip().lower()
        if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", bucket):
            raise ValueError("R2_BUCKET_NAME inválido")
        if "://" not in raw:
            if not re.fullmatch(r"[a-z0-9]{32}", raw.lower()):
                raise ValueError("R2_ACCOUNT_ID inválido")
            raw = f"https://{raw.lower()}.r2.cloudflarestorage.com"
        parsed = urlsplit(raw)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.port:
            raise ValueError("R2_ENDPOINT_URL deve ser HTTPS sem credenciais ou porta")
        if not re.fullmatch(r"[a-z0-9]{32}\.r2\.cloudflarestorage\.com", parsed.hostname.lower()):
            raise ValueError("R2_ENDPOINT_URL deve usar o endpoint S3 da conta Cloudflare")
        if parsed.path.strip("/").lower() not in {"", bucket} or parsed.query or parsed.fragment:
            raise ValueError("R2_ENDPOINT_URL deve conter apenas o host ou o bucket")
        return cls(f"https://{parsed.hostname.lower()}", bucket, access, secret)


def _encode(value: str) -> str:
    return quote(value, safe="-_.~")


def _canonical_query(params: dict[str, str]) -> str:
    return "&".join(f"{_encode(k)}={_encode(v)}" for k, v in
                    sorted(params.items(), key=lambda item: (_encode(item[0]), _encode(item[1]))))


def _hmac(key: bytes, value: str) -> bytes:
    return hmac.new(key, value.encode("utf-8"), hashlib.sha256).digest()


class R2Cache:
    def __init__(self, config: R2Config, client: httpx.AsyncClient | None = None):
        self.config = config
        self.client = client or httpx.AsyncClient(timeout=httpx.Timeout(20, connect=5), follow_redirects=False)
        self._owns_client = client is None
        self._hot: OrderedDict[str, tuple[float, dict[str, str]]] = OrderedDict()
        self._hot_limit = 1024

    async def close(self) -> None:
        if self._owns_client:
            await self.client.aclose()

    def _path(self, key: str = "") -> str:
        pieces = [self.config.bucket] + ([*key.split("/")] if key else [])
        return "/" + "/".join(_encode(piece) for piece in pieces)

    def _signature(self, date: str, scope_date: str, text: str) -> str:
        key = _hmac(("AWS4" + self.config.secret_key).encode(), scope_date)
        key = _hmac(key, "auto")
        key = _hmac(key, "s3")
        key = _hmac(key, "aws4_request")
        return hmac.new(key, text.encode(), hashlib.sha256).hexdigest()

    def _sign(self, method: str, path: str, params: dict[str, str], headers: dict[str, str],
              payload_hash: str, now: datetime, presign: bool = False) -> tuple[str, dict[str, str]]:
        stamp = now.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        day = stamp[:8]
        scope = f"{day}/auto/s3/aws4_request"
        host = urlsplit(self.config.endpoint).hostname or ""
        signed_headers = {"host": host}
        if not presign:
            signed_headers.update({k.lower(): " ".join(v.strip().split()) for k, v in headers.items()})
            signed_headers["x-amz-content-sha256"] = payload_hash
            signed_headers["x-amz-date"] = stamp
        names = ";".join(sorted(signed_headers))
        if presign:
            params = {**params, "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
                      "X-Amz-Credential": f"{self.config.access_key}/{scope}",
                      "X-Amz-Date": stamp, "X-Amz-Expires": str(SIGNED_URL_SECONDS),
                      "X-Amz-SignedHeaders": names}
        canonical = "\n".join((method, path, _canonical_query(params),
                               "".join(f"{name}:{signed_headers[name]}\n" for name in sorted(signed_headers)),
                               names, "UNSIGNED-PAYLOAD" if presign else payload_hash))
        sign_text = "\n".join(("AWS4-HMAC-SHA256", stamp, scope,
                               hashlib.sha256(canonical.encode()).hexdigest()))
        signature = self._signature(stamp, day, sign_text)
        if presign:
            params["X-Amz-Signature"] = signature
            return self.config.endpoint + path + "?" + _canonical_query(params), {}
        auth = (f"AWS4-HMAC-SHA256 Credential={self.config.access_key}/{scope},"
                f"SignedHeaders={names},Signature={signature}")
        return self.config.endpoint + path + (("?" + _canonical_query(params)) if params else ""), {
            **headers, "Host": host, "x-amz-date": stamp,
            "x-amz-content-sha256": payload_hash, "Authorization": auth}

    def presigned_get(self, key: str, now: datetime | None = None) -> str:
        return self._sign("GET", self._path(key), {}, {}, _EMPTY_HASH,
                          now or datetime.now(timezone.utc), presign=True)[0]

    def presigned_head(self, key: str, now: datetime | None = None) -> str:
        return self._sign("HEAD", self._path(key), {}, {}, _EMPTY_HASH,
                          now or datetime.now(timezone.utc), presign=True)[0]

    def _remember(self, key: str, last_modified: float, meta: dict[str, str]) -> None:
        self._hot[key] = (last_modified, meta)
        self._hot.move_to_end(key)
        if len(self._hot) > self._hot_limit:
            self._hot.popitem(last=False)

    @staticmethod
    def _metadata(headers: httpx.Headers) -> dict[str, str]:
        result = {}
        for field in ("title", "thumbnail"):
            encoded = headers.get(f"x-amz-meta-{field}", "")
            try:
                if encoded:
                    result[field] = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)).decode("utf-8")
            except (ValueError, UnicodeDecodeError):
                pass
        return result

    async def find(self, key: str) -> dict[str, str] | None:
        now = time.time()
        if key in self._hot:
            modified, meta = self._hot[key]
            if now - modified < TTL_SECONDS:
                self._hot.move_to_end(key)
                return meta
            self._hot.pop(key, None)
        url, headers = self._sign("HEAD", self._path(key), {}, {}, _EMPTY_HASH,
                                  datetime.now(timezone.utc))
        response = await self.client.head(url, headers=headers)
        if response.status_code == 404:
            return None
        response.raise_for_status()
        modified = parsedate_to_datetime(response.headers["Last-Modified"]).timestamp()
        if now - modified >= TTL_SECONDS:
            return None
        meta = self._metadata(response.headers)
        self._remember(key, modified, meta)
        return meta

    async def put(self, key: str, path: Path, title: str, thumbnail: str | None) -> None:
        # S3 SigV4 requires the payload hash. Read in chunks, then stream a
        # second time; never buffer the file. A local cache reader pin protects it.
        digest = hashlib.sha256()
        with path.open("rb") as file:
            for chunk in iter(lambda: file.read(256 * 1024), b""):
                digest.update(chunk)
        size = path.stat().st_size
        if size <= 0:
            raise ValueError("Arquivo de áudio vazio")
        def encoded(value: str) -> str:
            return base64.urlsafe_b64encode(value.encode()).decode().rstrip("=")
        clean_title = "".join(ch for ch in title if ch.isprintable() and ch not in '\\/:*?"<>|')[:120].strip() or "audio"
        ascii_title = unicodedata.normalize("NFKD", clean_title).encode("ascii", "ignore").decode().strip() or "audio"
        headers = {"Content-Type": "audio/mp4", "Content-Length": str(size),
                   "Content-Disposition": f'attachment; filename="{ascii_title}.m4a"; filename*=UTF-8\'\'{_encode(clean_title + ".m4a")}',
                   "x-amz-meta-title": encoded(title)}
        if thumbnail:
            headers["x-amz-meta-thumbnail"] = encoded(thumbnail)
        url, signed = self._sign("PUT", self._path(key), {}, headers, digest.hexdigest(),
                                 datetime.now(timezone.utc))
        async def chunks():
            with path.open("rb") as file:
                while data := await asyncio.to_thread(file.read, 256 * 1024):
                    yield data
        response = await self.client.put(url, headers=signed, content=chunks(), timeout=180)
        response.raise_for_status()
        self._remember(key, time.time(), {"title": title, "thumbnail": thumbnail or ""})

    async def ensure_lifecycle(self) -> bool:
        """Merge our 7-day rule without deleting rules owned by the bucket user."""
        params = {"lifecycle": ""}
        now = datetime.now(timezone.utc)
        url, headers = self._sign("GET", self._path(), params, {}, _EMPTY_HASH, now)
        response = await self.client.get(url, headers=headers)
        if response.status_code == 404:
            root = ET.Element("LifecycleConfiguration", xmlns=_NS)
        else:
            response.raise_for_status()
            root = ET.fromstring(response.content)
        for rule in list(root):
            if rule.findtext(f"{{{_NS}}}ID") == "gnarly-cache-seven-days":
                root.remove(rule)
        tag = lambda name: f"{{{_NS}}}{name}"
        rule = ET.SubElement(root, tag("Rule"))
        ET.SubElement(rule, tag("ID")).text = "gnarly-cache-seven-days"
        ET.SubElement(rule, tag("Status")).text = "Enabled"
        ET.SubElement(ET.SubElement(rule, tag("Filter")), tag("Prefix"))
        ET.SubElement(ET.SubElement(rule, tag("Expiration")), tag("Days")).text = "7"
        payload = ET.tostring(root, encoding="utf-8", xml_declaration=True)
        put_headers = {"Content-Type": "application/xml", "Content-Length": str(len(payload))}
        url, signed = self._sign("PUT", self._path(), params, put_headers,
                                 hashlib.sha256(payload).hexdigest(), datetime.now(timezone.utc))
        response = await self.client.put(url, headers=signed, content=payload)
        response.raise_for_status()
        return True
