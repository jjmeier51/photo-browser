#!/bin/sh
# Check and repair the Photo Browser SSD's exFAT file system on the Mac.
#
# Why: folders whose exFAT directory entries are damaged (e.g. "Directory /X/AI has zero length",
# "cluster chain … overlaps", "unexpected critical primary directory entry" — see
# docs/feature-notes.md §12) are still shown by macOS but can't be read by iOS: on the iPhone/iPad
# they're missing, look empty, or can't be saved into. Copying a folder (rebuild_exfat_folders.py)
# can't fix a damaged parent directory or a cross-linked FAT; Apple's fsck_exfat can. This runs the
# same check as Disk Utility ▸ First Aid, first read-only, then (after you confirm) the repair.
#
# Usage:  sh mac/repair_drive.sh /Volumes/<SSD name>
set -eu

VOL="${1:-}"
if [ -z "$VOL" ] || [ ! -d "$VOL" ]; then
  echo "usage: sh $0 /Volumes/<SSD name>" >&2
  echo "Mounted volumes:" >&2; ls /Volumes >&2
  exit 1
fi

diskutil info "$VOL" | grep -E "Volume Name|Device Node|File System Personality" || true
FS=$(diskutil info "$VOL" | awk -F: '/File System Personality/ {gsub(/^ +/, "", $2); print $2}')
case "$FS" in
  *ExFAT*|*exFAT*|*MS-DOS*|*FAT*) ;;
  *) echo "Note: this volume is \"$FS\", not exFAT/FAT — the iOS folder problem this fixes is exFAT-specific." ;;
esac

echo
echo "== 1/2 Checking (read-only) =="
if diskutil verifyVolume "$VOL"; then
  echo
  echo "No file-system errors found. If folders still look empty or missing on iOS, run"
  echo "  python3 mac/rebuild_exfat_folders.py \"<that folder>\" --apply"
  echo "on just those folders, then eject the SSD in Finder before unplugging it."
  exit 0
fi

echo
printf "Errors were found. Repair now? The SSD is unmounted while it runs; close anything using it. [y/N] "
read -r answer
case "$answer" in y|Y|yes|YES) ;; *) echo "Not repaired."; exit 1 ;; esac

echo
echo "== 2/2 Repairing =="
diskutil repairVolume "$VOL"
echo
echo "Done. Eject the SSD in Finder (don't just unplug it), connect it to the iPhone/iPad, and open"
echo "Photo Browser — the folders iOS couldn't read should now appear with their contents."
echo "Then run Settings ▸ Maintenance ▸ Drive Health in the app to confirm nothing is left."
