"""AI models — a person, a pet, an object or a style, made from 5–500 of your photos, to generate new pictures of.

**What a model is here.** Not a trained network (that needs a Mac with 32 GB or more — see `local_ai.py`), but
what every engine actually needs to draw a subject: a **curated set of its best, most varied photos**, kept under
a name. The engines use it in their own ways:

- **On this Mac** (`local_ai.py`: FLUX.2 klein 4B through mflux): the first few photos go in as reference images.
- **Seedream / Nano Banana** (Astria — `astria.py`, the Create with AI window): up to 10–14 of them go in as
  reference photos.
- **A trained model on Astria** (`astria.Client.create_tune`): the whole set is the training set of a Flux LoRA,
  which then appears among the tunes in Create / Edit with AI.

**Curating** (`curate`) is what turns "500 photos of her" into something that works. More photos stop helping a
single subject past a few dozen — what matters is that they're sharp, big enough, and *different from one
another*. So: unreadable, tiny and blurred photos are dropped; of near-identical shots (a burst) the sharpest is
kept; then the set is filled by always taking the photo least like those already taken (farthest-first), best
first. The order is kept: the first photos are the ones to use when an engine takes only a few.

A model is a folder in `~/Library/Application Support/Safe Finder/AI/Models/<name>/`: `model.json` and
`photos/001.jpg…` (copies — upright, sRGB, at most PHOTO_PX on the long side; the originals aren't touched or
needed again). Nothing here leaves the Mac; the engines that upload say so themselves.
"""
from __future__ import annotations

import io
import json
import os
import re
import shutil
import time
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

KINDS = {"person": "Person", "pet": "Pet", "object": "Object", "style": "Style"}
# The plain word for what the subject is — what prompts and a trained model's "class" call it.
DEFAULT_WORDS = {"person": "person", "pet": "dog", "object": "object", "style": "style"}
MIN_PHOTOS, MAX_PHOTOS = 5, 500
PHOTO_PX = 1536                      # long side of the kept copies
MIN_SIDE = 384                       # smaller than this on its short side: too little to learn from
# How many photos a model keeps, by kind (single subjects gain nothing past a few dozen; a style wants more).
TARGET = {"person": 30, "pet": 30, "object": 30, "style": 100}
NEAR_DUPLICATE_BITS = 6              # of 64: perceptual hashes this close are the same shot


def root() -> Path:
    return Path.home() / "Library" / "Application Support" / "Safe Finder" / "AI" / "Models"


def slug(name: str) -> str:
    """A folder name for a model's name."""
    s = unicodedata.normalize("NFC", name).strip()
    s = re.sub(r"[/\\:\x00-\x1f]", " ", s)
    s = re.sub(r"\s+", " ", s).strip(" .")
    return s[:80] or "Model"


# ----------------------------------------------------------------------------- looking at photos

@dataclass
class Candidate:
    path: str
    width: int = 0
    height: int = 0
    sharpness: float = 0.0           # variance of the Laplacian of a small grey copy: higher = crisper
    hash: int = 0                    # 64-bit difference hash
    look: tuple = ()                 # a small descriptor: what the photo looks like, for "how different is it"
    jpeg: bytes = b""                # the copy to keep

    @property
    def quality(self) -> float:
        """Sharp and big is good; neither counts for much beyond "enough"."""
        size = min(1.0, min(self.width, self.height) / 1024)
        return min(1.0, self.sharpness / 300.0) * 0.7 + size * 0.3


def _open_upright(path: str):
    """The photo as a Pillow image: upright, standard range, sRGB (as `astria.upload_jpeg` prepares one)."""
    from PIL import Image
    import astria
    data, _w, _h = astria.upload_jpeg(path, max_px=PHOTO_PX)
    im = Image.open(io.BytesIO(data))
    im.load()
    return im, data


