#!/usr/bin/env python3
"""Read how folders are *really* stored on the exFAT SSD — to find what iOS refuses to open.

Some folders open fine on the Mac but fail on the iPhone/iPad with "opendir errno 22 (Invalid
argument)", even after a clean `fsck_exfat`, and rebuilding them (a fresh copy) fixes them. macOS's
exFAT driver is lenient, and what it shows (`os.listdir`) is already translated, so a Mac-side look
can't see the problem. This script reads the folder's directory entries straight off the disk and
checks every field the exFAT specification defines: entry-set checksums, name hashes, entry counts,
names (forbidden / invalid UTF-16 / private-use characters), timestamps and UTC offsets, attributes,
reserved bytes, sizes and cluster chains — plus layout facts (deleted entries, fragmentation, entry
sets split across clusters). It compares the failing folders against healthy ones, so whatever
separates them shows up as "in (nearly) every failing folder, (nearly) no healthy one".

Read-only: it opens the disk device for reading and never writes. Run it BEFORE rebuilding a
folder — a rebuild rewrites the entries and erases the evidence.

Usage (needs sudo to read the disk device):
  sudo python3 mac/exfat_inspect.py "/Volumes/Extreme SSD/Kardashians/Kylie Jenner"
  sudo python3 mac/exfat_inspect.py --list unreadable.txt --root "/Volumes/Extreme SSD"
  (unreadable.txt = the list Drive Health's Share button exports)
For a disk image: python3 exfat_inspect.py --device image.img "Folder/Sub"
"""

from __future__ import annotations

import argparse
import os
import random
import struct
import subprocess
import sys
import unicodedata
from collections import Counter, defaultdict, deque

FORBIDDEN = set('"*/:<>?\\|')
MAX_DIR_BYTES = 256 * 1024 * 1024

HELP = {
    "checksum": "entry-set checksum doesn't match the entries (a strict driver rejects the set)",
    "name-hash": "NameHash doesn't match the name",
    "secondary-count": "SecondaryCount out of range or too small for the name",
    "stale-name-entries": "more name entries than the name needs (left over from a rename to a shorter name)",
    "vendor-entries": "vendor-specific extra entries in a file's entry set",
    "set-broken": "an entry set is cut short by a deleted / wrong-type entry or the end of the folder",
    "orphan-secondary": "in-use secondary entry with no file entry in front of it",
    "unknown-critical": "an entry type this exFAT version doesn't define, marked critical",
    "after-end": "in-use entries after the end-of-directory marker",
    "name-forbidden": "characters exFAT forbids in names (\" * / : < > ? \\ | or control characters)",
    "name-invalid-utf16": "invalid UTF-16 in a name (unpaired surrogate or U+FFFE/U+FFFF)",
    "name-private-use": "private-use characters (how macOS stores : / * ? etc.)",
    "name-garbage": "non-zero characters after the end of a name",
    "name-flags": "a name entry's flags byte isn't zero",
    "name-length": "name length is zero",
    "duplicate-name": "two items whose names are equal ignoring case",
    "attributes": "reserved attribute bits set",
    "reserved-fields": "reserved bytes that should be zero aren't",
    "timestamp": "an impossible date/time (month 0/13, day 0, 25:61…) in a file entry",
    "timestamp-zero": "an all-zero (never set) timestamp",
    "utc-offset": "invalid UTC-offset byte",
    "ms-increment": "10-millisecond field above 199",
    "valid-length": "ValidDataLength larger than DataLength (or different, for a folder)",
    "alloc-flags": "allocation flags don't match the item's size / first cluster",
    "cluster-range": "first cluster outside the drive",
    "cluster-free": "an item's first cluster is marked free in the allocation bitmap",
    "dir-length": "a folder whose size isn't a whole number of clusters, is zero, or tops 256 MB",
    "chain": "the folder's own cluster chain is broken (loop, ends early, free or bad cluster)",
    "split-set": "an entry set spans two clusters (allowed; a classic driver-bug spot)",
    "split-set-fragmented": "an entry set spans two clusters that aren't next to each other on disk",
    "fragmented": "the folder's directory data is in more than one piece on disk",
    "churn": "more deleted entries than live ones (many files removed/renamed in place)",
    "large": "more than 10,000 items",
    "no-fat-chain-dir": "the folder's data is marked contiguous (NoFatChain) and spans several clusters",
}
INFO_ONLY = {"split-set", "fragmented", "churn", "large", "no-fat-chain-dir", "vendor-entries"}


