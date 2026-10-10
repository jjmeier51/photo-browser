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
separates them shows up as "in (nearly) every failing folder, (nearly) no healthy one". It also
reports WHERE on the drive each folder's contents physically sit: a structurally clean folder that
iOS still rejects points at the reader (e.g. one that can't reach past some offset on a large drive),
and comparing locations across hundreds of folders shows whether that's the dividing line.

Read-only: it opens the disk device for reading and never writes. Run it BEFORE rebuilding a
folder — a rebuild rewrites the entries and erases the evidence.

Usage (needs sudo to read the disk device):
  sudo python3 mac/exfat_inspect.py "/Volumes/Extreme SSD/Kardashians/Kylie Jenner"
  sudo python3 mac/exfat_inspect.py --list unreadable.txt --root "/Volumes/Extreme SSD" --sample 5000
  (unreadable.txt = the list Drive Health's Share button exports)
For a disk image: python3 exfat_inspect.py --device image.img "Folder/Sub"
"""

from __future__ import annotations

import argparse
import bisect
import os
import random
import struct
import subprocess
import sys
import unicodedata
from collections import Counter, defaultdict, deque

FORBIDDEN = set('"*/:<>?\\|')
DIR_OWNER: dict[int, str] = {}   # cluster → the folder whose contents it holds (every folder read so far)
FIRST_OWNER: dict[int, tuple[str, str, bool]] = {}   # first cluster → (folder, name, is_dir) of every item read
FILES: list[tuple[int, int, bool, str, str]] = []      # (first cluster, clusters, NoFatChain, folder, name) of every file
KEEP_RAW = False            # --dump: keep each entry set's bytes (off by default — a full-drive walk holds ~1M items)
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
    "dir-crosslinked": "part of the folder's contents is ALSO inside a file's data (cross-linked clusters)",
    "dir-fat:zero": "contiguous folder; its clusters' FAT entries are empty (the usual way)",
    "dir-fat:chain": "contiguous folder; its clusters' FAT entries ALSO hold a proper chain",
    "dir-fat:other": "contiguous folder; its clusters' FAT entries hold something else (stale or odd values)",
    "dir-fat:followed": "folder's contents are found by following the FAT (not marked contiguous)",
    "after-end-bytes": "leftover bytes after the end-of-directory marker (should be all zero; a strict reader may object)",
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
    return kind.startswith(("dir-fat:", "rec:")) or kind.split(":")[-1] in INFO_ONLY


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
        self.partition_offset = u64(boot, 64) * self.bps      # where the volume starts on the disk (0 = unknown)
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

    def offset(self, c: int) -> int:
        """Byte offset of cluster `c` from the start of the volume."""
        return self.heap_offset + (c - 2) * self.cluster_size

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
    __slots__ = ("name", "is_dir", "first", "length", "no_fat_chain", "index", "entry_off", "raw", "created", "rec")

    def __init__(self, name, is_dir, first, length, no_fat_chain, index, entry_off=None, raw=None, created=0):
        self.name, self.is_dir, self.first = name, is_dir, first
        self.length, self.no_fat_chain, self.index = length, no_fat_chain, index
        self.entry_off = entry_off              # byte offset of its record (inside the parent folder's data)
        self.raw = raw                          # its entry set's bytes (only with --dump)
        self.created = created                  # its exFAT creation timestamp
        self.rec = None                         # a folder's file entry (32 bytes): its writer's fingerprint


class Report:
    def __init__(self, label: str):
        self.label = label
        self.found: dict[str, list[str]] = defaultdict(list)
        self.items: list[Item] = []
        self.live = self.deleted = self.extents = self.clusters = 0
        self.size = 0
        self.unreadable: str | None = None
        self.by_name: dict[str, list[str]] = {}     # item name → problems in its own entry set
        self.dir_lo = self.dir_hi = None           # where this folder's own contents sit (byte offsets)
        self.entry_off = None                      # where its record sits, inside the parent folder
        self.own_raw = None                        # its record's bytes (only with --dump)
        self.dir_clusters: list[int] = []          # its contents' clusters, in reading order
        self.nfc = None                            # its record's NoFatChain flag
        self.created = 0                           # its record's creation timestamp
        self.rec = None                            # its record's file entry (32 bytes)
        self.under: str | None = None              # a checked folder it sits inside (iOS never got to it)
        self.file_lo = self.file_hi = None         # where its files' data starts (lowest / highest)

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
    r.dir_clusters = clusters
    for c in clusters:
        DIR_OWNER.setdefault(c, label or "(drive root)")
    r.dir_lo = vol.offset(min(clusters))
    r.dir_hi = vol.offset(max(clusters)) + vol.cluster_size
    r.extents = 1 + sum(1 for a, b in zip(clusters, clusters[1:]) if b != a + 1)
    if r.extents > 1:
        r.add("fragmented", f"{r.extents} pieces")
    if no_fat_chain and len(clusters) > 1:
        r.add("no-fat-chain-dir", f"{len(clusters)} clusters")
    if no_fat_chain:
        vals = [vol.fat(c) for c in clusters]
        if not any(vals):
            r.add("dir-fat:zero", "")
        elif vals == [c + 1 for c in clusters[:-1]] + [0xFFFFFFFF]:
            r.add("dir-fat:chain", "")
        else:
            r.add("dir-fat:other", " ".join(f"{v:#x}" for v in vals[:4]))
    else:
        r.add("dir-fat:followed", "")
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
            elif data[i * 32:].count(0) != len(data) - i * 32:
                stale = sum(1 for j in range(i, n) if any(data[j * 32:(j + 1) * 32]))
                r.add("after-end-bytes", f"{stale} non-zero slots after the end marker at #{i}")
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
        ci = i // per_cluster
        entry_off = vol.offset(clusters[ci]) + (i % per_cluster) * 32 if ci < len(clusters) else None
        r.items.append(Item(name, is_dir, first_c, dlen, nfc, i, entry_off, raw if KEEP_RAW else None, u32(e, 8)))
        if first_c and dlen:
            FIRST_OWNER.setdefault(first_c, (label, name, is_dir))
            if not is_dir:
                FILES.append((first_c, -(-dlen // vol.cluster_size), nfc, label, name))
        if is_dir:
            r.items[-1].rec = bytes(e)
        if not is_dir and dlen and vol.valid_cluster(first_c):
            fo = vol.offset(first_c)
            r.file_lo = fo if r.file_lo is None else min(r.file_lo, fo)
            r.file_hi = fo if r.file_hi is None else max(r.file_hi, fo)
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
        own_raw, own_item = it.raw, it
    if length is None:
        return root_report(vol), ""
    rep = parse_directory(vol, first, length, nfc, rel)
    add_own(rep, own)
    rep.own_raw = own_raw
    add_record(rep, own_item)
    return rep, ""


def add_record(rep: Report, it: Item) -> None:
    """The folder's own record in its parent: where it is, its flags, and how its writer filled it in."""
    rep.entry_off, rep.nfc, rep.created, rep.rec = it.entry_off, it.no_fat_chain, it.created, it.rec
    e = it.rec
    if e is None:
        return
    c, m, a = u32(e, 8), u32(e, 12), u32(e, 16)
    rep.add(f"rec:attributes {u16(e, 4):#06x}", "")
    rep.add(f"rec:10ms {'zero' if not e[20] and not e[21] else 'set'}", "")
    rep.add(f"rec:UTC offset {'set' if e[22] & 0x80 else 'none'}", "")
    rep.add("rec:modified " + ("= created" if m == c else "> created" if m > c else "< created"), "")
    rep.add("rec:accessed " + ("= modified" if a == m else "≠ modified"), "")


def crosslinks(vol: Volume, reports: list[Report]) -> None:
    """Flag folders whose contents' clusters also lie inside some file's data."""
    dirc = sorted(DIR_OWNER)
    dset = set(dirc)
    hit: dict[int, str] = {}
    walked = 0
    for first, n, nfc, folder, name in FILES:
        where = f"{folder}/{name}".strip("/")
        if nfc:
            j = bisect.bisect_left(dirc, first)
            while j < len(dirc) and dirc[j] < first + n:
                hit.setdefault(dirc[j], where)
                j += 1
        elif walked < 30_000_000:
            cl, _ = vol.chain(first, n * vol.cluster_size, False)
            walked += len(cl)
            for c in cl:
                if c in dset:
                    hit.setdefault(c, where)
    for r in reports:
        shared = [c for c in r.dir_clusters if c in hit]
        if shared:
            r.add("dir-crosslinked", f"cluster {shared[0]} is also in file “{printable(hit[shared[0]])}”")


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
        add_record(rep, it)
        rep.under = next((k for k in skip if norm(rel).startswith(k + "/")), None)
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


def location_report(vol: Volume, bad: list[Report], good: list[Report]) -> str | None:
    """Where the checked folders sit on the drive compared with the others — a reader that can't reach
    part of a large drive (a 32-bit block number tops out at 2 TiB with 512-byte blocks) fails exactly
    for the folders stored past that point, whatever their contents. Returns a verdict if location
    separates the two groups."""
    size = vol.heap_offset + vol.cluster_count * vol.cluster_size
    limit = (2 ** 32) * vol.bps - vol.partition_offset          # 2^32 blocks from the start of the disk
    print(f"\n== Where things sit on the drive ({size / 1e12:.2f} TB; "
          f"2^32 {vol.bps}-byte blocks end at {limit / 1e12:.2f} TB into this volume) ==")

    def span(rs: list[Report], key) -> str:
        vals = [key(r) for r in rs if key(r) is not None]
        return f"{tb(min(vals))} – {tb(max(vals))}" if vals else "—"

    print(f"{'':26} {'checked':>22} {'others':>22}")
    for label, key in (("folder contents (start)", lambda r: r.dir_lo), ("folder contents (end)", lambda r: r.dir_hi),
                       ("record in the parent", lambda r: r.entry_off),
                       ("files' data (lowest)", lambda r: r.file_lo), ("files' data (highest)", lambda r: r.file_hi)):
        print(f"{label:26} {span(bad, key):>22} {span(good, key):>22}")
    edges = [0.5e12 * k for k in range(0, int(size / 0.5e12) + 2)]
    # A folder that grew got its new pieces wherever there was free space, so bucket by its farthest piece.
    print(f"\n{'folder contents reach':26} {'checked':>8} {'others':>8}")
    for lo, hi in zip(edges, edges[1:]):
        nb_ = sum(1 for r in bad if r.dir_hi is not None and lo < r.dir_hi <= hi)
        ng_ = sum(1 for r in good if r.dir_hi is not None and lo < r.dir_hi <= hi)
        if nb_ or ng_:
            print(f"{tb(int(lo)) + ' – ' + tb(int(hi)):26} {nb_:8} {ng_:8}")
    verdicts = []
    for label, key in (("contents reach", lambda r: r.dir_hi), ("record sits", lambda r: r.entry_off)):
        b = [key(r) for r in bad if key(r) is not None]
        g = [key(r) for r in good if key(r) is not None]
        if b and g:
            if min(b) > max(g):
                verdicts.append(f"LOCATION: every checked folder's {label} beyond {tb(min(b))}, and no other "
                                f"folder's does (farthest: {tb(max(g))}). The 2^32-block mark is {tb(limit)}.")
            else:
                beyond = sum(1 for x in g if x >= min(b))
                print(f"   {beyond} of {len(g)} other folders' {label} as far as or beyond the nearest checked one "
                      f"({tb(min(b))}).")
    return "\n".join(verdicts) or None


def strict_listing(data: bytes) -> tuple[str, int]:
    """Read `data` the way a strict exFAT driver reads a folder's contents: ("empty" | "lists" | "fails", sets)."""
    sets, i, n = 0, 0, len(data) // 32
    while i < n:
        t = data[i * 32]
        if t == 0x00:
            return ("lists" if sets else "empty"), sets
        if t < 0x80 or 0xA0 <= t <= 0xBF or t >= 0xE0:      # unused / benign entries are skipped
            i += 1
            continue
        if t != 0x85:
            return "fails", sets
        sc = data[i * 32 + 1]
        if i + 1 + sc > n:                                  # runs on into the next cluster
            return "lists", sets
        raw = data[i * 32:(i + 1 + sc) * 32]
        if not 2 <= sc <= 18 or raw[32] != 0xC0 or set_checksum(raw) != u16(raw, 2):
            return "fails", sets
        sets += 1
        i += 1 + sc
    return "lists", sets


def wrap_report(vol: Volume, bad: list[Report], good: list[Report], shift: int | None = None) -> str | None:
    """Test one specific reader bug: block numbers kept in 32 bits. With 512-byte blocks they run out
    2^32 blocks (2.20 TB) into the disk, and a read past that point silently lands 2.20 TB earlier.
    A folder stored there is then read from the wrong spot, and what happens to sit there decides
    the result: other files' bytes → "Invalid argument"; zeros → an empty folder; another folder's
    contents → that folder's items. This reads those exact spots and predicts the iPhone's view."""
    shift = shift or (2 ** 32) * vol.bps                  # (overridable so a small test image can exercise it)
    limit = shift - vol.partition_offset

    def predict(r: Report):
        for k, c in enumerate(r.dir_clusters):
            off = vol.offset(c)
            if off < limit:
                continue
            a = off - shift
            if a < 0:
                return k, a, "before this volume", "fails", 0
            ac = (a - vol.heap_offset) // vol.cluster_size + 2
            if a < vol.heap_offset:
                where = "the volume's own tables"
            elif ac in DIR_OWNER:
                where = f"the contents of “{DIR_OWNER[ac]}”"
            elif vol.allocated(ac):
                where = "file data"
            else:
                where = "free space"
            data = vol._read(a, vol.cluster_size)
            if k:                                          # the first pieces read fine; only the rest wraps
                verdict, sets = strict_listing(data)
                verdict = "fails" if verdict == "fails" else f"partly lists ({verdict})"
                return k, a, where, verdict, sets
            if not any(data):
                return k, a, where + " (all zeros)", "empty", 0
            verdict, sets = strict_listing(data)
            return k, a, where, verdict, sets
        return None

    wrap_c = shift // vol.cluster_size

    def twin(r: Report):
        """The item whose ID a 32-bit block-based ID would share with this folder: the one whose data
        starts exactly `shift` bytes before this folder's first cluster."""
        if not r.dir_clusters or vol.offset(r.dir_clusters[0]) < limit:
            return None
        hit = FIRST_OWNER.get(r.dir_clusters[0] - wrap_c)
        if hit is None:
            return None
        folder, name, is_dir = hit
        folder = "" if folder == "(drive root)" else folder + "/"
        return f"{'folder' if is_dir else 'file'} {folder}{printable(name)}"

    b_pred = [(r, predict(r)) for r in bad]
    g_pred = [(r, predict(r)) for r in good if r.under is None]
    g_past = [(r, p) for r, p in g_pred if p]
    if not g_past and not any(p for _, p in b_pred):
        return None                                        # nothing on this drive is stored past the line
    b_twin = [(r, twin(r)) for r in bad]
    g_twin = [(r, twin(r)) for r, _ in g_past]
    print(f"\n== Same-ID test: does an item start exactly {tb(shift)} before each folder? ==")
    print("If iOS builds an item's ID from a 32-bit block number, a folder past the line shares its ID with that\n"
          "item, and the two get confused. Only folders with such a twin would break.\n")
    for r, t in b_twin:
        print(f"   {r.label[:60]:60} " + (f"twin: {t}" if t else ("no twin" if r.dir_lo and r.dir_lo >= limit
                                                                   else "(not past the line)")))
    with_twin = [r.label for r, t in g_twin if t]
    print(f"\n   other folders past the line with a twin: {len(with_twin)} of {len(g_twin)}"
          + (" — e.g. " + "; ".join(with_twin[:6]) if with_twin else ""))
    # Recency is the other thing all the failing folders share — see whether new folders past the line open.
    since = min((r.created for r in bad if r.created), default=0)
    if since:
        day = exfat_time(since, None, 0)[:10]
        recent = [r for r in good if r.under is None and r.created >= since]
        past = [r for r in recent if r.dir_lo is not None and r.dir_lo >= limit]
        print(f"\n   other folders created since {day} (when the oldest checked one was): {len(recent)} — "
              f"{len(past)} stored past the line, {len(recent) - len(past)} below it")
        if past:
            print("   new AND past the line, yet not on your list: "
                  + "; ".join(f"{r.label} ({exfat_time(r.created, None, 0)[:10]})" for r in past[:8]))
    nb_twin = sum(1 for _, t in b_twin if t)
    twin_verdict = None
    if bad and nb_twin == len(bad) and len(with_twin) <= max(1, len(g_twin) // 20):
        twin_verdict = (f"SAME-ID: every checked folder has an item starting exactly {tb(shift)} before it, and only "
                        f"{len(with_twin)} of {len(g_twin)} other folders past the line do.")
    elif bad:
        print(f"   checked folders with a twin: {nb_twin} of {len(bad)}")
    print(f"\n== If the iPhone's reader wraps at 2^32 blocks ({tb(limit)}) ==")
    print(f"A folder stored past that point would be read from {tb(shift)} earlier. What is there, per folder:\n")
    print(f"{'checked folder':44} {'stored at':>10}  {'NoFatChain':>10}  {'created':29}  wrapped read lands on → prediction")
    for r, pr in b_pred:
        made = exfat_time(r.created, None, 0)[:10] if r.created else "?"
        if r.rec is not None:
            made = exfat_time(u32(r.rec, 8), r.rec[20], r.rec[22])
        if pr is None:
            print(f"{r.label[:44]:44} {tb(r.dir_lo):>10}  {str(r.nfc):>10}  {made:29}  (not past {tb(limit)})")
            continue
        k, a, where, verdict, sets = pr
        tail = f" ({sets} sets first)" if sets else ""
        print(f"{r.label[:44]:44} {tb(r.dir_lo):>10}  {str(r.nfc):>10}  {made:29}  "
              + (f"after {k} good cluster(s), " if k else "") + f"{tb(a) if a >= 0 else '—'}, {where} → {verdict}{tail}")
    counts = Counter(p[3].split(" (")[0] for _, p in g_past)
    print(f"\nOther folders stored past {tb(limit)}: {len(g_past)} of {len(g_pred)}"
          + (" — predicted: " + ", ".join(f"{v} {n}" for v, n in counts.most_common()) if g_past else ""))
    nfc_b = Counter(r.nfc for r, p in b_pred if p)
    nfc_g = Counter(r.nfc for r, p in g_past)
    print(f"   NoFatChain on the folder's record — checked: {dict(nfc_b)} · others past the line: {dict(nfc_g)}")
    for verdict in ("empty", "lists", "fails"):
        ex = [r.label for r, p in g_past if p[3] == verdict][:6]
        if ex:
            print(f"   predicted to {'look EMPTY' if verdict == 'empty' else 'show the WRONG items' if verdict == 'lists' else 'fail'} "
                  f"on the iPhone, e.g.: " + "; ".join(ex))
    files_past = [r.label for r, _ in g_pred if r.dir_hi is not None and r.dir_hi <= limit
                  and r.file_lo is not None and r.file_lo >= limit][:4]
    if files_past:
        print("   folders stored below the line whose photos all sit past it (if these photos show fine on the "
              "iPhone, file reads don't wrap): " + "; ".join(files_past))
    fails_b = sum(1 for _, p in b_pred if p and p[3] == "fails")
    fails_g = counts.get("fails", 0)
    if bad and fails_b == len(bad) and fails_g <= max(1, len(g_past) // 20):
        return "\n".join(x for x in (twin_verdict, (
            f"WRAP: every checked folder is stored past {tb(limit)} and a wrapped read of it lands on bytes a "
            f"strict reader rejects; only {fails_g} of the {len(g_past)} other folders past the line would. "
            f"Check the 'look EMPTY' examples on the iPhone to confirm.")) if x)
    return twin_verdict


def describe(kind: str) -> str:
    if kind.startswith("own-entry:"):
        return "the folder's own entry in its parent: " + HELP.get(kind[len("own-entry:"):], "")
    return HELP.get(kind, "")


def exfat_time(ts: int, ms: int | None, utc: int) -> str:
    sec = (ts & 0x1F) * 2 + (ms or 0) // 100
    t = (f"{1980 + (ts >> 25):04}-{(ts >> 21) & 0xF:02}-{(ts >> 16) & 0x1F:02} "
         f"{(ts >> 11) & 0x1F:02}:{(ts >> 5) & 0x3F:02}:{sec:02}")
    if utc & 0x80:
        v = utc & 0x7F
        v = v - 0x80 if v & 0x40 else v
        t += f" UTC{'+' if v >= 0 else '-'}{abs(v) * 15 // 60:02}:{abs(v) * 15 % 60:02}"
    else:
        t += " (no UTC offset)"
    return t


def dump_set(title: str, raw: bytes | None) -> None:
    """One entry set: every field decoded, then the bytes, so two sets can be compared exactly."""
    print(f"   {title}")
    if raw is None:
        print("      (not available)")
        return
    e, s = raw[:32], raw[32:64]
    print(f"      file entry:  secondaries {e[1]}, checksum {u16(e, 2):04x}, attributes {u16(e, 4):#06x}, "
          f"reserved {u16(e, 6):#06x}")
    print(f"      created  {exfat_time(u32(e, 8), e[20], e[22])}")
    print(f"      modified {exfat_time(u32(e, 12), e[21], e[23])}")
    print(f"      accessed {exfat_time(u32(e, 16), None, e[24])}, reserved tail {e[25:32].hex()}")
    print(f"      stream:      flags {s[1]:#04x} (AllocationPossible {s[1] & 1}, NoFatChain {(s[1] >> 1) & 1}), "
          f"reserved {s[2]:#04x}, name length {s[3]}, name hash {u16(s, 4):04x}, reserved {u16(s, 6):#06x}")
    print(f"                   valid length {u64(s, 8)}, reserved {u32(s, 16):#x}, first cluster {u32(s, 20)}, "
          f"size {u64(s, 24)}")
    for k in range(0, len(raw), 32):
        print(f"      {raw[k]:02x}: {raw[k:k + 32].hex(' ')}")


def print_dump(r: Report, limit: int = 6) -> None:
    dump_set("its own record (in the parent folder):", r.own_raw)
    for it in r.items[:limit]:
        dump_set(f"item “{printable(it.name)}”:", it.raw)
    if len(r.items) > limit:
        print(f"   … and {len(r.items) - limit} more items")


def tb(n: int | None) -> str:
    if n is None:
        return "—"
    return f"{n / 1e12:.2f} TB" if n >= 1e11 else f"{n / 1e9:.1f} GB"


def print_report(r: Report) -> None:
    print(f"\n{r.label or '(drive root)'}  — {r.live} items, {r.deleted} deleted, "
          f"{r.size // 1024} KB in {r.clusters} cluster(s), {r.extents} piece(s)")
    print(f"   on the drive: contents at {tb(r.dir_lo)}" + (f"–{tb(r.dir_hi)}" if r.clusters > 1 else "")
          + f" · its record (in the parent) at {tb(r.entry_off)}"
          + (f" · its files' data from {tb(r.file_lo)} to {tb(r.file_hi)}" if r.file_lo is not None else ""))
    if r.unreadable:
        print(f"   can't read: {r.unreadable}")
    if not any(not k.startswith(("rec:", "dir-fat:")) for k in r.found):
        print("   (no problems)")
    facts = sorted(k for k in r.found if k.startswith(("rec:", "dir-fat:")))
    for kind in sorted((k for k in r.found if k not in facts), key=lambda k: (is_info(k), k)):
        ex = r.found[kind]
        more = f" (+{len(ex) - 3} more)" if len(ex) > 3 else ""
        tag = "info " if is_info(kind) else "PROBLEM"
        print(f"   {tag:7} {kind:22} {len(ex):6}  e.g. {'; '.join(ex[:3])}{more}")
    if facts:
        print("   facts   " + " · ".join(k + (f" ({r.found[k][0]})" if r.found[k][0] else "") for k in facts))


def main() -> None:
    ap = argparse.ArgumentParser(description="Inspect exFAT folders on disk (read-only).")
    ap.add_argument("folders", nargs="*", help="folders on the SSD (or volume-relative paths with --device)")
    ap.add_argument("--list", help="Drive Health's exported unreadable-folder list (drive-relative paths)")
    ap.add_argument("--root", help='the SSD for --list, e.g. "/Volumes/Extreme SSD"')
    ap.add_argument("--device", help="read this device / image instead of the one df reports")
    ap.add_argument("--sample", type=int, default=150, help="healthy folders to compare against (default 150)")
    ap.add_argument("--dump", action="store_true",
                    help="also print each checked folder's raw records (its own and its first items') field by field")
    args = ap.parse_args()
    global KEEP_RAW
    KEEP_RAW = args.dump

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
        if args.dump:
            print_dump(rep)
        bad.append(rep)
    if not bad or args.sample <= 0:
        return

    print(f"\n== Comparing with up to {args.sample} other folders on the drive… ==")
    good = healthy_sample(vol, {norm(r.label) for r in bad}, args.sample)
    crosslinks(vol, bad + good)
    good_flags = Counter(k for r in good for k in r.found)
    bad_flags = Counter(k for r in bad for k in r.found)
    nb, ng = len(bad), max(1, len(good))
    # Folders made in the same days as the checked ones: same tools and OS versions, so the fairest comparison.
    since = min((r.created for r in bad if r.created), default=0)
    new = [r for r in good if since and r.created >= since]
    new_flags = Counter(k for r in new for k in r.found)
    nn = max(1, len(new))
    print(f"{'finding':32} {'checked':>8} {'others':>8} {'new':>8}   (new = the {len(new)} others created since "
          f"{exfat_time(since, None, 0)[:10] if since else '—'})")
    rows = sorted(set(bad_flags) | set(good_flags), key=lambda k: -(bad_flags[k] / nb - good_flags[k] / ng))
    for k in rows:
        print(f"{k:32} {100 * bad_flags[k] / nb:7.0f}% {100 * good_flags[k] / ng:7.0f}% "
              f"{100 * new_flags[k] / nn:7.0f}%   {describe(k)}")
    avg = lambda rs, f: sum(f(r) for r in rs) / max(1, len(rs))
    print(f"\n{'':24} {'checked':>8} {'others':>8}")
    print(f"{'avg items':24} {avg(bad, lambda r: r.live):8.0f} {avg(good, lambda r: r.live):8.0f}")
    print(f"{'avg deleted items':24} {avg(bad, lambda r: r.deleted):8.0f} {avg(good, lambda r: r.deleted):8.0f}")
    print(f"{'avg pieces on disk':24} {avg(bad, lambda r: r.extents):8.1f} {avg(good, lambda r: r.extents):8.1f}")
    located = location_report(vol, bad, good)
    wrapped = wrap_report(vol, bad, good)
    if wrapped:
        located = "\n".join(x for x in (located, wrapped) if x)
    suspects = [k for k in rows if bad_flags[k] / nb >= 0.6 and good_flags[k] / ng <= 0.15]
    rare = [k for k in rows if k not in suspects and not is_info(k) and bad_flags[k] and good_flags[k] / ng <= 0.15]
    print()
    if located:
        print(located)
    if suspects:
        print("Likely trigger(s): " + ", ".join(suspects))
    if rare:
        print("Problems in some checked folders that the others hardly have: "
              + ", ".join(f"{k} ({bad_flags[k]} of {nb})" for k in rare))
    if not suspects and not rare:
        if any(not is_info(k) for r in bad for k in r.found):
            print("Problems found, but just as common in the other folders.")
        elif not located:
            print("The checked folders are structurally clean — what iOS rejects isn't in their directory entries.")
    print("\nPaste this whole output back to Claude.")


if __name__ == "__main__":
    main()
