"""Finding the faces in a photo, and turning each into numbers that say whose it is — on this Mac, with no Qt.

`people.py` groups faces into people; this module is what looks at the pictures:

- **Where the faces are** — YuNet (OpenCV's face detector; MIT licence, 230 KB): every face's box and five points
  (the eyes, the tip of the nose, the corners of the mouth).
- **Whose face it is** — SFace (OpenCV's face recogniser; Apache-2.0, 37 MB): the face, turned upright and cropped
  to 112 × 112 by those five points, becomes 128 numbers. Two pictures of one person give nearly the same numbers
  (cosine similarity above about 0.36); two people don't.

Both are run directly with onnxruntime and worked out in numpy + Pillow here — no OpenCV — exactly as OpenCV runs
them (checked against `cv2.FaceDetectorYN` / `FaceRecognizerSF`: boxes to 1e-4 px, embeddings to cosine 0.9997).
The same code runs on the Mac and, for the tests, on Linux.

**The models aren't in the app**: they're downloaded once, on the day People is first used, from OpenCV's own
model pages, checked against their published SHA-256, and kept in
`~/Library/Application Support/Photo Browser for Mac/People/models`. That download is the only time the network
is involved: **no photo, face or number ever leaves the Mac.**

Things learned the hard way (all measured):
- The detector wants **BGR**, the recogniser **RGB**; both take 0…255 with no scaling.
- The detector sees faces about 10–300 px tall *in the 640 × 640 picture it's given*. A whole 12-megapixel photo
  squeezed to 640 loses the faces at the back of a group; cut into tiles it loses the close-up that fills the
  frame. So: once whole, and — for a big photo — again as overlapping tiles at twice the size, the two merged.
- The recogniser's quantised file doesn't load in onnxruntime; the full one logs hundreds of harmless warnings
  unless told to be quiet.

`analyse(path)` is the whole job for one photo: its faces as dicts with `box` (fractions of the upright picture,
from the top left), `score`, `quality` (`people.quality_of`: size, sharpness, facing the camera) and `emb`.
`scan(...)` does a folder's worth on a few threads and hands each photo's faces to the store.
"""
from __future__ import annotations

import hashlib
import os
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Callable

import numpy as np

import people

MODEL = "yunet-2023mar+sface-2021dec"          # stamped on every photo looked at: other models, other numbers
MODELS = {
    "detector": {
        "file": "face_detection_yunet_2023mar.onnx", "bytes": 232_589,
        "sha256": "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4",
        "url": "https://huggingface.co/opencv/face_detection_yunet/resolve/main/face_detection_yunet_2023mar.onnx",
        "what": "YuNet face detector (OpenCV, MIT licence)"},
    "recogniser": {
        "file": "face_recognition_sface_2021dec.onnx", "bytes": 38_696_353,
        "sha256": "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79",
        "url": "https://huggingface.co/opencv/face_recognition_sface/resolve/main/face_recognition_sface_2021dec.onnx",
        "what": "SFace face recogniser (OpenCV, Apache-2.0 licence)"},
}
NET = 640                                       # the detector's picture is 640 × 640
SCORE_SHOW, SCORE_USE = 0.6, 0.72               # a detection at all; one sure enough to go by
MIN_FACE = 36                                   # px on its shorter side, in the photo as decoded
MAX_FACES = 40
DECODE = 2560                                   # a photo's longer side as worked on (a JPEG is decoded near this)
TEMPLATE = np.array([[38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366], [41.5493, 92.3655],
                     [70.7299, 92.2041]], dtype=np.float64)        # where the five points belong in the 112 × 112 crop
PHOTO_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp", ".tif", ".tiff", ".bmp", ".avif"}


class Missing(Exception):
    """The models (or onnxruntime) aren't there yet."""


def models_folder() -> Path:
    env = os.environ.get("PHOTO_BROWSER_FACE_MODELS")
    return Path(env) if env else people.folder() / "models"


def installed() -> bool:
    return all((models_folder() / m["file"]).is_file() for m in MODELS.values())


def runtime_ok() -> bool:
    try:
        import onnxruntime  # noqa: F401
        return True
    except ImportError:
        return False


