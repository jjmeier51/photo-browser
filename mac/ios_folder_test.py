#!/usr/bin/env python3
"""Make a few tiny test folders on the SSD, each written a different way, to find out which way of
writing gives a folder iOS can't open ("opendir errno 22" in Drive Health).

The folders iOS rejects look clean on disk (exfat_inspect.py finds nothing wrong in their records),
and each theory so far — flushing folders, moving files, where on the drive a folder sits — has been
contradicted by a later test. A controlled test settles it: every folder here holds the same small
photo and differs only in how it was written. Plug the SSD into the iPhone and see which ones open,
then dump the raw records of all of them with `exfat_inspect.py --dump`. The bytes that differ
between the ones that open and the ones that don't point at the cause.

Writes only its own "iOS Test …" folders at the top of the drive; --remove deletes them again.

  python3 mac/ios_folder_test.py "/Volumes/Extreme SSD"
  python3 mac/ios_folder_test.py "/Volumes/Extreme SSD" --remove
"""

from __future__ import annotations

import argparse
import base64
import os
import shutil
import subprocess
import sys
import tempfile

PHOTO = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAA0JCgsKCA0LCgsODg0PEyAVExISEyccHhcgLikxMC4pLSwzOko+MzZGNywtQFdBRkxO"
    "UlNSMj5aYVpQYEpRUk//2wBDAQ4ODhMREyYVFSZPNS01T09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09P"
    "T09PT09PT0//wAARCABgAGADASIAAhEBAxEB/8QAGQABAAMBAQAAAAAAAAAAAAAAAAMFBgQC/8QALRAAAgICAAUCBAYDAAAAAAAA"
    "AAECAwQRBhIhMUFRoQUTI3EkYYGRwdHh8PH/xAAbAQEAAgMBAQAAAAAAAAAAAAAAAQQDBgcFAv/EACgRAAICAQMCBAcAAAAAAAAA"
    "AAABAgQDESExBVETQZGhEhQyM3GBsf/aAAwDAQACEQMRAD8ArQAbCeOAAAAAAAAAAAAAAAAAAAAAASUUW5FirprlOT8JFtRw7dOO"
    "77oVvS0ormf69v5Kli7Xrfdkl/fRbmbFXyZfoWpSgvLeHLFH6WTCUt9pRcVr3KnJxb8WfLkVSg3232f2fkivfrWXpimm/R+jGWvl"
    "xbzjoQgAuGEAAAAAAElFM8i+FNa3Kb0v7Iy64apU8m256brikk15fn29ypdsfLV5Zey9+F7mavi8XIody6wMGrBo+XX1k+s5vvJn"
    "SAc5yZJ5Zuc3q2bRGKglGK2BDlY1WXRKm6O4vs/KfqiYEQnKElKL0aEoqS0Zis7Fnh5UqJveuqlrXMvU5zQ8TUp0039FJS5H06tP"
    "r3/LXuZ46J0207VaOR8+f5RrNrD4WVxXAABeK4AAALzhixK6+rT5pRUl6aX/AEoybEyJYuVXfDq4PevVeV+xTv13ZrTxLlr3W6M1"
    "fL4WWM35G3BDi5NWXRG6mW4vuvKfoyY5zOEoScZLRo2iMlJaoAHi22umqVtslGEVttkJOT0XJLaS1ZUcTWJYtNWnzSnzL00l/kzh"
    "1/Esx52ZK7TUEuWCfdL/AHZyHQ+mVpVqsccueX+zWbeVZcrkuAAD0CsAAAAAAdGJmX4djnRPW9cyfVS+5c0cRVuP4iicZJLrBppv"
    "z31r3M8Cja6bWtPXJHfvwyxhtZcW0XsaO3iKhR+lRZKW+0morXuU+b8Qyc5r50koJ7UIrSTOQHzW6ZVrS+LHHfu9yctvLlWknsAA"
    "egVgAAAAAAAAAAAAAAAAAAAAD//Z"
)

