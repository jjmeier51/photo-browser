#!/usr/bin/env python3
"""Take the characters exFAT and iOS can't handle out of every file and folder name under a folder.

The characters are \\ / : * ? " < > | and control characters — the same ones Safe Finder replaces with
"-" when it copies to the SSD ("28 names adjusted so iOS can read them"). Cleaning a folder on the Mac
first means the names arrive on the SSD exactly as you see them. By default the characters are
removed ("JAV: Episode 3" → "JAV Episode 3", "What's next?.jpg" → "What's next.jpg"); where removing
one would glue two words or numbers together it becomes a space ("1:2" → "1 2"). --dash replaces each
with "-" instead, exactly like Safe Finder. Also, like Safe Finder: accents are stored in the standard
form, trailing dots and spaces go, and names over 255 characters are shortened (keeping the
extension). A "/" shown in a Finder name counts too — macOS stores it as ":".

Dry run by default. --apply renames, deepest items first, never overwriting anything (a clash gets
" (2)", " (3)" …), and writes a log next to where you run it; --undo LOG puts every name back.
macOS's "._" companion files are left to macOS, which renames them along with their file.

On the SSD itself it asks for --on-drive: renaming there changes paths, and the iPhone app keeps
Favorites, covers and captions by path — reattach them afterwards with Drive Health ▸ Re-link.

  python3 mac/clean_names.py ~/Pictures/PornPics                 # dry run: what would change
  python3 mac/clean_names.py ~/Pictures/PornPics --apply
  python3 mac/clean_names.py --undo clean-names-20261011-140000.tsv
"""

from __future__ import annotations

import argparse
import datetime
import os
import re
import subprocess
import sys
import unicodedata

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from safe_copy_to_ssd import EXFAT_ILLEGAL, safe_name  # noqa: E402


def bad(c: str) -> bool:
    return c in EXFAT_ILLEGAL or ord(c) < 0x20 or ord(c) == 0x7F


def clean(name: str, dash: bool) -> str:
    n = unicodedata.normalize("NFC", name)
    if dash:
        return safe_name(n)
    out = []
    for i, c in enumerate(n):
        if not bad(c):
            out.append(c)
            continue
        before = out[-1] if out else ""
        after = next((d for d in n[i + 1:] if not bad(d)), "")
        if before.isalnum() and after.isalnum():
            out.append(" ")                               # don't glue "1:2" into "12"
    n = re.sub(r" {2,}", " ", "".join(out))
    stem, dot, ext = n.rpartition(".")
    if dot and stem:                                      # no stray space before the extension
        n = stem.rstrip(" ") + "." + ext
    return safe_name(n.strip(" ") or "untitled")


def filesystem(path: str) -> str:
    """The filesystem type of the volume holding `path` ("apfs", "exfat", …) from `mount`."""
    try:
        out = subprocess.run(["mount"], capture_output=True, text=True).stdout
    except OSError:
        return ""
    best, kind = "", ""
    for line in out.splitlines():
        m = re.match(r".+? on (.+) \(([^,)]+)", line)
        if m and (path == m.group(1) or path.startswith(m.group(1).rstrip("/") + "/")) and len(m.group(1)) > len(best):
            best, kind = m.group(1), m.group(2)
    return kind.lower()


def free_name(folder: str, wanted: str, current: str) -> str:
    """`wanted`, or "wanted (2)" … if another item in `folder` already has that name."""
    stem, dot, ext = wanted.rpartition(".")
    if not dot or not stem:
        stem, ext = wanted, ""
    n = 1
    while True:
        cand = wanted if n == 1 else f"{stem} ({n})" + (f".{ext}" if ext else "")
        target = os.path.join(folder, cand)
        if not os.path.lexists(target) or os.path.samefile(target, os.path.join(folder, current)):
            return cand
        n += 1


def rename(old: str, new: str) -> None:
    """Rename, going through a temporary name when only accents' encoding or letter case changes —
    a filesystem that treats both names as the same file would otherwise ignore the change."""
    if os.path.lexists(new) and os.path.samefile(old, new):
        tmp = os.path.join(os.path.dirname(old), f".clean-names-{os.getpid()}")
        os.rename(old, tmp)
        os.rename(tmp, new)
    else:
        os.rename(old, new)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", nargs="?", help="the folder to clean (everything inside it, at any depth)")
    ap.add_argument("--apply", action="store_true", help="really rename (default: dry run)")
    ap.add_argument("--dash", action="store_true", help='replace each character with "-" (like Safe Finder)')
    ap.add_argument("--on-drive", action="store_true", help="allow it on the exFAT SSD (paths change — see above)")
    ap.add_argument("--include-top", action="store_true", help="also clean the name of the folder itself")
    ap.add_argument("--undo", metavar="LOG", help="put back every name a previous --apply changed")
    args = ap.parse_args()

    if args.undo:
        with open(args.undo, encoding="utf-8") as f:
            pairs = [line.rstrip("\n").split("\t") for line in f if "\t" in line]
        done = 0
        for old, new in reversed(pairs):
            if os.path.lexists(new) and not os.path.lexists(old):
                rename(new, old)
                done += 1
            else:
                print(f"  can't put back: {new}")
        print(f"Put back {done} of {len(pairs)} names.")
        return

    if not args.folder:
        ap.error("pass a folder")
    top = os.path.abspath(os.path.expanduser(args.folder))
    if not os.path.isdir(top):
        sys.exit(f"{top} isn't a folder")
    fs = filesystem(top)
    if fs in ("exfat", "msdos") and not args.on_drive:
        sys.exit(f"{top} is on the {fs} drive. Renaming there changes paths, so the iPhone app's Favorites, "
                 "covers and captions on renamed items need Drive Health ▸ Re-link afterwards. "
                 "Add --on-drive if you want that.")

    plan: list[tuple[str, str]] = []                      # (folder, old name) → cleaned later, deepest first
    for folder, dirs, files in os.walk(top, topdown=False):
        for name in files + dirs:
            if name.startswith("._"):
                continue
            if clean(name, args.dash) != name:
                plan.append((folder, name))
    if args.include_top and clean(os.path.basename(top), args.dash) != os.path.basename(top):
        plan.append((os.path.dirname(top), os.path.basename(top)))

    if not plan:
        print("Every name is already fine.")
        return
    for folder, name in plan:
        rel = os.path.relpath(os.path.join(folder, name), top)
        new = clean(name, args.dash)
        same = unicodedata.normalize("NFC", name) == new
        print(f"  {rel}\n    → {new}" + ("   (accents re-encoded; looks the same)" if same else ""))
    print(f"\n{len(plan)} name(s) to change.")
    if not args.apply:
        print("Dry run — nothing renamed. Add --apply to do it.")
        return

    log = os.path.abspath(datetime.datetime.now().strftime("clean-names-%Y%m%d-%H%M%S.tsv"))
    done = 0
    with open(log, "w", encoding="utf-8") as f:
        for folder, name in plan:
            old = os.path.join(folder, name)
            new = os.path.join(folder, free_name(folder, clean(name, args.dash), name))
            try:
                rename(old, new)
            except OSError as e:
                print(f"  couldn't rename {old}: {e}")
                continue
            f.write(f"{old}\t{new}\n")
            f.flush()
            done += 1
    print(f"Renamed {done} of {len(plan)}. Log (for --undo): {log}")


if __name__ == "__main__":
    main()
