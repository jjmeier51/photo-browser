#!/usr/bin/env python3
"""Move folders' lists of contents below 2.2 TB on the exFAT SSD, so the iPhone can read them.

Why (Oct 2026, see docs/feature-notes.md §12): the iPhone's exFAT driver misreads a folder's list of
contents when it is stored more than 2^32 × 512 bytes (2.20 TB) into the drive. Such folders fail
with "Invalid argument", look empty, or show an older list, while the Mac reads them correctly — and
photos are read correctly wherever they sit. Every unreadable folder had its list past that point,
and every rebuilt copy that happened to land below it works.

What it does: each folder whose list of contents (its exFAT directory data — one 1 MB cluster holds
~10,000 items) reaches past the line gets that list copied into free space below it, and the
folder's record in its parent is pointed at the copy. Lists full of deleted entries (a folder whose
files were all saved under a temporary name and renamed) are compacted on the way, which leaves room
to grow. Nothing else changes: names, dates, the files and their data stay where they are, so every
path — and the iPhone app's labels, covers and captions — is untouched.

Safety: a dry run by default (it only reads; the SSD can stay mounted). --apply has macOS check the
drive first (fsck_exfat) and refuses unless it is clean, unmounts it, makes sure the free space it
picked really isn't used by any file, saves an undo file holding every byte it will change, and
writes in a crash-safe order — copy the lists into free space, mark that space used, repoint the
folders, only then free the old space — so an interruption can at worst leave some space marked used.
It then re-reads every moved folder, has fsck_exfat check the drive again, and remounts it.
--undo FILE puts every changed byte back.

  sudo python3 mac/relocate_folders.py "/Volumes/Extreme SSD"                 # dry run: what would move
  sudo python3 mac/relocate_folders.py "/Volumes/Extreme SSD" --apply --only "Porn & Onlyfans/Porn/Lexi Star"
  sudo python3 mac/relocate_folders.py "/Volumes/Extreme SSD" --apply
  sudo python3 mac/relocate_folders.py "/Volumes/Extreme SSD" --undo relocate-undo-20261011-120000.json
"""

from __future__ import annotations

import argparse
import bisect
import datetime
import json
import os
import struct
import subprocess
import sys
from collections import deque

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import exfat_inspect as xi  # noqa: E402

EOC = 0xFFFFFFFF
ALIGN = 4096
F_FULLFSYNC = 51


class Disk:
    """Byte-addressed access to the raw volume (a raw macOS device only takes whole aligned blocks)."""

    def __init__(self, device: str, writable: bool):
        self.fd = os.open(device, os.O_RDWR if writable else os.O_RDONLY)

    def _span(self, off: int, n: int) -> tuple[int, int]:
        start = off - off % ALIGN
        end = off + n
        return start, end + (-end) % ALIGN

    def read(self, off: int, n: int) -> bytes:
        start, end = self._span(off, n)
        return os.pread(self.fd, end - start, start)[off - start: off - start + n]

    def write(self, off: int, data: bytes) -> None:
        start, end = self._span(off, len(data))
        block = bytearray(os.pread(self.fd, end - start, start))
        if len(block) != end - start:
            raise OSError(f"short read at {start}")
        block[off - start: off - start + len(data)] = data
        if os.pwrite(self.fd, bytes(block), start) != len(block):
            raise OSError(f"short write at {start}")

    def flush(self) -> None:
        """Ask the drive to commit its own cache (F_FULLFSYNC on the raw device on a Mac). Raw-device
        writes aren't buffered by macOS, so a device that refuses both requests is no reason to stop."""
        try:
            import fcntl
            fcntl.fcntl(self.fd, F_FULLFSYNC)
            return
        except (OSError, ImportError):
            pass
        try:
            os.fsync(self.fd)
        except OSError:
            pass