def download_size() -> int:
    return sum(m["bytes"] for m in MODELS.values() if not (models_folder() / m["file"]).is_file())


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def download(progress: Callable[[str], None] = lambda _t: None, stop: Callable[[], bool] | None = None) -> None:
    """Fetches the models not here yet, each checked against its published SHA-256 before it's kept. Raises
    `OSError` with a sentence when it can't."""
    import net_fetch
    folder = models_folder()
    folder.mkdir(parents=True, exist_ok=True)
    for m in MODELS.values():
        dest = folder / m["file"]
        if dest.is_file():
            continue
        part = folder / (m["file"] + ".part")
        total = m["bytes"]
        progress(f"Downloading the {m['what']}…")
        got, why = net_fetch.fetch_to_file(
            m["url"], {"User-Agent": "PhotoBrowser/1.0"}, str(part), limit=3600, stop=stop, min_bytes=1000,
            progress=lambda have, _t, m=m: progress(f"Downloading the {m['what']}… {have / 1e6:.1f} of {total / 1e6:.1f} MB"))
        if not got:
            raise OSError(f"The {m['what']} couldn't be downloaded: {why}.")
        if _sha256(part) != m["sha256"]:
            part.unlink(missing_ok=True)
            raise OSError(f"The {m['what']} that came down isn't the published file (its checksum differs) — "
                          "it wasn't kept.")
        os.replace(part, dest)


_sessions: dict[str, object] = {}
_lock = threading.Lock()


def _session(which: str):
    with _lock:
        s = _sessions.get(which)
        if s is None:
            try:
                import onnxruntime as ort
            except ImportError as e:
                raise Missing("onnxruntime isn't installed") from e
            path = models_folder() / MODELS[which]["file"]
            if not path.is_file():
                raise Missing(f"{MODELS[which]['file']} isn't downloaded")
            opts = ort.SessionOptions()
            opts.intra_op_num_threads = 1                 # the scan runs several photos at once instead
            opts.log_severity_level = 3
            s = _sessions[which] = ort.InferenceSession(str(path), opts, providers=["CPUExecutionProvider"])
        return s


# ----------------------------------------------------------------------------- where the faces are

_NAMES = [f"{k}_{st}" for k in ("cls", "obj", "bbox", "kps") for st in (8, 16, 32)]