def is_info(kind: str) -> bool:
    return kind.split(":")[-1] in INFO_ONLY


def u16(b: bytes, o: int) -> int:
    return struct.unpack_from("<H", b, o)[0]


def u32(b: bytes, o: int) -> int:
    return struct.unpack_from("<I", b, o)[0]


def u64(b: bytes, o: int) -> int:
    return struct.unpack_from("<Q", b, o)[0]


def set_checksum(raw: bytes) -> int:
    c = 0
    for i, byte in enumerate(raw):
        if i in (2, 3):
            continue
        c = (((c & 1) << 15) | (c >> 1)) + byte
        c &= 0xFFFF
    return c


def name_hash(units: list[int], upcase: list[int]) -> int:
    h = 0
    for u in units:
        c = upcase[u]
        for byte in (c & 0xFF, c >> 8):
            h = ((((h & 1) << 15) | (h >> 1)) + byte) & 0xFFFF
    return h


def table_checksum(raw: bytes) -> int:
    c = 0
    for byte in raw:
        c = ((((c & 1) << 31) | (c >> 1)) + byte) & 0xFFFFFFFF
    return c


def printable(name: str) -> str:
    """The name with invisible, private-use and broken characters shown as \\uXXXX."""
    return "".join(c if c.isprintable() and not 0xE000 <= ord(c) <= 0xF8FF else f"\\u{ord(c):04x}" for c in name)


def decode_units(units: list[int]) -> str:
    return struct.pack(f"<{len(units)}H", *units).decode("utf-16-le", "surrogatepass")


def timestamp_problem(ts: int) -> str | None:
    if ts == 0:
        return "zero"
    sec2, minute, hour = ts & 0x1F, (ts >> 5) & 0x3F, (ts >> 11) & 0x1F
    day, month, year = (ts >> 16) & 0x1F, (ts >> 21) & 0x0F, 1980 + (ts >> 25)
    if not (1 <= month <= 12) or day < 1 or hour > 23 or minute > 59 or sec2 > 29:
        return f"{year}-{month:02}-{day:02} {hour:02}:{minute:02}:{sec2 * 2:02}"
    mdays = [31, 29 if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) else 28,
             31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    if day > mdays:
        return f"{year}-{month:02}-{day:02}"
    return None


