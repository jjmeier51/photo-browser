#!/usr/bin/env python3
"""Find what makes iOS refuse to open certain folders on the exFAT SSD.

Background: after a clean `fsck_exfat`, Photo Browser's Drive Health still lists folders iOS can't
open ("opendir errno 22 — Invalid argument") although macOS shows their contents. That's Apple's
FSKit exFAT driver rejecting something *inside* the folder (renaming the folder itself didn't help).
The usual suspects are file names: Unicode forms (decomposed accents), emoji / characters outside the
basic plane, invisible characters, characters exFAT forbids, names that collide once case and
Unicode form are ignored, undecodable bytes, very long names.

This script reads those folders on the Mac (which can), flags every unusual name, and compares how
common each flag is in the failing folders versus a sample of healthy ones — so the trigger shows
up as "in (nearly) every failing folder, (nearly) no healthy one". Read-only; changes nothing.

Usage:
  python3 diagnose_ios_unreadable.py --list unreadable.txt --root "/Volumes/Extreme SSD"
  (unreadable.txt = the list Drive Health's Share button exports)
"""

from __future__ import annotations

import argparse
import os
import random
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

ILLEGAL = set('"*/:<>?\\|')
INVISIBLE = {0x00A0: "no-break space", 0x202F: "narrow no-break space", 0x2009: "thin space",
             0x200B: "zero-width space", 0x200C: "zero-width non-joiner", 0x200D: "zero-width joiner",
             0xFEFF: "BOM", 0xFE0F: "emoji variation selector", 0x2028: "line separator",
             0x00AD: "soft hyphen"}

FLAG_HELP = {
    "decomposed": "Unicode decomposed form (NFD) — e.g. an accent stored as a separate mark",
    "astral": "characters outside the basic plane (most emoji)",
    "private-use": "private-use characters (how macOS stores : / * ? etc. it can't put on exFAT)",
    "illegal": "characters exFAT forbids (\" * / : < > ? \\ | or control characters)",
    "invisible": "invisible / special spaces (no-break, zero-width, variation selector…)",
    "undecodable": "bytes that aren't valid UTF-8 (shown with \\udcXX escapes)",
    "trailing": "name ends with a space or a dot",
    "leading-space": "name starts with a space",
    "long": "name longer than 200 UTF-16 units (exFAT max 255)",
    "collision": "two names in the folder that differ only by case or Unicode form",
    "appledouble": "macOS ._ AppleDouble sidecar files",
    "non-ascii": "any non-ASCII character at all (broad — context only)",
}


def flags_for(name: str) -> set[str]:
    f: set[str] = set()
    if any(0xDC80 <= ord(c) <= 0xDCFF for c in name):
        f.add("undecodable")
    try:
        if unicodedata.normalize("NFC", name) != name:
            f.add("decomposed")
    except ValueError:
        pass
    if any(ord(c) > 0xFFFF for c in name):
        f.add("astral")
    if any(0xE000 <= ord(c) <= 0xF8FF for c in name):
        f.add("private-use")
    if any(c in ILLEGAL or ord(c) < 0x20 or ord(c) == 0x7F for c in name):
        f.add("illegal")
    if any(ord(c) in INVISIBLE for c in name):
        f.add("invisible")
    if name.endswith((" ", ".")) and name not in (".", ".."):
        f.add("trailing")
    if name.startswith(" "):
        f.add("leading-space")
    if len(name.encode("utf-16-le", "surrogatepass")) // 2 > 200:
        f.add("long")
    if name.startswith("._"):
        f.add("appledouble")
    if any(ord(c) > 127 for c in name):
        f.add("non-ascii")
    return f


def scan(folder: Path) -> tuple[int, dict[str, list[str]]]:
    """(entry count, flag → example names) for one folder's own entries."""
    try:
        names = os.listdir(folder)
    except OSError as e:
        return -1, {"unreadable-on-mac": [str(e)]}
    found: dict[str, list[str]] = defaultdict(list)
    keys: dict[str, list[str]] = defaultdict(list)
    for n in names:
        for fl in flags_for(n):
            found[fl].append(n)
        try:
            keys[unicodedata.normalize("NFC", n).casefold()].append(n)
        except ValueError:
            pass
    for group in keys.values():
        if len(group) > 1:
            found["collision"].extend(group)
    return len(names), found