def _detect_tile(rgb: np.ndarray, scale: float, ox: float, oy: float, threshold: float) -> np.ndarray:
    """Faces in one picture no bigger than 640 × 640 (`rgb`: H × W × 3 uint8) as rows of
    [x, y, w, h, ten landmark coordinates, score] in the *photo's* pixels: tile → photo is ÷ `scale`, + (ox, oy)."""
    h, w = rgb.shape[:2]
    canvas = np.zeros((NET, NET, 3), dtype=np.float32)
    canvas[:h, :w] = rgb[:, :, ::-1]                               # RGB → BGR, top-left, the rest black
    out = dict(zip(_NAMES, _session("detector").run(_NAMES, {"input": canvas.transpose(2, 0, 1)[None]})))
    rows = []
    for st in (8, 16, 32):
        n = NET // st
        score = np.sqrt(np.clip(out[f"cls_{st}"][0, :, 0], 0, 1) * np.clip(out[f"obj_{st}"][0, :, 0], 0, 1))
        keep = score >= threshold
        if not keep.any():
            continue
        idx = np.nonzero(keep)[0]
        c, r = (idx % n).astype(np.float32), (idx // n).astype(np.float32)
        b = out[f"bbox_{st}"][0][idx]
        k = out[f"kps_{st}"][0][idx].reshape(-1, 5, 2).copy()
        cx, cy = (c + b[:, 0]) * st, (r + b[:, 1]) * st
        bw, bh = np.exp(b[:, 2]) * st, np.exp(b[:, 3]) * st
        k[:, :, 0] = (k[:, :, 0] + c[:, None]) * st
        k[:, :, 1] = (k[:, :, 1] + r[:, None]) * st
        rows.append(np.concatenate([np.stack([cx - bw / 2, cy - bh / 2, bw, bh], 1), k.reshape(-1, 10),
                                    score[idx, None]], 1))
    if not rows:
        return np.zeros((0, 15), dtype=np.float32)
    f = np.concatenate(rows, 0).astype(np.float64)
    f[:, :14] /= scale
    f[:, 0] += ox
    f[:, 1] += oy
    f[:, 4:14:2] += ox
    f[:, 5:14:2] += oy
    return f


def _nms(f: np.ndarray, overlap: float = 0.3) -> np.ndarray:
    """The best of each pile of boxes that are one face (greedy, by score)."""
    if not len(f):
        return f
    f = f[np.argsort(-f[:, 14], kind="stable")]
    x1, y1 = f[:, 0], f[:, 1]
    x2, y2 = x1 + f[:, 2], y1 + f[:, 3]
    area = f[:, 2] * f[:, 3]
    alive = np.ones(len(f), dtype=bool)
    keep = []
    for i in range(len(f)):
        if not alive[i]:
            continue
        keep.append(i)
        iw = np.clip(np.minimum(x2[i], x2) - np.maximum(x1[i], x1), 0, None)
        ih = np.clip(np.minimum(y2[i], y2) - np.maximum(y1[i], y1), 0, None)
        alive &= ~(iw * ih / (area[i] + area - iw * ih + 1e-9) > overlap)
    return f[keep]


def detect(img, threshold: float = SCORE_SHOW) -> np.ndarray:
    """Every face in a Pillow RGB picture: rows of [x, y, w, h, 10 landmark coordinates, score], best first."""
    from PIL import Image
    W, H = img.size
    s = min(NET / W, NET / H, 1.0)
    small = img.resize((max(1, round(W * s)), max(1, round(H * s))), Image.Resampling.BILINEAR) if s < 1 else img
    found = [_detect_tile(np.asarray(small, dtype=np.uint8), s, 0.0, 0.0, threshold)]
    if max(W, H) > NET * 1.5:                                      # big enough to hide small faces: again, in tiles
        s2 = min(2 * NET / W, 2 * NET / H, 1.0)
        w2, h2 = max(1, round(W * s2)), max(1, round(H * s2))
        mid = np.asarray(img.resize((w2, h2), Image.Resampling.BILINEAR) if s2 < 1 else img, dtype=np.uint8)

        def starts(size: int) -> list[int]:
            if size <= NET:
                return [0]
            last = size - NET
            return sorted({0, last // 2, last}) if last > 160 else [0, last]

        for ty in starts(h2):
            for tx in starts(w2):
                tile = mid[ty:ty + NET, tx:tx + NET]
                f = _detect_tile(tile, s2, tx / s2, ty / s2, threshold)
                if len(f):
                    # a face cut by a tile's edge isn't a face: the next tile (or the whole-picture pass) has it
                    # whole. An edge that is the photo's own edge cuts nothing.
                    th, tw = tile.shape[:2]
                    left, top = (f[:, 0] * s2 - tx), (f[:, 1] * s2 - ty)
                    right, bottom = left + f[:, 2] * s2, top + f[:, 3] * s2
                    cut = ((left <= 2) & (tx > 0)) | ((top <= 2) & (ty > 0)) | \
                          ((right >= tw - 2) & (tx + tw < w2)) | ((bottom >= th - 2) & (ty + th < h2))
                    found.append(f[~cut])
    return _nms(np.concatenate(found, 0))[:MAX_FACES * 2]


# ----------------------------------------------------------------------------- whose face it is

def _similarity(src: np.ndarray, dst: np.ndarray = TEMPLATE) -> np.ndarray:
    """The 2 × 3 matrix that turns, scales and moves the points `src` onto `dst` as nearly as can be (Umeyama)."""
    src = np.asarray(src, dtype=np.float64)
    ms, md = src.mean(0), dst.mean(0)
    sc, dc = src - ms, dst - md
    U, S, Vt = np.linalg.svd(dc.T @ sc / len(src))
    d = np.ones(2)
    if np.linalg.det(U) * np.linalg.det(Vt) < 0:
        d[1] = -1
    R = U @ np.diag(d) @ Vt
    scale = (S * d).sum() / max((sc ** 2).sum() / len(src), 1e-12)
    M = np.zeros((2, 3))
    M[:, :2] = scale * R
    M[:, 2] = md - scale * R @ ms
    return M


def align(img, landmarks: np.ndarray):
    """The face upright in a 112 × 112 picture, its eyes, nose and mouth where the recogniser expects them."""
    from PIL import Image
    A = np.vstack([_similarity(landmarks), [0, 0, 1]])
    Ai = np.linalg.inv(A)
    a, b, c, d, e, f = Ai[0, 0], Ai[0, 1], Ai[0, 2], Ai[1, 0], Ai[1, 1], Ai[1, 2]
    # (OpenCV counts a pixel's centre as a whole number, Pillow as a half)
    return img.transform((112, 112), Image.Transform.AFFINE,
                         (a, b, c + 0.5 - (a + b) / 2, d, e, f + 0.5 - (d + e) / 2), resample=Image.Resampling.BILINEAR)


def embed(aligned) -> np.ndarray:
    """The aligned face as 128 numbers of length 1."""
    x = np.asarray(aligned.convert("RGB"), dtype=np.float32).transpose(2, 0, 1)[None]
    v = _session("recogniser").run(["fc1"], {"data": x})[0][0].astype(np.float32)
    return v / max(float(np.linalg.norm(v)), 1e-9)


def _sharpness(aligned) -> float:
    g = np.asarray(aligned.convert("L"), dtype=np.float32)
    lap = -4 * g[1:-1, 1:-1] + g[:-2, 1:-1] + g[2:, 1:-1] + g[1:-1, :-2] + g[1:-1, 2:]
    return float(lap.var())


def _frontal(lm: np.ndarray) -> float:
    """1 facing the camera … 0 in profile: how far the nose sits from midway between the eyes."""
    eyes = float(np.linalg.norm(lm[1] - lm[0]))
    if eyes < 1e-6:
        return 0.0
    return float(max(0.0, 1.0 - abs(lm[2, 0] - (lm[0, 0] + lm[1, 0]) / 2) / eyes * 2.0))


# ----------------------------------------------------------------------------- a photo, a folder

def open_upright(path: str, longest: int = DECODE):
    """The photo as a Pillow RGB picture the way it's meant to be seen (EXIF orientation applied), no bigger
    than it need be."""
    from PIL import Image, ImageOps
    try:
        import batch_crop  # noqa: F401 — registers HEIC with Pillow, when it can
    except ImportError:
        pass
    im = Image.open(path)
    try:
        im.draft("RGB", (longest, longest))                        # a JPEG: decoded near the size wanted
    except Exception:  # noqa: BLE001 — only a speed-up
        pass
    im = ImageOps.exif_transpose(im)
    if im.mode != "RGB":
        im = im.convert("RGB")
    if max(im.size) > longest:
        im.thumbnail((longest, longest), Image.Resampling.BILINEAR)
    return im


def analyse(path: str) -> list[dict]:
    """The faces in one photo (module notes). Raises `Missing` without the models; `OSError`/`ValueError` for a
    file that can't be read as a picture."""
    im = open_upright(path)
    W, H = im.size
    out: list[dict] = []
    for row in detect(im):
        x, y, w, h = (float(v) for v in row[:4])
        score = float(row[14])
        if score < SCORE_USE or min(w, h) < MIN_FACE:
            continue
        lm = row[4:14].reshape(5, 2)
        face = align(im, lm)
        quality = people.quality_of(score, min(w, h), _sharpness(face), _frontal(lm))
        out.append({"box": (max(0.0, x / W), max(0.0, y / H), min(1.0, w / W), min(1.0, h / H)),
                    "score": score, "quality": quality, "emb": embed(face)})
        if len(out) >= MAX_FACES:
            break
    return out


def crop(path: str, box: tuple[float, float, float, float], size: int = 160, margin: float = 0.45):
    """A square picture of one face, with room round it — what the People window shows in its circles."""
    from PIL import Image
    im = open_upright(path, 1600)
    W, H = im.size
    x, y, w, h = box[0] * W, box[1] * H, box[2] * W, box[3] * H
    side = max(w, h) * (1 + 2 * margin)
    cx, cy = x + w / 2, y + h / 2 - h * 0.06
    left, top = cx - side / 2, cy - side / 2
    return im.crop((round(left), round(top), round(left + side), round(top + side))).resize(
        (size, size), Image.Resampling.LANCZOS)


def photos_under(folders: list[str], stop: Callable[[], bool] = lambda: False) -> list[str]:
    out: list[str] = []
    for folder in folders:
        if os.path.isfile(folder):
            if os.path.splitext(folder)[1].lower() in PHOTO_EXTS:
                out.append(folder)
            continue
        for root, dirs, files in os.walk(folder):
            if stop():
                return out
            dirs[:] = sorted(d for d in dirs if not d.startswith(".") and not d.endswith((".app", ".photoslibrary")))
            out += [os.path.join(root, n) for n in sorted(files)
                    if not n.startswith(".") and os.path.splitext(n)[1].lower() in PHOTO_EXTS]
    return out


def scan(store: "people.Store", folders: list[str], progress: Callable[[int, int, int], None] = lambda d, t, f: None,
         stop: Callable[[], bool] = lambda: False, workers: int | None = None) -> dict[str, int]:
    """Looks at every photo under `folders` that hasn't been looked at (as it is now, with these models) and
    records its faces. `progress(done, total, faces found)`. Returns {"photos", "faces", "failed", "skipped"}.
    Stopping loses nothing: each photo is recorded as it's done."""
    paths = photos_under(folders, stop)
    todo = []
    for p in paths:
        try:
            st = os.stat(p)
        except OSError:
            continue
        if not store.scanned(p, st.st_mtime, st.st_size, MODEL):
            todo.append((p, st.st_mtime, st.st_size))
    out = {"photos": 0, "faces": 0, "failed": 0, "skipped": len(paths) - len(todo)}
    if not todo:
        return out
    _session("detector")
    _session("recogniser")                       # (raises Missing before any thread starts)
    workers = workers or max(2, min(6, (os.cpu_count() or 4) - 2))

    def one(item):
        path, mtime, size = item
        if stop():
            return None
        try:
            return item, analyse(path)
        except Missing:
            raise
        except Exception:  # noqa: BLE001 — a file that isn't a picture after all: noted as having no faces
            return item, None

    with ThreadPoolExecutor(max_workers=workers) as pool:
        for i, result in enumerate(pool.map(one, todo)):
            if result is None:
                continue
            (path, mtime, size), found = result
            if found is None:
                out["failed"] += 1
                found = []
            store.add_file(path, mtime, size, found, MODEL)
            out["photos"] += 1
            out["faces"] += len(found)
            progress(i + 1, len(todo), out["faces"])
    return out