class Node:
    """One folder: where its list of contents is, and where its record sits in its parent."""

    def __init__(self, path: str, parent: "Node | None", item: "xi.Item | None", rep: "xi.Report",
                 length: int, hidden: bool):
        self.path, self.parent, self.item, self.rep = path, parent, item, rep
        self.clusters: list[int] = rep.dir_clusters
        self.length, self.hidden = length, hidden
        self.new: list[int] = []                    # where its list goes (in order; contiguous when possible)
        self.buf: bytearray | None = None           # its list, as it will be written (patched / compacted)
        self.index_map: dict[int, int] | None = None  # entry index before → after compaction


def system_clusters(vol: "xi.Volume") -> tuple[list[int], int, set[int]]:
    """(allocation bitmap clusters, bitmap length, every cluster the bitmap and up-case table use)."""
    clusters, _ = vol.chain(vol.root_cluster, None, False)
    data = vol.read_clusters(clusters, None)
    bm: list[int] = []
    bm_len = 0
    used: set[int] = set()
    for i in range(0, len(data), 32):
        t = data[i]
        if t == 0:
            break
        if t in (0x81, 0x82):
            first, length = xi.u32(data, i + 20), xi.u64(data, i + 24)
            cl, _ = vol.chain(first, length, False)
            used.update(cl)
            if t == 0x81 and not bm:
                bm, bm_len = cl, length
    return bm, bm_len, used


def walk(vol: "xi.Volume") -> list[Node]:
    """Every folder on the drive (hidden ones too — their files count when checking free space)."""
    root_rep = xi.root_report(vol)
    root = Node("", None, None, root_rep, len(root_rep.dir_clusters) * vol.cluster_size, False)
    nodes = [root]
    queue = deque([root])
    while queue:
        node = queue.popleft()
        for it in node.rep.items:
            if not it.is_dir:
                continue
            path = f"{node.path}/{it.name}".strip("/")
            rep = xi.parse_directory(vol, it.first, it.length, it.no_fat_chain, path)
            child = Node(path, node, it, rep, it.length, node.hidden or it.name.startswith("."))
            nodes.append(child)
            if not rep.unreadable and not rep.found.get("chain"):
                queue.append(child)
    return nodes