PHOTO_NAME = "test photo.jpg"
TESTS = [
    ("iOS Test 1 - empty", "made with mkdir, nothing put in it"),
    ("iOS Test 2 - new file", "mkdir, then the photo written straight under its final name "
                              "(how Safe Finder and the copy rebuild write files)"),
    ("iOS Test 3 - moved in", "the photo written at the top of the drive, then moved into a new folder "
                              "(a same-drive move, like Finder or your NewFolder test)"),
    ("iOS Test 4 - rebuilt", "built as a hidden folder, then renamed into place "
                             "(exactly how the copy rebuild makes folders)"),
    ("iOS Test 5 - Mac copy", "the photo copied with macOS's own copier, cp — like Finder it brings the "
                              "file's extended attributes along, so it also writes a ._ file"),
]
STRAY = [".iOS Test 4 - rebuilt.tmp", "iOS Test 3 incoming.jpg"]


def write_new(path: str) -> None:
    """Create the file fresh under its final name, no flush — the copy rebuild's way."""
    with open(path, "xb") as f:
        f.write(PHOTO)


def make(root: str) -> None:
    for name, _ in TESTS:
        if os.path.lexists(os.path.join(root, name)):
            sys.exit(f"“{name}” already exists — run with --remove first.")
    os.mkdir(os.path.join(root, TESTS[0][0]))

    t2 = os.path.join(root, TESTS[1][0])
    os.mkdir(t2)
    write_new(os.path.join(t2, PHOTO_NAME))

    t3 = os.path.join(root, TESTS[2][0])
    incoming = os.path.join(root, STRAY[1])
    write_new(incoming)
    os.sync()                                   # the photo exists on disk before it is moved, like a real file
    os.mkdir(t3)
    os.rename(incoming, os.path.join(t3, PHOTO_NAME))

    hidden = os.path.join(root, STRAY[0])
    os.mkdir(hidden)
    write_new(os.path.join(hidden, PHOTO_NAME))
    os.sync()
    os.rename(hidden, os.path.join(root, TESTS[3][0]))

    t5 = os.path.join(root, TESTS[4][0])
    os.mkdir(t5)
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, PHOTO_NAME)
        with open(src, "wb") as f:
            f.write(PHOTO)
        if shutil.which("xattr"):               # what a downloaded photo carries on a Mac
            subprocess.run(["xattr", "-w", "com.apple.metadata:kMDItemWhereFroms", "ios_folder_test", src],
                           check=False)
        subprocess.run(["cp", src, os.path.join(t5, PHOTO_NAME)], check=True)
    os.sync()

    print("Made these folders at the top of the drive:\n")
    for name, how in TESTS:
        print(f"  {name:24} {how}")
    print(f"""
Next:
 1. Read the raw records now, before anything else touches them (read-only), and keep the output:
      sudo python3 mac/exfat_inspect.py --dump --sample 0 {' '.join(f'"{os.path.join(root, n)}"' for n, _ in TESTS)}
 2. Eject the SSD in Finder, plug it into the iPhone, open Photo Browser and run Drive Health.
    Note which "iOS Test" folders it lists as unreadable. (Tests 2-5 should each show one photo
    when opened; test 1 is empty either way, so only Drive Health can tell about it.)
 3. Paste both to Claude. Afterwards: python3 mac/ios_folder_test.py "{root}" --remove""")


def remove(root: str) -> None:
    gone = 0
    for name in [n for n, _ in TESTS] + STRAY:
        p = os.path.join(root, name)
        if os.path.isdir(p) and not os.path.islink(p):
            shutil.rmtree(p)
            gone += 1
        elif os.path.lexists(p):
            os.remove(p)
            gone += 1
    os.sync()
    print(f"Removed {gone} test item(s).")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("drive", help='the SSD, e.g. "/Volumes/Extreme SSD"')
    ap.add_argument("--remove", action="store_true", help="delete the test folders again")
    args = ap.parse_args()
    root = os.path.abspath(args.drive)
    if not os.path.isdir(root):
        sys.exit(f"{root} isn't a folder")
    if sys.platform == "darwin" and not os.path.ismount(root):
        sys.exit(f"{root} isn't the top of a drive — pass the SSD itself, e.g. \"/Volumes/Extreme SSD\"")
    remove(root) if args.remove else make(root)


if __name__ == "__main__":
    main()
