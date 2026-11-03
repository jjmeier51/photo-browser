"""Content-key retrieval and DASH download for Passes media (no Qt).

Two entry points: grab_original() for the encrypted `original` variant, and
grab_plain_dash() for an unencrypted manifest. The licence request is
authenticated with the caller's own access token; the Widevine device only
supplies the session envelope.

ffmpeg is resolved through video_tools, which knows the Homebrew paths a bundled
.app's PATH doesn't include. Paths handed to social.* are converted to str.
"""
from __future__ import annotations

import os
import re
import subprocess
import tempfile
import traceback
import urllib.request
from pathlib import Path
from urllib.parse import quote

import yt_dlp
from pywidevine import PSSH, Cdm, Device

import passes
import social
import video_tools

SW_SECURE_CRYPTO = "8fd9a7ea-73de-49bc-8b9e-ec1e73d325d3"
SW_SECURE_DECODE = "d597b3c2-7827-4047-9ee4-c10e49f7bc14"

# BuyDRM service certificate — only a backstop; make_device.py writes the real
# one to service_cert.txt next to the device.
SERVICE_CERT = (
    "CAUSuQUKswIIAxIQTBvbgP1Avrk5wSGIMyCvYRjV5pC7BSKOAjCCAQoCggEBANZJ542CyvnJY1c3AsvH1jtzpXtHIfaL+gaiqFK9TQG3hA5UZq2kJaBVe+JfXKL4OV1qwyV18/OXiWeNFXJc7TTSkuC+oqnNFIuICNCvAH2dhpB/FBOm7w6X8kGQUZh9vm0QxbpLct60VUl1uwajN76lJRtrIkZyvy9+Ep6AST3cYPDWwhIwao6BDSWDk8XlxT+Lu22RgaiYPUgBUhnc3uhN4jyYZj5lQ4HIw7YJ8rMTI+CVS1TcxAeQfwoDfmLkIK0ifRBuUbKVDFXKaHCD62+MOytkCQsDGuSWAL+zX2lFtuyIEU3tF1yAHHZNP4OilJktHA4rw600jhl8OazEe/MCAwEAAToGYnV5ZHJtEoADfn/wSHa0UlyDQqzv+GDaAbT8sMV7tUpqXbAHSCJRmdIDX/ZuZPLVJucxSnEVakX5goeMELdkKjMeGi75dojRoVEPpWw7GJSxzxZ8LAjRE+Y2ymVxyKgeH7MZxVIGhxxBosUVnOR3LyCfKiUArK/cZ2wQYJ/mOFOmBQDEmDU7nkGclIJOxY0BKNwpMlKJFWy32srxXJlDJ1VozWdkLxZuMP6J0qzqsZGm0AIMXPMPha16XIsycTPA5O7cjb3fF2hqWZF7ah1NMbcvfprZiPfJPCWnwtL+ZCz8poq1PJ2QRXr0GE1ZwS5CDv/AmOiE2i3NuhdVTrBi1aQ6QBB5rkERA2ypjBAPV59PreurelpBx8kgZSTxwITRJJvO46INq0Jy7bHXL42iDli25YatVW4s7IlGPHIjSphQ/Z4k/PKwX3vQOe5LvGWyRN4OXcNFBdZB6yv5k+2LYW2yhz5NFjO92p4YCwSXx/s/7EidD4tev5Ry6N3/heqc7YIIo2q4hsyp"
)

_IMAGE_EXTS = {"jpg", "jpeg", "png", "webp"}
_VIDEO_SUFFIXES = {".mp4", ".m4a", ".m4v", ".mov", ".m4s", ".ts", ".aac"}


def _service_cert() -> str:
    """The service certificate written by make_device.py, else the embedded copy."""
    try:
        return (passes.device_path().parent / "service_cert.txt").read_text().strip()
    except OSError:
        return SERVICE_CERT


def _pssh_from(manifest: bytes) -> PSSH:
    m = re.search(rb"<cenc:pssh>([^<]+)</cenc:pssh>", manifest)
    if not m:
        raise RuntimeError("no pssh in manifest")
    pssh = PSSH(m.group(1).decode())
    if pssh.system_id != PSSH.SystemId.Widevine:
        raise RuntimeError("pssh is not Widevine")
    return pssh


