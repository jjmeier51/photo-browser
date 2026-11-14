"""What Safe Finder's search understands, and the pieces that make it quick — no Qt here.

**The search field's language** (`tokens` splits it; `safe_finder.Query` gives each piece its meaning):

    gazebo sunset          every word must be in the name — or among the file's tags
    "route 66"             the words together, as written
    -blurry                not this word
    tag:beach  #beach      carries the tag (exactly; `tag:bea*` = starting with)
    is:favorite  is:ai     Favorites / To AI      is:tagged  is:untagged
    in:seligman            somewhere inside a folder whose name has this
    date:2020  date:2020-06  date:2020-06-20  date:today|yesterday|week|month|year
    before:2021  after:2020-06            (by the file's modified date)
    .heic  *.mov  ext:mp4,mov   kind:video   size:>100mb          (as before)

**Matching forgives how names are written** (`forms`, `has`): case and accents don't count ("cafe" finds
"Café"), a file's NFD name matches what was typed in NFC, and separators don't either — "img 1003" and "img1003"
both find "IMG_1003.jpg", "new york" finds "New-York".

**The names are kept for a couple of minutes** (`NameIndex`): a search walks its folders once, noting every
name; while that's fresh, the next search of the same place — a word added, a filter changed — filters the
names in memory instead of reading the drive again, which is what lets the results follow the typing. Only
names are kept (no sizes or dates: those are read for the files that match), a tree past LIMIT entries isn't
kept at all, and anything that changes files drops it (`forget`).
"""
from __future__ import annotations

import datetime as _dt
import threading
import time
import unicodedata

_SEPARATORS = str.maketrans({c: " " for c in "_-.()[]{}+,;~"})


def fold(text: str) -> str:
    """Lower case, accents off, one form whatever the Unicode composition."""
    if text.isascii():
        return text.lower()
    text = unicodedata.normalize("NFKD", text)
    return "".join(c for c in text if not unicodedata.combining(c)).casefold()


def forms(name: str) -> tuple[str, str, str]:
    """A name as it's matched: folded; with separators as spaces; and with nothing between its parts."""
    f = fold(name)
    spaced = " ".join(f.translate(_SEPARATORS).split())
    return f, spaced, spaced.replace(" ", "")


def has(term: str, name_forms: tuple[str, str, str]) -> bool:
    """Whether a folded search term is in a name (see `forms`)."""
    f, spaced, squeezed = name_forms
    if term in f or term in spaced:
        return True
    parts = term.translate(_SEPARATORS).split()
    if len(parts) > 1 and " ".join(parts) in spaced:           # "route-66" typed, "Route 66" on disk
        return True
    t = "".join(parts)
    return len(t) >= 3 and t in squeezed


def tokens(text: str) -> list[tuple[str, str, bool]]:
    """The search text as (key, value, negated) pieces: key "" for a plain word or "quoted phrase", else what
    came before the colon ("tag", "is", "size"…), lower case. Quotes keep spaces: `in:"new york"`."""
    out: list[tuple[str, str, bool]] = []
    i, n = 0, len(text)
    while i < n:
        if text[i].isspace():
            i += 1
            continue
        neg = False
        if text[i] == "-" and i + 1 < n and not text[i + 1].isspace():
            neg, i = True, i + 1
        key = ""
        j = i
        while j < n and (text[j].isalpha()):
            j += 1
        if j < n and text[j] == ":" and j > i and j + 1 < n and not text[j + 1].isspace():
            key, i = text[i:j].lower(), j + 1
        if i < n and text[i] in "\"“”":
            end = i + 1
            while end < n and text[end] not in "\"“”":
                end += 1
            value, i = text[i + 1:end], min(n, end + 1)
        else:
            end = i
            while end < n and not text[end].isspace():
                end += 1
            value, i = text[i:end], end
        if value.strip():
            out.append((key, value.strip(), neg))
    return out


def _day(d: _dt.date) -> float:
    return _dt.datetime(d.year, d.month, d.day).timestamp()


def date_range(spec: str, today: _dt.date | None = None) -> tuple[float, float] | None:
    """[start, end) in Unix time for "2020", "2020-06", "2020-06-20", "today", "yesterday", "week" (the last 7
    days), "month" (30), "year" (365). None for anything else."""
    today = today or _dt.date.today()
    s = spec.strip().lower()
    one = _dt.timedelta(days=1)
    if s in ("today", "yesterday"):
        d = today if s == "today" else today - one
        return _day(d), _day(d + one)
    if s in ("week", "month", "year"):
        days = {"week": 7, "month": 30, "year": 365}[s]
        return _day(today - _dt.timedelta(days=days - 1)), _day(today + one)
    parts = s.replace("/", "-").split("-")
    try:
        nums = [int(p) for p in parts]
    except ValueError:
        return None
    try:
        if len(nums) == 1 and 1900 <= nums[0] <= 2200:
            return _day(_dt.date(nums[0], 1, 1)), _day(_dt.date(nums[0] + 1, 1, 1))
        if len(nums) == 2:
            y, m = nums
            return _day(_dt.date(y, m, 1)), _day(_dt.date(y + (m == 12), m % 12 + 1, 1))
        if len(nums) == 3:
            d = _dt.date(*nums)
            return _day(d), _day(d + one)
    except (ValueError, OverflowError):
        return None
    return None


class NameIndex:
    """The names under a folder, as the last search's walk found them: `get(root)` → [(folder, is it the root,
    [folder names], [file names])] while fresh, else None."""

    TTL = 150.0
    LIMIT = 800_000

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._roots: dict[str, tuple[float, list]] = {}

    def get(self, root: str) -> list | None:
        with self._lock:
            hit = self._roots.get(root)
            if hit and time.monotonic() - hit[0] < self.TTL:
                return hit[1]
            self._roots.pop(root, None)
            return None

    def fresh(self, roots: list[str]) -> bool:
        return bool(roots) and all(self.get(r) is not None for r in roots)

    def put(self, root: str, listing: list, entries: int) -> None:
        if entries > self.LIMIT:
            return
        with self._lock:
            if len(self._roots) >= 6:                      # a handful of places at most
                oldest = min(self._roots, key=lambda k: self._roots[k][0])
                self._roots.pop(oldest, None)
            self._roots[root] = (time.monotonic(), listing)

    def forget(self) -> None:
        with self._lock:
            self._roots.clear()


NAMES = NameIndex()