class Volume:
    """Read-only access to an exFAT volume on a device or image file."""

    ALIGN = 4096

    def __init__(self, device: str):
        self.fd = os.open(device, os.O_RDONLY)
        boot = self._read(0, 512)
        if boot[3:11] != b"EXFAT   ":
            raise SystemExit(f"{device} isn't an exFAT volume")
        self.bps = 1 << boot[108]
        self.cluster_size = self.bps << boot[109]
        self.fat_offset = u32(boot, 80) * self.bps
        self.heap_offset = u32(boot, 88) * self.bps
        self.cluster_count = u32(boot, 92)
        self.root_cluster = u32(boot, 96)
        self.volume_flags = u16(boot, 106)
        self.revision = u16(boot, 104)
        self._fat_cache: dict[int, bytes] = {}
        self.bitmap: bytes | None = None
        self.upcase: list[int] = list(range(0x10000))
        self.notes: list[str] = []
        self._load_root_metadata()

    def _read(self, off: int, n: int) -> bytes:
        start = off - off % self.ALIGN
        end = off + n
        end += (-end) % self.ALIGN
        data = os.pread(self.fd, end - start, start)
        return data[off - start: off - start + n]

    def valid_cluster(self, c: int) -> bool:
        return 2 <= c <= self.cluster_count + 1

    def read_cluster(self, c: int) -> bytes:
        return self._read(self.heap_offset + (c - 2) * self.cluster_size, self.cluster_size)

    def fat(self, c: int) -> int:
        off = self.fat_offset + 4 * c
        chunk = off // 65536
        data = self._fat_cache.get(chunk)
        if data is None:
            if len(self._fat_cache) > 512:
                self._fat_cache.clear()
            data = self._read(chunk * 65536, 65536)
            self._fat_cache[chunk] = data
        return u32(data, off % 65536)

    def allocated(self, c: int) -> bool | None:
        if self.bitmap is None or not self.valid_cluster(c):
            return None
        i = c - 2
        return bool(self.bitmap[i // 8] >> (i % 8) & 1)

    def chain(self, first: int, length: int | None, no_fat_chain: bool) -> tuple[list[int], list[str]]:
        """Clusters holding `length` bytes from `first` (None = follow the FAT to its end)."""
        problems: list[str] = []
        if not self.valid_cluster(first):
            return [], [f"first cluster {first} is outside the drive"]
        need = None if length is None else max(1, -(-length // self.cluster_size))
        if no_fat_chain and need is not None:
            clusters = list(range(first, first + need))
            if not self.valid_cluster(clusters[-1]):
                problems.append("contiguous run goes past the end of the drive")
                clusters = [c for c in clusters if self.valid_cluster(c)]
        else:
            clusters, seen, c = [], set(), first
            limit = need if need is not None else 4_000_000
            while True:
                if c in seen:
                    problems.append(f"cluster chain loops back to {c}")
                    break
                if not self.valid_cluster(c):
                    problems.append(f"cluster chain points outside the drive ({c:#x})")
                    break
                seen.add(c)
                clusters.append(c)
                if len(clusters) >= limit:
                    if need is not None and self.fat(c) != 0xFFFFFFFF:
                        problems.append("cluster chain continues past the folder's size")
                    break
                nxt = self.fat(c)
                if nxt == 0xFFFFFFFF:
                    break
                if nxt == 0xFFFFFFF7:
                    problems.append(f"cluster chain hits a bad-cluster marker after {c}")
                    break
                if nxt == 0:
                    problems.append(f"cluster chain hits a free FAT entry after {c}")
                    break
                c = nxt
            if need is not None and len(clusters) < need and not problems:
                problems.append(f"cluster chain ends after {len(clusters)} of {need} clusters")
        free = [c for c in clusters if self.allocated(c) is False]
        if free:
            problems.append(f"{len(free)} of the folder's clusters are marked free in the allocation bitmap")
        return clusters, problems

    def read_clusters(self, clusters: list[int], length: int | None) -> bytes:
        out = bytearray()
        run_start, prev = None, None
        for c in clusters + [None]:
            if c is not None and prev is not None and c == prev + 1:
                prev = c
                continue
            if run_start is not None:
                n = prev - run_start + 1
                out += self._read(self.heap_offset + (run_start - 2) * self.cluster_size, n * self.cluster_size)
            run_start = prev = c
        return bytes(out if length is None else out[:length])

    def _load_root_metadata(self) -> None:
        clusters, problems = self.chain(self.root_cluster, None, False)
        for p in problems:
            self.notes.append(f"root folder: {p}")
        data = self.read_clusters(clusters, None)
        for i in range(0, len(data), 32):
            t = data[i]
            if t == 0:
                break
            e = data[i:i + 32]
            if t == 0x81 and self.bitmap is None:
                first, length = u32(e, 20), u64(e, 24)
                cl, _ = self.chain(first, length, False)
                self.bitmap = self.read_clusters(cl, length)
            elif t == 0x82:
                first, length, want = u32(e, 20), u64(e, 24), u32(e, 4)
                cl, _ = self.chain(first, length, False)
                raw = self.read_clusters(cl, length)
                if table_checksum(raw) != want:
                    self.notes.append("the up-case table's checksum doesn't match")
                units = list(struct.unpack(f"<{len(raw) // 2}H", raw[: len(raw) // 2 * 2]))
                table, idx, j = list(range(0x10000)), 0, 0
                while j < len(units) and idx < 0x10000:
                    if units[j] == 0xFFFF and j + 1 < len(units):
                        idx += units[j + 1]
                        j += 2
                    else:
                        table[idx] = units[j]
                        idx += 1
                        j += 1
                self.upcase = table


class Item:
    __slots__ = ("name", "is_dir", "first", "length", "no_fat_chain", "index")

    def __init__(self, name, is_dir, first, length, no_fat_chain, index):
        self.name, self.is_dir, self.first = name, is_dir, first
        self.length, self.no_fat_chain, self.index = length, no_fat_chain, index


class Report:
    def __init__(self, label: str):
        self.label = label
        self.found: dict[str, list[str]] = defaultdict(list)
        self.items: list[Item] = []
        self.live = self.deleted = self.extents = self.clusters = 0
        self.size = 0
        self.unreadable: str | None = None
        self.by_name: dict[str, list[str]] = {}     # item name → problems in its own entry set

    def add(self, kind: str, example: str) -> None:
        self.found[kind].append(example)


def parse_directory(vol: Volume, first: int, length: int, no_fat_chain: bool, label: str) -> Report:
    r = Report(label)
    clusters, problems = vol.chain(first, length, no_fat_chain)
    for p in problems:
        r.add("chain", p)
    if not clusters:
        r.unreadable = "no clusters"
        return r
    r.clusters = len(clusters)
    r.extents = 1 + sum(1 for a, b in zip(clusters, clusters[1:]) if b != a + 1)
    if r.extents > 1:
        r.add("fragmented", f"{r.extents} pieces")
    if no_fat_chain and len(clusters) > 1:
        r.add("no-fat-chain-dir", f"{len(clusters)} clusters")
    data = vol.read_clusters(clusters, length)
    r.size = len(data)
    n = len(data) // 32
    per_cluster = vol.cluster_size // 32
    names: dict[tuple, list[str]] = defaultdict(list)
    i = 0
    while i < n:
        e = data[i * 32:(i + 1) * 32]
        t = e[0]
        if t == 0x00:
            after = [j for j in range(i + 1, n) if data[j * 32] & 0x80]
            if after:
                r.add("after-end", f"{len(after)} in-use entries after the end marker at #{i}")
            break
        if not t & 0x80:
            if t == 0x05:                                # a deleted file's primary entry
                r.deleted += 1
            i += 1
            continue
        if t in (0x81, 0x82, 0x83, 0xA0, 0xA1):      # root-only system entries
            i += 1
            continue
        if t & 0x40:
            r.add("orphan-secondary", f"type {t:#04x} at #{i}")
            i += 1
            continue
        if t != 0x85:
            sc = e[1]
            if not t & 0x20:
                r.add("unknown-critical", f"type {t:#04x} at #{i}")
            i += 1 + sc
            continue

        sc = e[1]
        where = f"#{i}"
        if not 2 <= sc <= 18:
            r.add("secondary-count", f"SecondaryCount {sc} at {where}")
            i += 1
            continue
        if i + sc >= n:
            r.add("set-broken", f"entry set at {where} runs past the end of the folder")
            break
        raw = data[i * 32:(i + 1 + sc) * 32]
        types = [raw[k * 32] for k in range(1, sc + 1)]
        if types[0] != 0xC0:
            r.add("set-broken", f"entry after the file entry at {where} is {types[0]:#04x}, not a stream extension")
            i += 1
            continue
        s = raw[32:64]
        name_len = s[3]
        need = -(-name_len // 15)
        name_types = types[1:1 + need]
        if len(name_types) < need or any(t2 != 0xC1 for t2 in name_types):
            r.add("set-broken" if any(not t2 & 0x80 for t2 in name_types) else "secondary-count",
                  f"name at {where} needs {need} name entries, set has types {[hex(x) for x in types[1:]]}")
            i += 1 + sc
            continue
        units: list[int] = []
        for k in range(need):
            ne = raw[(2 + k) * 32:(3 + k) * 32]
            if ne[1] != 0:
                r.add("name-flags", where)
            units += struct.unpack("<15H", ne[2:32])
        name_units, tail = units[:name_len], units[name_len:]
        name = decode_units(name_units)
        shown = printable(name)
        mine: list[str] = []

        def flag(kind: str, example: str) -> None:
            r.add(kind, example)
            if not kind.startswith("split-set"):
                mine.append(kind)

        if name_len == 0:
            flag("name-length", where)
        if any(tail):
            flag("name-garbage", shown)
        extra = types[1 + need:]
        if extra:
            if all(t2 == 0xC1 for t2 in extra):
                flag("stale-name-entries", f"{shown} (+{len(extra)})")
            elif all(t2 in (0xE0, 0xE1) for t2 in extra):
                flag("vendor-entries", shown)
            elif any(not t2 & 0x80 for t2 in extra):
                flag("set-broken", f"{shown}: deleted entry inside its set")
            elif any(not t2 & 0x20 for t2 in extra):
                flag("unknown-critical", f"{shown}: secondary types {[hex(x) for x in extra]}")
        if set_checksum(raw) != u16(raw, 2):
            flag("checksum", shown)
        if name_hash(name_units, vol.upcase) != u16(s, 4):
            flag("name-hash", shown)
        bad_utf16 = False
        for k, u in enumerate(name_units):
            if 0xD800 <= u <= 0xDBFF:
                if k + 1 >= len(name_units) or not 0xDC00 <= name_units[k + 1] <= 0xDFFF:
                    bad_utf16 = True
            elif 0xDC00 <= u <= 0xDFFF:
                if k == 0 or not 0xD800 <= name_units[k - 1] <= 0xDBFF:
                    bad_utf16 = True
            elif u in (0xFFFE, 0xFFFF):
                bad_utf16 = True
        if bad_utf16:
            flag("name-invalid-utf16", shown)
        if any(u < 0x20 or (u < 0x80 and chr(u) in FORBIDDEN) for u in name_units):
            flag("name-forbidden", shown)
        if any(0xE000 <= u <= 0xF8FF for u in name_units):
            flag("name-private-use", shown)

        attrs = u16(e, 4)
        is_dir = bool(attrs & 0x10)
        if attrs & 0xFFC8:
            flag("attributes", f"{shown} ({attrs:#06x})")
        if u16(e, 6) or any(e[25:32]) or s[2] or u16(s, 6) or u32(s, 16):
            flag("reserved-fields", shown)
        for label_, off in (("created", 8), ("modified", 12), ("accessed", 16)):
            p = timestamp_problem(u32(e, off))
            if p == "zero":
                flag("timestamp-zero", f"{shown} ({label_})")
            elif p:
                flag("timestamp", f"{shown} ({label_} {p})")
        if e[20] > 199 or e[21] > 199:
            flag("ms-increment", shown)
        for off in (22, 23, 24):
            b = e[off]
            if b & 0x80:
                v = b & 0x7F
                v = v - 0x80 if v & 0x40 else v
                if not -48 <= v <= 56:
                    flag("utc-offset", shown)
            elif b:
                flag("utc-offset", shown)

        flags = s[1]
        alloc_possible, nfc = bool(flags & 1), bool(flags & 2)
        vdl, first_c, dlen = u64(s, 8), u32(s, 20), u64(s, 24)
        if vdl > dlen or (is_dir and vdl != dlen):
            flag("valid-length", f"{shown} (valid {vdl}, size {dlen})")
        if (not alloc_possible and (first_c or dlen)) or (dlen == 0 and first_c != 0) or (dlen and first_c == 0):
            flag("alloc-flags", f"{shown} (flags {flags:#x}, first {first_c}, size {dlen})")
        if dlen and first_c and not vol.valid_cluster(first_c):
            flag("cluster-range", f"{shown} ({first_c:#x})")
        elif dlen and first_c and vol.allocated(first_c) is False:
            flag("cluster-free", shown)
        if is_dir and (dlen == 0 or dlen % vol.cluster_size or dlen > MAX_DIR_BYTES):
            flag("dir-length", f"{shown} ({dlen} bytes)")
        if (i // per_cluster) != ((i + sc) // per_cluster):
            flag("split-set", shown)
            a = clusters[i // per_cluster] if i // per_cluster < len(clusters) else None
            b = clusters[(i + sc) // per_cluster] if (i + sc) // per_cluster < len(clusters) else None
            if a is not None and b is not None and b != a + 1:
                flag("split-set-fragmented", shown)
        key = tuple(vol.upcase[u] for u in name_units)
        names[key].append(shown)
        r.items.append(Item(name, is_dir, first_c, dlen, nfc, i))
        r.by_name[norm(name)] = mine
        r.live += 1
        i += 1 + sc
    for group in names.values():
        if len(group) > 1:
            r.add("duplicate-name", " = ".join(group[:3]))
    if r.deleted > r.live and r.deleted > 20:
        r.add("churn", f"{r.deleted} deleted vs {r.live} live")
    if r.live > 10_000:
        r.add("large", f"{r.live} items")
    return r


def norm(s: str) -> str:
    return unicodedata.normalize("NFC", s).casefold()


def resolve(vol: Volume, rel: str) -> tuple[Report | None, str]:
    """Walk `rel` (volume-relative, "/"-separated) from the root; inspect the final folder."""
    parts = [p for p in rel.strip("/").split("/") if p]
    first, length, nfc = vol.root_cluster, None, False
    for depth, part in enumerate(parts):
        here = parse_directory(vol, first, length, nfc, "/".join(parts[:depth])) if length is not None \
            else root_report(vol)
        want = norm(part)
        match = [it for it in here.items if norm(it.name) == want]
        if not match:
            return None, f"“{part}” not found on the disk under /{'/'.join(parts[:depth])}"
        it = match[0]
        if not it.is_dir:
            return None, f"“{part}” is a file, not a folder"
        first, length, nfc = it.first, it.length, it.no_fat_chain
        own = here.by_name.get(norm(it.name), [])
    if length is None:
        return root_report(vol), ""
    rep = parse_directory(vol, first, length, nfc, rel)
    add_own(rep, own)
    return rep, ""


def add_own(rep: Report, own: list[str]) -> None:
    """Problems in the folder's own entry, in its parent — they can stop it opening too."""
    for k in own:
        rep.add(f"own-entry:{k}", "this folder's entry in its parent")


_root_cache: Report | None = None


def root_report(vol: Volume) -> Report:
    global _root_cache
    if _root_cache is None:
        clusters, _ = vol.chain(vol.root_cluster, None, False)
        _root_cache = parse_directory(vol, vol.root_cluster, len(clusters) * vol.cluster_size, False, "(drive root)")
    return _root_cache


def healthy_sample(vol: Volume, skip: set[str], want: int) -> list[Report]:
    """Breadth-first over the drive's folders (dot-folders skipped), excluding the failing ones."""
    out: list[Report] = []
    root = root_report(vol)
    queue = deque(("", it, root.by_name.get(norm(it.name), [])) for it in root.items if it.is_dir)
    seen = 0
    while queue and len(out) < want * 3 and seen < 20_000:
        parent, it, own = queue.popleft()
        seen += 1
        if it.name.startswith("."):
            continue
        rel = f"{parent}/{it.name}".strip("/")
        rep = parse_directory(vol, it.first, it.length, it.no_fat_chain, rel)
        if norm(rel) not in skip:
            add_own(rep, own)
            out.append(rep)
        queue.extend((rel, c, rep.by_name.get(norm(c.name), [])) for c in rep.items if c.is_dir)
    random.seed(1)
    return random.sample(out, min(want, len(out)))


def device_for(path: str) -> tuple[str, str]:
    """(raw device, mount point) of the volume holding `path` (macOS `df`)."""
    out = subprocess.run(["df", "-P", path], capture_output=True, text=True, check=True).stdout.splitlines()
    fields = out[1].split(None, 5)
    dev, mount = fields[0], fields[5]
    if dev.startswith("/dev/disk"):
        dev = "/dev/rdisk" + dev[len("/dev/disk"):]
    return dev, mount


def describe(kind: str) -> str:
    if kind.startswith("own-entry:"):
        return "the folder's own entry in its parent: " + HELP.get(kind[len("own-entry:"):], "")
    return HELP.get(kind, "")


def print_report(r: Report) -> None:
    print(f"\n{r.label or '(drive root)'}  — {r.live} items, {r.deleted} deleted, "
          f"{r.size // 1024} KB in {r.clusters} cluster(s), {r.extents} piece(s)")
    if r.unreadable:
        print(f"   can't read: {r.unreadable}")
    if not r.found:
        print("   (no problems)")
    for kind in sorted(r.found, key=lambda k: (is_info(k), k)):
        ex = r.found[kind]
        more = f" (+{len(ex) - 3} more)" if len(ex) > 3 else ""
        tag = "info " if is_info(kind) else "PROBLEM"
        print(f"   {tag:7} {kind:22} {len(ex):6}  e.g. {'; '.join(ex[:3])}{more}")


def main() -> None:
    ap = argparse.ArgumentParser(description="Inspect exFAT folders on disk (read-only).")
    ap.add_argument("folders", nargs="*", help="folders on the SSD (or volume-relative paths with --device)")
    ap.add_argument("--list", help="Drive Health's exported unreadable-folder list (drive-relative paths)")
    ap.add_argument("--root", help='the SSD for --list, e.g. "/Volumes/Extreme SSD"')
    ap.add_argument("--device", help="read this device / image instead of the one df reports")
    ap.add_argument("--sample", type=int, default=150, help="healthy folders to compare against (default 150)")
    args = ap.parse_args()

    rels: list[str] = []
    mount = None
    device = args.device
    if args.list:
        if not args.root:
            sys.exit("--list needs --root")
        with open(args.list, encoding="utf-8") as f:
            rels += [l.strip().strip("/") for l in f if l.strip()]
        if not device:
            device, mount = device_for(args.root)
    for p in args.folders:
        if args.device:
            rels.append(p.strip("/"))
            continue
        ap_ = os.path.abspath(p)
        dev, mnt = device_for(ap_)
        if device and device != dev:
            sys.exit(f"{p} is on a different drive than the other folders")
        device, mount = dev, mnt
        rel = os.path.relpath(ap_, mnt).replace(os.sep, "/")
        rels.append("" if rel == "." else rel)
    if not rels:
        ap.print_help()
        return
    if not device:
        sys.exit("Couldn't work out which disk to read")
    os.sync()
    try:
        vol = Volume(device)
    except PermissionError:
        sys.exit(f"Can't read {device} — run with sudo (and if macOS still refuses, give Terminal "
                 "Full Disk Access in System Settings ▸ Privacy & Security).")
    print(f"Volume {device}" + (f" ({mount})" if mount else "")
          + f": cluster {vol.cluster_size // 1024} KB, {vol.cluster_count} clusters, revision "
          f"{vol.revision >> 8}.{vol.revision & 0xFF}"
          + (", marked DIRTY (not cleanly ejected)" if vol.volume_flags & 2 else ""))
    for n in vol.notes:
        print(f"  note: {n}")

    print(f"\n== Folders to check ({len(rels)}) ==")
    bad: list[Report] = []
    for rel in rels:
        rep, why = resolve(vol, rel)
        if rep is None:
            print(f"\n{rel}: {why}")
            continue
        print_report(rep)
        bad.append(rep)
    if not bad or args.sample <= 0:
        return

    print(f"\n== Comparing with up to {args.sample} other folders on the drive… ==")
    good = healthy_sample(vol, {norm(r.label) for r in bad}, args.sample)
    good_flags = Counter(k for r in good for k in r.found)
    bad_flags = Counter(k for r in bad for k in r.found)
    nb, ng = len(bad), max(1, len(good))
    print(f"{'finding':24} {'checked':>8} {'others':>8}")
    rows = sorted(set(bad_flags) | set(good_flags), key=lambda k: -(bad_flags[k] / nb - good_flags[k] / ng))
    for k in rows:
        print(f"{k:24} {100 * bad_flags[k] / nb:7.0f}% {100 * good_flags[k] / ng:7.0f}%   {describe(k)}")
    avg = lambda rs, f: sum(f(r) for r in rs) / max(1, len(rs))
    print(f"\n{'':24} {'checked':>8} {'others':>8}")
    print(f"{'avg items':24} {avg(bad, lambda r: r.live):8.0f} {avg(good, lambda r: r.live):8.0f}")
    print(f"{'avg deleted items':24} {avg(bad, lambda r: r.deleted):8.0f} {avg(good, lambda r: r.deleted):8.0f}")
    print(f"{'avg pieces on disk':24} {avg(bad, lambda r: r.extents):8.1f} {avg(good, lambda r: r.extents):8.1f}")
    suspects = [k for k in rows if bad_flags[k] / nb >= 0.6 and good_flags[k] / ng <= 0.15]
    rare = [k for k in rows if k not in suspects and not is_info(k) and bad_flags[k] and good_flags[k] / ng <= 0.15]
    print()
    if suspects:
        print("Likely trigger(s): " + ", ".join(suspects))
    if rare:
        print("Problems in some checked folders that the others hardly have: "
              + ", ".join(f"{k} ({bad_flags[k]} of {nb})" for k in rare))
    if not suspects and not rare:
        if any(not is_info(k) for r in bad for k in r.found):
            print("Problems found, but just as common in the other folders.")
        else:
            print("The checked folders are structurally clean — what iOS rejects isn't in their directory entries.")
    print("\nPaste this whole output back to Claude.")


if __name__ == "__main__":
    main()
