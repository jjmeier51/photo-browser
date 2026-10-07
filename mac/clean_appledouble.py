#!/usr/bin/env python3
"""Remove orphaned macOS "._" AppleDouble files from folders on the exFAT SSD.

macOS can't store extended attributes on exFAT, so it writes a hidden "._<name>" sidecar next to
every file it tags (quarantine, "where from", Finder tags…). When the real file is later deleted or
renamed — or was only ever a temporary ".sb-…" atomic-save file — the sidecar is left behind.
In Photo Browser's biggest folders half of all entries are such sidecars (Kendall Jenner: 46,435 of
92,870), and iOS fails to open folders that large. Orphans (sidecar whose file is gone) carry nothing
useful, so removing them is safe; `--all` also removes sidecars of files that still exist (that drops
their Finder tags / quarantine / "where from" — the photos themselves are untouched).

Dry run unless --apply.
  python3 clean_appledouble.py "/Volumes/Extreme SSD/Kardashians/Kendall Jenner"
  python3 clean_appledouble.py "/Volumes/Extreme SSD/Kardashians" --recursive --apply
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path


def clean(folder: Path, apply: bool, include_live: bool) -> tuple[int, int, int]:
    """(orphans, live sidecars, entries before) for one folder's own entries."""
    try:
        names = os.listdir(folder)
    except OSError as e:
        print(f"  can't read {folder}: {e}")
        return 0, 0, 0
    present = set(names)
    orphans = live = 0
    for n in names:
        if not n.startswith("._"):
            continue
        base = n[2:]
        is_orphan = base not in present
        if not is_orphan and not include_live:
            live += 1
            continue
        if is_orphan:
            orphans += 1
        else:
            live += 1
        if apply:
            try:
                os.remove(folder / n)
            except OSError as e:
                print(f"  couldn't remove {n}: {e}")
    return orphans, live, len(names)


def main() -> None:
    ap = argparse.ArgumentParser(description="Remove orphaned ._ AppleDouble files (dry run unless --apply).")
    ap.add_argument("folders", nargs="+", type=Path)
    ap.add_argument("--recursive", action="store_true", help="also every subfolder")
    ap.add_argument("--all", action="store_true", help="also remove sidecars of files that still exist")
    ap.add_argument("--apply", action="store_true", help="actually delete (default: just count)")
    args = ap.parse_args()

    total_o = total_l = 0
    for root in args.folders:
        if not root.is_dir():
            sys.exit(f"Not a folder: {root}")
        dirs = [root]
        if args.recursive:
            for d, sub, _ in os.walk(root):
                sub[:] = [s for s in sub if not s.startswith(".")]
                if Path(d) != root:
                    dirs.append(Path(d))
        for d in dirs:
            o, l, n = clean(d, args.apply, args.all)
            if o or (args.all and l):
                removed = o + (l if args.all else 0)
                verb = "removed" if args.apply else "would remove"
                print(f"{d}: {verb} {removed} of {n} entries ({o} orphaned"
                      + (f", {l} of existing files" if args.all else f"; {l} sidecars of existing files kept") + ")")
            total_o += o
            total_l += l
    print(f"\nOrphaned sidecars: {total_o}" + ("" if args.apply else "  (dry run — add --apply)"))
    if args.apply:
        print("Eject the SSD in Finder before unplugging it.")


if __name__ == "__main__":
    main()