def look_at(path: str) -> Candidate | None:
    """Everything curating needs to know about one photo — None when it can't be read as a picture."""
    import numpy as np
    try:
        im, data = _open_upright(path)
    except Exception:  # noqa: BLE001 — not a picture Pillow can read
        return None
    grey = im.convert("L")
    small = np.asarray(grey.resize((256, 256)), dtype=np.float32)
    lap = (-4 * small[1:-1, 1:-1] + small[:-2, 1:-1] + small[2:, 1:-1] + small[1:-1, :-2] + small[1:-1, 2:])
    d = np.asarray(grey.resize((9, 8)), dtype=np.int16)
    bits = (d[:, 1:] > d[:, :-1]).flatten()
    h = 0
    for b in bits:
        h = (h << 1) | int(b)
    tiny = np.asarray(im.convert("RGB").resize((8, 8)), dtype=np.float32).flatten() / 255.0
    return Candidate(path, im.width, im.height, float(lap.var()), h, tuple(float(v) for v in tiny), data)


def _distance(a: tuple, b: tuple) -> float:
    return sum((x - y) * (x - y) for x, y in zip(a, b)) ** 0.5


@dataclass
class Curated:
    picked: list[Candidate] = field(default_factory=list)          # in the order to use them
    dropped: list[tuple[str, str]] = field(default_factory=list)   # (path, why)
    seen: int = 0