def describe(n: str) -> str:
    odd = [f"U+{ord(c):04X}" for c in n if ord(c) > 127 or ord(c) < 0x20]
    return f"{n!r}" + (f"  [{', '.join(dict.fromkeys(odd))}]" if odd else "")


def main() -> None:
    ap = argparse.ArgumentParser(description="Diagnose folders iOS can't open on the exFAT SSD (read-only).")
    ap.add_argument("--list", type=Path, required=True, help="Drive Health's exported unreadable-folder list")
    ap.add_argument("--root", type=Path, required=True, help='the SSD, e.g. "/Volumes/Extreme SSD"')
    ap.add_argument("--sample", type=int, default=300, help="healthy folders to compare against (default 300)")
    args = ap.parse_args()
    if not args.root.is_dir():
        sys.exit(f"Not mounted: {args.root}")

    rels = [l.strip().strip("/") for l in args.list.read_text("utf-8").splitlines() if l.strip()]
    bad = [args.root / r for r in rels]
    bad_set = {p.resolve() for p in bad if p.exists()}

    print(f"== Failing folders ({len(bad)}) ==")
    bad_flags = Counter()
    for p, rel in zip(bad, rels):
        if not p.is_dir():
            print(f"\n{rel}: not found on the Mac")
            continue
        count, found = scan(p)
        print(f"\n{rel}  ({count} entries)")
        for fl in found:
            bad_flags[fl] += 1
        for fl, names in sorted(found.items(), key=lambda kv: kv[0] == "non-ascii"):
            if fl == "non-ascii" and len(found) > 1:
                continue
            ex = "; ".join(describe(n) for n in names[:3])
            more = f" (+{len(names) - 3} more)" if len(names) > 3 else ""
            print(f"   {fl:13} {len(names):5}  e.g. {ex}{more}")
        if not found:
            print("   (no unusual names)")

    print(f"\n== Sampling up to {args.sample} healthy folders for comparison… ==")
    healthy: list[Path] = []
    for dirpath, dirnames, _ in os.walk(args.root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        here = Path(dirpath)
        if here == args.root or here.resolve() in bad_set:
            continue
        if any(str(here.resolve()).startswith(str(b) + os.sep) for b in bad_set):
            continue
        healthy.append(here)
    random.seed(1)
    sample = random.sample(healthy, min(args.sample, len(healthy)))
    good_flags = Counter()
    for p in sample:
        _, found = scan(p)
        for fl in found:
            good_flags[fl] += 1

    nb, ng = max(1, len(bad_set)), max(1, len(sample))
    print(f"\n== How often each kind of name appears ==\n{'flag':14} {'failing':>9} {'healthy':>9}")
    rows = sorted(set(bad_flags) | set(good_flags), key=lambda k: -(bad_flags[k] / nb - good_flags[k] / ng))
    for fl in rows:
        print(f"{fl:14} {100 * bad_flags[fl] / nb:8.0f}% {100 * good_flags[fl] / ng:8.0f}%   {FLAG_HELP.get(fl, '')}")
    suspects = [fl for fl in rows if fl != "non-ascii" and bad_flags[fl] / nb >= 0.6 and good_flags[fl] / ng <= 0.15]
    print()
    if suspects:
        print("Likely trigger(s): " + ", ".join(suspects))
        print("These kinds of names appear in most failing folders and few healthy ones.")
    else:
        print("No name pattern separates the failing folders from healthy ones — the trigger is probably")
        print("in the folder's on-disk layout, not its names; rebuild one folder as a test:")
        print('  python3 mac/rebuild_exfat_folders.py "/Volumes/<SSD>/<one failing folder>" --apply')
    print("\nPaste this whole output back to Claude.")


if __name__ == "__main__":
    main()