def free_runs(vol: "xi.Volume", last_ok: int) -> list[list[int]]:
    """[start, length] runs of clusters the bitmap marks free, all at or before cluster `last_ok`."""
    runs: list[list[int]] = []
    bm = vol.bitmap
    start = None
    c = 2
    while c <= last_ok:
        i = c - 2
        byte = bm[i // 8]
        if i % 8 == 0 and c + 7 <= last_ok and byte in (0x00, 0xFF):
            if byte == 0x00:
                start = c if start is None else start
            elif start is not None:
                runs.append([start, c - start])
                start = None
            c += 8
            continue
        if not byte >> (i % 8) & 1:
            start = c if start is None else start
        elif start is not None:
            runs.append([start, c - start])
            start = None
        c += 1
    if start is not None:
        runs.append([start, last_ok + 1 - start])
    return runs


def take(runs: list[list[int]], n: int) -> list[int] | None:
    """`n` free clusters, removed from `runs`: one contiguous stretch if there is one (first fit),
    otherwise gathered from the largest gaps — a folder's list may legally sit in pieces, chained in
    the FAT, and the free space below the line is mostly small gaps left by deleted files."""
    for r in runs:
        if r[1] >= n:
            first = r[0]
            r[0] += n
            r[1] -= n
            return list(range(first, first + n))
    if sum(r[1] for r in runs) < n:
        return None
    out: list[int] = []
    for r in sorted(runs, key=lambda r: -r[1]):
        while r[1] and len(out) < n:
            out.append(r[0])
            r[0] += 1
            r[1] -= 1
        if len(out) == n:
            break
    return out


def contiguous(clusters: list[int]) -> bool:
    return all(b == a + 1 for a, b in zip(clusters, clusters[1:]))


def segments(clusters: list[int]) -> list[tuple[int, int]]:
    """(first cluster, count) of each contiguous piece, in order."""
    out: list[tuple[int, int]] = []
    for c in clusters:
        if out and c == out[-1][0] + out[-1][1]:
            out[-1] = (out[-1][0], out[-1][1] + 1)
        else:
            out.append((c, 1))
    return out


def compact(buf: bytes) -> tuple[bytearray, dict[int, int], int] | None:
    """The list with every deleted entry dropped (live entry sets kept byte for byte, in order), the
    old → new index of each set, and the bytes in use; None unless it checks out as whole, well-formed
    sets."""
    out = bytearray()
    mapping: dict[int, int] = {}
    n = len(buf) // 32
    i = 0
    while i < n:
        t = buf[i * 32]
        if t == 0x00:
            break
        if t & 0x80:
            if t == 0x85:
                mapping[i] = len(out) // 32
            out += buf[i * 32:(i + 1) * 32]
        i += 1
    # every primary must be followed by exactly its secondaries, and no secondary may stand alone
    j, m = 0, len(out) // 32
    while j < m:
        t = out[j * 32]
        if t == 0x85:
            sc = out[j * 32 + 1]
            if j + sc >= m:
                return None
            if any(not 0xC0 <= out[(j + k) * 32] for k in range(1, sc + 1)):
                return None
            j += 1 + sc
        elif t >= 0xC0:
            return None
        else:
            j += 1
    if len(out) > len(buf):
        return None
    used = len(out)
    out += bytes(len(buf) - len(out))
    return out, mapping, used


def live_sets(buf: bytes) -> list[bytes]:
    sets, n, i = [], len(buf) // 32, 0
    while i < n:
        t = buf[i * 32]
        if t == 0x00:
            break
        if t == 0x85:
            sc = buf[i * 32 + 1]
            sets.append(bytes(buf[i * 32:(i + 1 + sc) * 32]))
            i += 1 + sc
            continue
        i += 1
    return sets


def repoint(buf: bytearray, index: int, expect: bytes, clusters: list[int], cluster_size: int) -> None:
    """Point the folder record at entry `index` of a parent's list at its new `clusters` — marked
    contiguous (NoFatChain) when they are, otherwise found through the FAT chain written for them."""
    sc = buf[index * 32 + 1]
    a, b = index * 32, (index + 1 + sc) * 32
    if bytes(buf[a:b]) != expect:
        raise SystemExit("A folder's record changed between reading and planning — nothing was written.")
    s = a + 32
    size = len(clusters) * cluster_size
    buf[s + 1] = (buf[s + 1] & ~0x03) | 0x01 | (0x02 if contiguous(clusters) else 0)   # AllocationPossible, NoFatChain
    buf[s + 8:s + 16] = struct.pack("<Q", size)         # ValidDataLength = DataLength for a folder
    buf[s + 20:s + 24] = struct.pack("<I", clusters[0])
    buf[s + 24:s + 32] = struct.pack("<Q", size)
    buf[a + 2:a + 4] = struct.pack("<H", xi.set_checksum(bytes(buf[a:b])))


def entry_ranges(vol: "xi.Volume", clusters: list[int], a: int, b: int) -> list[tuple[int, int, int]]:
    """Disk ranges (disk offset, buffer start, buffer end) holding bytes [a, b) of a folder's list."""
    out: list[tuple[int, int, int]] = []
    cs = vol.cluster_size
    pos = a
    while pos < b:
        ci, within = divmod(pos, cs)
        end = min(b, (ci + 1) * cs)
        out.append((vol.offset(clusters[ci]) + within, pos, end))
        pos = end
    return out


def run(cmd: list[str]) -> tuple[int, str]:
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()


def fsck(device: str) -> tuple[bool, str]:
    tool = os.environ.get("FSCK_EXFAT", "/sbin/fsck_exfat")
    if not os.path.exists(tool):
        return True, f"({tool} not found — skipped)"
    code, out = run([tool, "-n", device])
    return code == 0, out


def human(n: int) -> str:
    return f"{n / 1e6:.0f} MB" if n < 1e9 else f"{n / 1e9:.1f} GB"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("drive", nargs="?",
                    help='the SSD, e.g. "/Volumes/Extreme SSD" — or a folder on it, to fix just that folder and '
                         "the folders inside it")
    ap.add_argument("--device", help="the raw device or a disk image (instead of finding it from the drive)")
    ap.add_argument("--apply", action="store_true", help="really move them (default: dry run)")
    ap.add_argument("--only", nargs="+", metavar="FOLDER", help="just these folders (drive-relative paths)")
    ap.add_argument("--include-hidden", action="store_true", help="also move lists inside hidden (dot) folders")
    ap.add_argument("--no-compact", action="store_true", help="copy lists as they are, deleted entries included")
    ap.add_argument("--undo", metavar="FILE", help="put back every byte a previous --apply changed")
    ap.add_argument("--limit-bytes", type=int, help=argparse.SUPPRESS)    # tests: a small image's "line"
    args = ap.parse_args()

    mount = None
    device = args.device
    if not device:
        if not args.drive:
            ap.error("pass the SSD (or --device)")
        device, mount = xi.device_for(os.path.abspath(args.drive))
    scope = None
    if args.drive and mount and os.path.realpath(args.drive) != os.path.realpath(mount):
        scope = os.path.relpath(os.path.realpath(args.drive), os.path.realpath(mount))
    elif args.drive and args.device:
        scope = args.drive.strip("/") or None          # with --device: a folder path inside that volume
    is_image = os.path.isfile(device)
    if not is_image and os.geteuid() != 0:
        sys.exit("Run it with sudo — it reads the disk device directly.")

    if args.undo:
        undo(args.undo, device, mount)
        return

    if mount and args.apply:
        # Unmount before reading: macOS may still write its cached changes while unmounting.
        code, out = run(["diskutil", "unmount", mount])
        if code != 0:
            sys.exit(f"Couldn't unmount the SSD — close anything using it (Finder windows, Safe Finder, "
                     f"Photo Browser for Mac) and try again.\n{out}")
        print(f"Unmounted {mount} (it is remounted at the end).")
        try:
            plan_and_move(args, device, mount, scope)
        finally:
            code, out = run(["diskutil", "mount", device.replace("/dev/rdisk", "/dev/disk")])
            print("Remounted the SSD." if code == 0 else f"Couldn't remount the SSD — unplug and replug it.\n{out}")
        return
    if mount:
        os.sync()
    plan_and_move(args, device, mount, scope)


def plan_and_move(args: argparse.Namespace, device: str, mount: str | None, scope: str | None) -> None:
    xi.KEEP_RAW = "dirs"
    vol = xi.Volume(device)
    cs = vol.cluster_size
    line = args.limit_bytes or (2 ** 32) * vol.bps - vol.partition_offset
    # A 1 GB margin both ways: lists that close to the line move too, and copies land at least that far
    # below it — in case the drive's partition starts a little later than its boot sector records.
    margin = 0 if args.limit_bytes else 2 ** 30
    safe = line - margin
    last_ok = (safe - vol.heap_offset) // cs + 1                   # last cluster that ends below `safe`
    while vol.offset(last_ok) + cs > safe:
        last_ok -= 1
    print(f"Volume {device}: {vol.cluster_count} clusters of {cs // 1024} KB, starting "
          f"{vol.partition_offset // 512} blocks into the disk; the line is {xi.tb(line)} (2^32 × {vol.bps}-byte blocks)")
    if vol.bitmap is None:
        sys.exit("Couldn't read the allocation bitmap.")
    boot = vol._read(0, 512)
    if boot[110] != 1:
        sys.exit("This volume has more than one FAT (TexFAT) — not supported.")

    print("Reading every folder on the drive…")
    nodes = walk(vol)
    only = None
    if args.only:
        only = set()
        for p in args.only:
            if mount and os.path.isabs(p) and os.path.abspath(p).startswith(mount + "/"):
                p = os.path.relpath(os.path.abspath(p), mount)
            only.add(xi.norm(p.strip("/")))

    movers: list[Node] = []
    skipped: list[str] = []
    hidden_left = 0
    within = xi.norm(scope) if scope else None
    if scope:
        print(f"Only “{scope}” and the folders inside it.")
    for nd in nodes:
        if within is not None and not (xi.norm(nd.path) == within or xi.norm(nd.path).startswith(within + "/")):
            continue
        if nd.parent is None or not any(vol.offset(c) + cs > safe for c in nd.clusters):
            continue
        if only is not None and xi.norm(nd.path) not in only:
            continue
        if nd.hidden and not args.include_hidden:
            hidden_left += 1
            continue
        if nd.rep.unreadable or nd.rep.found.get("chain") or nd.length % cs or nd.item.raw is None:
            skipped.append(f"{nd.path} (its list has problems: {nd.rep.unreadable or nd.rep.found.get('chain')})")
            continue
        movers.append(nd)
    root_high = [c for c in nodes[0].clusters if vol.offset(c) + cs > safe]
    print(f"{len(nodes) - 1} folders; {len(movers)} to move" + (f" ({len(skipped)} skipped)" if skipped else ""))
    if root_high:
        print("  note: part of the drive's top-level list is past the line too — this tool can't move that one.")
    if only is not None:
        missing = only - {xi.norm(n.path) for n in movers}
        for m in sorted(missing):
            print(f"  “{m}”: not found, or its list is already below the line")
    if not movers:
        print("Nothing to move.")
        return

    # Plan: compact lists that are full of deleted entries (which can shrink them), then find room for
    # each below the line, biggest first so they get the longest unbroken stretches.
    need: dict[int, int] = {}
    for nd in movers:
        data = bytearray(vol.read_clusters(nd.clusters, nd.length))
        nd.buf = data
        n = len(nd.clusters)
        if not args.no_compact and nd.rep.deleted:
            res = compact(data)
            if res and live_sets(res[0]) == live_sets(data):
                buf, nd.index_map, used = res
                n = min(n, -(-used // cs) + 1)          # what the live entries need, plus a cluster to grow
                nd.buf = buf[:n * cs]
        need[id(nd)] = n
    runs = free_runs(vol, last_ok)
    free_total = sum(r[1] for r in runs)
    largest = max((r[1] for r in runs), default=0)
    wanted = sum(need.values())
    print(f"Free space below the line: {human(free_total * cs)} in {len(runs)} gap(s), the largest "
          f"{human(largest * cs)}; these lists need {human(wanted * cs)}.")
    if wanted > free_total:
        sys.exit("Not enough free space below the line for all of them — nothing was written. Move some of "
                 "them at a time with --only, or free up space on the drive first.")
    for nd in sorted(movers, key=lambda n: -need[id(n)]):
        nd.new = take(runs, need[id(nd)])
    print()
    for nd in sorted(movers, key=lambda n: n.path):
        where = xi.tb(vol.offset(min(nd.clusters)))
        pieces, new_pieces = len(segments(nd.clusters)), len(segments(nd.new))
        extra = f", {nd.rep.deleted} deleted entries dropped" if nd.index_map is not None else ""
        if len(nd.new) != len(nd.clusters):
            extra += f", {len(nd.clusters)} → {len(nd.new)} clusters"
        print(f"  {nd.path}\n      {nd.rep.live} items; list at {where}"
              + (f" in {pieces} pieces" if pieces > 1 else "")
              + f" → {xi.tb(vol.offset(nd.new[0]))}" + (f" in {new_pieces} pieces" if new_pieces > 1 else "") + extra)
    for s in skipped:
        print(f"  skipped: {s}")
    if hidden_left:
        print(f"  ({hidden_left} hidden folder(s) past the line left alone — the iPhone app doesn't show them)")

    # The records to repoint live in the parents' lists — patch those in memory first.
    moving = {id(n) for n in movers}
    parent_bufs: dict[int, tuple[Node, bytearray]] = {}
    for nd in movers:
        par = nd.parent
        if id(par) in moving:
            buf = par.buf
            index = par.index_map.get(nd.item.index, None) if par.index_map is not None else nd.item.index
            if index is None:
                sys.exit(f"Lost track of “{nd.path}” while compacting its parent — nothing was written.")
        else:
            if id(par) not in parent_bufs:
                parent_bufs[id(par)] = (par, bytearray(vol.read_clusters(par.clusters, par.length)))
            buf = parent_bufs[id(par)][1]
            index = nd.item.index
        repoint(buf, index, nd.item.raw, nd.new, cs)

    if not args.apply:
        print("\nDry run — nothing was written. To do it: add --apply (the SSD gets unmounted while it runs).")
        return

    damaged = [n.path for n in nodes if n.rep.unreadable or n.rep.found.get("chain")]
    if damaged:
        sys.exit(f"{len(damaged)} folder(s) have broken cluster chains (e.g. “{damaged[0]}”), so free space can't "
                 "be trusted — repair the drive first (sh mac/repair_drive.sh). Nothing was written.")
    apply(vol, device, movers, parent_bufs)


def apply(vol: "xi.Volume", device: str, movers: list[Node], parent_bufs: dict) -> None:
    ok, out = fsck(device)
    if not ok:
        sys.exit("macOS's check found problems on the drive, so nothing was written. Repair it first "
                 f"(sh mac/repair_drive.sh), then run this again.\n{out}")
    cs = vol.cluster_size
    bm_clusters, bm_len, sys_used = system_clusters(vol)
    dest = sorted(c for n in movers for c in n.new)
    dest_set = set(dest)

    # The bitmap says these clusters are free — make sure no folder or file actually uses them.
    clash = [c for c in dest if c in xi.DIR_OWNER or c in sys_used]
    for first, n, nfc, folder, name in xi.FILES:
        if clash:
            break
        if nfc:
            j = bisect.bisect_left(dest, first)
            if j < len(dest) and dest[j] < first + n:
                clash.append(dest[j])
        else:
            cl, _ = vol.chain(first, n * cs, False)
            hit = [c for c in cl if c in dest_set]
            clash += hit
    if clash:
        sys.exit(f"Cluster {clash[0]} is marked free but something uses it — the drive needs a repair first "
                 "(sh mac/repair_drive.sh). Nothing was written.")

    disk = Disk(device, writable=True)
    plan: list[tuple[str, int, bytes]] = []            # (phase, disk offset, new bytes), in write order

    def bitmap_writes(phase: str, bits: dict[int, bool], current: bytearray) -> None:
        touched = sorted({(c - 2) // 8 for c in bits})
        for c, on in bits.items():
            i = c - 2
            if on:
                current[i // 8] |= 1 << (i % 8)
            else:
                current[i // 8] &= ~(1 << (i % 8)) & 0xFF
        for b in touched:
            ci, within = divmod(b, cs)
            plan.append((phase, vol.offset(bm_clusters[ci]) + within, bytes(current[b:b + 1])))

    def fat_write(phase: str, c: int, value: int) -> None:
        plan.append((phase, vol.fat_offset + 4 * c, struct.pack("<I", value)))

    boot = bytearray(vol._read(0, 512))
    was_dirty = bool(xi.u16(boot, 106) & 2)
    plan.append(("mark the drive in use", 106, struct.pack("<H", xi.u16(boot, 106) | 2)))
    for nd in movers:                                   # 1. copy each list into free space
        pos = 0
        for first, count in segments(nd.new):
            plan.append(("copy", vol.offset(first), bytes(nd.buf[pos:pos + count * cs])))
            pos += count * cs
    for nd in movers:                                   # 2. chain the new clusters (the only way to a list in
        for a, b in zip(nd.new, nd.new[1:] + [None]):   #    pieces; harmless for one marked contiguous)
            fat_write("chain the copies", a, b if b is not None else EOC)
    bitmap = bytearray(vol.bitmap[:bm_len])
    bitmap_writes("mark the copies used", {c: True for c in dest}, bitmap)        # 3.
    for par, buf in parent_bufs.values():               # 4. repoint the records (the switch-over)
        orig = vol.read_clusters(par.clusters, par.length)
        diff = [k for k in range(0, len(buf), 32) if buf[k:k + 32] != orig[k:k + 32]]
        for k in diff:
            for off, a, b in entry_ranges(vol, par.clusters, k, k + 32):
                plan.append(("repoint", off, bytes(buf[a:b])))
    old = {c: False for nd in movers for c in nd.clusters if c not in dest_set}
    bitmap_writes("free the old lists", old, bitmap)                              # 5.
    for nd in movers:
        if not nd.item.no_fat_chain:
            for c in nd.clusters:
                if c not in dest_set:
                    fat_write("free the old lists", c, 0)
    if not was_dirty:
        plan.append(("mark the drive clean", 106, struct.pack("<H", xi.u16(boot, 106) & ~2 & 0xFFFF)))

    # Undo file: the original bytes of everything but the copies (those land in free space).
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    undo_path = os.path.abspath(f"relocate-undo-{stamp}.json")
    serial = xi.u32(boot, 100)
    records, seen = [], set()
    for phase, off, data in plan:
        if phase == "copy" or (off, len(data)) in seen:
            continue
        seen.add((off, len(data)))
        records.append({"off": off, "old": disk.read(off, len(data)).hex()})
    with open(undo_path, "w") as f:
        json.dump({"device": device, "serial": serial, "made": stamp, "records": records}, f)
        f.flush()
        os.fsync(f.fileno())
    print(f"Undo file: {undo_path}")

    last = None
    for phase, off, data in plan:
        if phase != last:
            if last is not None:
                disk.flush()
            print(f"  {phase}…")
            last = phase
        disk.write(off, data)
    disk.flush()

    # Verify: read every moved folder back from its new place.
    xi._root_cache = None
    xi.KEEP_RAW = False
    check = xi.Volume(device)
    bad = []
    moved_first = {(n.parent.path, n.item.name): n.new[0] for n in movers}
    moved_len = {(n.parent.path, n.item.name): len(n.new) * cs for n in movers}
    for nd in movers:
        rep, why = xi.resolve(check, nd.path)
        if rep is None:
            bad.append(f"{nd.path}: {why}")
            continue
        want = [(i.name, moved_first.get((nd.path, i.name), i.first), moved_len.get((nd.path, i.name), i.length))
                for i in nd.rep.items]
        got = [(i.name, i.first, i.length) for i in rep.items]
        if rep.dir_clusters != nd.new or got != want:
            bad.append(f"{nd.path}: reads back differently")
    ok, out = fsck(device)
    print(f"\nMoved {len(movers) - len(bad)} of {len(movers)} folder lists below the line.")
    for b in bad:
        print(f"  PROBLEM {b}")
    print("macOS's check of the drive afterwards: " + ("clean." if ok else f"found problems:\n{out}"))
    if bad or not ok:
        print(f"To put everything back: sudo python3 mac/relocate_folders.py --device {device} --undo {undo_path}")
    else:
        print("Eject the SSD in Finder, plug it into the iPhone, and run Drive Health.")


def undo(path: str, device: str, mount: str | None) -> None:
    with open(path) as f:
        u = json.load(f)
    if mount:
        code, out = run(["diskutil", "unmount", mount])
        if code != 0:
            sys.exit(f"Couldn't unmount the SSD.\n{out}")
    try:
        disk = Disk(device, writable=True)
        if xi.u32(disk.read(0, 512), 100) != u["serial"]:
            sys.exit("This undo file belongs to a different drive — nothing was written.")
        for r in reversed(u["records"]):
            disk.write(r["off"], bytes.fromhex(r["old"]))
        disk.flush()
        print(f"Put back {len(u['records'])} changed regions.")
        ok, out = fsck(device)
        print("macOS's check of the drive: " + ("clean." if ok else f"found problems:\n{out}"))
    finally:
        if mount:
            run(["diskutil", "mount", device.replace("/dev/rdisk", "/dev/disk")])


if __name__ == "__main__":
    main()