def curate(paths: list[str], kind: str = "person",
           progress: Callable[[int, int, str], None] = lambda done, total, name: None,
           stop: Callable[[], bool] = lambda: False, target: int | None = None) -> Curated:
    """The best varied set from `paths` (see the module doc). Reads every photo once; nothing is written."""
    out = Curated()
    want = target or TARGET.get(kind, 30)
    paths = list(dict.fromkeys(paths))[:MAX_PHOTOS]
    good: list[Candidate] = []
    for i, path in enumerate(paths):
        if stop():
            return out
        progress(i, len(paths), os.path.basename(path))
        out.seen += 1
        c = look_at(path)
        if c is None:
            out.dropped.append((path, "couldn't be read as a picture"))
        elif min(c.width, c.height) < MIN_SIDE:
            out.dropped.append((path, f"too small ({c.width}×{c.height})"))
        else:
            good.append(c)
    progress(len(paths), len(paths), "")
    # Blur is judged against the set itself (a soft-focus shoot isn't all "blurred"): well under the middle one.
    if len(good) >= 8:
        middle = sorted(c.sharpness for c in good)[len(good) // 2]
        floor = middle * 0.25
        keep = [c for c in good if c.sharpness >= floor]
        if len(keep) >= MIN_PHOTOS:
            out.dropped += [(c.path, "blurred") for c in good if c.sharpness < floor]
            good = keep
    # Near-identical shots: the sharpest of each stays.
    good.sort(key=lambda c: c.quality, reverse=True)
    unique: list[Candidate] = []
    for c in good:
        twin = next((u for u in unique if bin(u.hash ^ c.hash).count("1") <= NEAR_DUPLICATE_BITS), None)
        if twin is None:
            unique.append(c)
        else:
            out.dropped.append((c.path, f"nearly the same as {os.path.basename(twin.path)}"))
    if not unique:
        return out
    # Farthest-first: the best photo, then always the one least like any taken so far (quality breaks ties and
    # tempers the choice, so a poor odd-one-out doesn't jump the queue).
    picked = [unique[0]]
    rest = unique[1:]
    nearest = {id(c): _distance(c.look, picked[0].look) for c in rest}
    while rest and len(picked) < want:
        best = max(rest, key=lambda c: nearest[id(c)] * (0.6 + 0.4 * c.quality))
        picked.append(best)
        rest.remove(best)
        for c in rest:
            nearest[id(c)] = min(nearest[id(c)], _distance(c.look, best.look))
    out.dropped += [(c.path, "more than the model needs (others like it were kept)") for c in rest]
    out.picked = picked
    return out


# ----------------------------------------------------------------------------- the models kept

@dataclass
class Model:
    folder: Path
    name: str
    kind: str = "person"
    word: str = "person"             # what it is, in a prompt: "woman", "golden retriever", "ceramic mug"
    created: float = 0.0
    photos: list[str] = field(default_factory=list)       # file names in photos/, in the order to use them
    sources: list[str] = field(default_factory=list)      # where each came from (for the record only)
    consent: bool = False            # a real person: the maker said they have the person's consent
    astria_tune: int | None = None   # the Flux LoRA trained on Astria from this set, if any
    astria_token: str = ""
    seen: int = 0                    # how many photos were offered

    def photo_paths(self, limit: int | None = None) -> list[str]:
        paths = [str(self.folder / "photos" / p) for p in self.photos]
        paths = [p for p in paths if os.path.isfile(p)]
        return paths[:limit] if limit else paths

    @property
    def cover(self) -> str | None:
        paths = self.photo_paths(1)
        return paths[0] if paths else None

    @property
    def subject(self) -> str:
        """How a prompt refers to it when photos stand in for it: "the woman in the reference photos"."""
        if self.kind == "style":
            return "the style of the reference pictures"
        return f"the {self.word} in the reference photos"

    def save(self) -> None:
        doc = {"format": "safe-finder-ai-model", "version": 1, "name": self.name, "kind": self.kind, "word": self.word,
               "created": self.created, "photos": self.photos, "sources": self.sources, "consent": self.consent,
               "astria_tune": self.astria_tune, "astria_token": self.astria_token, "seen": self.seen}
        tmp = self.folder / ".model.json.saving"
        tmp.write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")
        os.replace(tmp, self.folder / "model.json")


def load(folder: Path) -> Model | None:
    try:
        d = json.loads((folder / "model.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(d, dict) or d.get("format") != "safe-finder-ai-model":
        return None
    tune = d.get("astria_tune")
    return Model(folder, str(d.get("name") or folder.name), d.get("kind") if d.get("kind") in KINDS else "person",
                 str(d.get("word") or "person"), float(d.get("created") or 0),
                 [str(p) for p in d.get("photos") or [] if isinstance(p, str) and "/" not in p],
                 [str(p) for p in d.get("sources") or []], bool(d.get("consent")),
                 int(tune) if isinstance(tune, int) and not isinstance(tune, bool) else None,
                 str(d.get("astria_token") or ""), int(d.get("seen") or 0))


def all_models() -> list[Model]:
    base = root()
    out: list[Model] = []
    try:
        folders = sorted(p for p in base.iterdir() if p.is_dir() and not p.name.startswith("."))
    except OSError:
        return out
    for f in folders:
        m = load(f)
        if m is not None:
            out.append(m)
    return sorted(out, key=lambda m: m.name.casefold())


def name_free(name: str) -> bool:
    return not (root() / slug(name)).exists()


def create(name: str, kind: str, word: str, curated: Curated, consent: bool = False) -> Model:
    """Keeps the curated photos as a new model. Raises FileExistsError when the name is taken, ValueError when
    there are too few photos."""
    if len(curated.picked) < MIN_PHOTOS:
        raise ValueError(f"A model needs at least {MIN_PHOTOS} usable photos; {len(curated.picked)} were.")
    folder = root() / slug(name)
    if folder.exists():
        raise FileExistsError(str(folder))
    building = folder.with_name("." + folder.name + ".making")
    shutil.rmtree(building, ignore_errors=True)
    (building / "photos").mkdir(parents=True)
    names: list[str] = []
    for i, c in enumerate(curated.picked, 1):
        fname = f"{i:03d}.jpg"
        (building / "photos" / fname).write_bytes(c.jpeg)
        names.append(fname)
    model = Model(building, name.strip() or folder.name, kind if kind in KINDS else "person",
                  (word or DEFAULT_WORDS.get(kind, "subject")).strip(), time.time(), names,
                  [c.path for c in curated.picked], bool(consent), None, "", curated.seen)
    model.save()
    os.replace(building, folder)                 # whole, or not there at all
    model.folder = folder
    return model


def token_for(name: str) -> str:
    """A made-up word for a trained model to know the subject by — rare enough to mean nothing else."""
    letters = re.sub(r"[^a-z]", "", unicodedata.normalize("NFKD", name).lower())[:4] or "sbj"
    return "ohwx" + letters