def _content_key(pssh: PSSH, content_id: str, access_token: str):
    """Ask the licence endpoint for the content key, at two security levels."""
    device = passes.device_path()
    if not device.is_file():
        raise RuntimeError(f"no Widevine device at {device}")

    cdm = Cdm.from_device(Device.load(str(device)))
    sid = cdm.open()
    try:
        cdm.set_service_certificate(sid, _service_cert())
        last: Exception | None = None
        for level in (SW_SECURE_CRYPTO, SW_SECURE_DECODE):
            challenge = cdm.get_license_challenge(sid, pssh)
            url = (f"{passes.API}/content/drm/license-request"
                   f"?drm-type=widevine&drm-code={level}"
                   f"&content-id={quote(content_id)}")
            req = urllib.request.Request(url, data=challenge, headers={
                "Authorization": f"Bearer {access_token}",
                "Content-Type":  "application/octet-stream",
                "User-Agent":    passes._UA,
                "Origin":        "https://www.passes.com",
                "Referer":       "https://www.passes.com/",
            })
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    cdm.parse_license(sid, r.read())
                keys = cdm.get_keys(sid, "CONTENT")
                if keys:
                    return keys[0]
            except Exception as e:  # noqa: BLE001
                last = e
        raise RuntimeError(f"licence rejected at both levels: {last}")
    finally:
        cdm.close(sid)


def _ffmpeg(args: list[str]) -> None:
    exe = video_tools.ffmpeg()
    if not exe:
        raise RuntimeError("ffmpeg not found")
    subprocess.run([exe, "-y", *args],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)


def _merge(plain: list[Path], staged: Path, date: float) -> None:
    """Put the downloaded tracks together into `staged`."""
    if len(plain) == 2 and not video_tools.ffmpeg():
        # no ffmpeg: AVFoundation through the helper can still join two halves
        if not video_tools.mux(str(plain[0]), str(plain[1]), str(staged), date):
            raise RuntimeError("mux failed and no ffmpeg")
        return
    args: list[str] = []
    for p in plain:
        args += ["-i", str(p)]
    _ffmpeg(args + ["-c", "copy", str(staged)])


def _grab(item: social.Item, headers: dict, exif_session, url: str,
          content_id: str | None) -> social.Settled:
    """Download `url` as DASH, decrypt when `content_id` is given, then place it."""
    if os.path.lexists(item.folder / item.filename):
        return social.Settled(item, str(item.folder / item.filename), present=True)

    # ffmpeg can't write HEIC, so anything unusual becomes a JPEG
    ext = "mp4" if item.video else (item.ext if item.ext in _IMAGE_EXTS else "jpg")
    out_name = f"{item.name}.{ext}"

    try:
        with tempfile.TemporaryDirectory(prefix="passes-dash-") as td:
            tmp = Path(td)

            key = None
            if content_id is not None:
                man = tmp / "manifest.mpd"
                with urllib.request.urlopen(url, timeout=30) as r:
                    man.write_bytes(r.read())
                token = headers["Authorization"].split(" ", 1)[1]
                key = _content_key(_pssh_from(man.read_bytes()), content_id, token)

            yt_dlp.YoutubeDL({
                "quiet": True,
                "no_warnings": True,
                "allow_unplayable_formats": True,
                "outtmpl": str(tmp / "%(format_id)s.%(ext)s"),
            }).download([url])

            # an encrypted image downloads as a segment, not a media file, so only
            # video tracks may be narrowed by suffix
            got = sorted(p for p in tmp.iterdir()
                         if p.is_file() and p.suffix not in {".mpd", ".m3u8"})
            if item.video:
                tracks = [p for p in got if p.suffix in _VIDEO_SUFFIXES] or got
            else:
                tracks = got
            if not tracks:
                raise RuntimeError("nothing downloaded")

            plain: list[Path] = []
            for t in tracks:
                if key is None:
                    plain.append(t)
                    continue
                out = tmp / f"plain_{t.name}"
                _ffmpeg(["-decryption_key", key.key.hex(),
                         "-i", str(t), "-c", "copy", str(out)])
                plain.append(out)

            staged = tmp / out_name
            if item.video:
                _merge(plain, staged, item.date)
            else:
                _ffmpeg(["-i", str(plain[0]), "-frames:v", "1", "-q:v", "2", str(staged)])

            if item.date:
                os.utime(str(staged), (item.date, item.date))
            if exif_session is not None:
                social.write_meta(str(staged), item, exif_session)

            placed = social.place(str(staged), item.folder, out_name)
            if placed is None:
                return social.Settled(item, str(item.folder / out_name), present=True)
            return social.Settled(item, placed)
    except Exception as e:  # noqa: BLE001
        where = traceback.extract_tb(e.__traceback__)[-1]
        return social.Settled(
            item,
            why=(f"dash: {type(e).__name__}: {e} "
                 f"(at {os.path.basename(where.filename)}:{where.lineno})"))


def grab_original(item: social.Item, headers: dict, exif_session=None) -> social.Settled:
    """Fetch, decrypt and place the original-quality variant of one item."""
    url = passes.ENCRYPTED.get(item.key)
    if not url:
        return social.Settled(item, why="dash: no manifest url")
    return _grab(item, headers, exif_session, url, item.key)


def grab_plain_dash(item: social.Item, headers: dict, exif_session=None) -> social.Settled:
    """Fetch and place an unencrypted manifest (no key needed)."""
    return _grab(item, headers, exif_session, item.url, None)