#!/bin/sh
# Launch Photo Browser for Mac from a terminal (the same as double-clicking "Photo Browser for Mac.command").
# First run creates a virtualenv and installs the dependencies.
#
#   ./run.sh                 the app
#   ./run.sh --bulk-editor   the earlier, smaller bulk editor (bulk_editor/ — EXIF, dates and file names in tables)
set -e
cd "$(dirname "$0")"
if [ ! -d .venv ]; then
  python3 -m venv .venv
  .venv/bin/pip install --quiet --upgrade pip
  .venv/bin/pip install --quiet -r requirements.txt
fi
if ! command -v exiftool >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/exiftool ] && [ ! -x /usr/local/bin/exiftool ]; then
  echo "Note: exiftool not found — install it with 'brew install exiftool' to edit metadata." >&2
fi
if [ "${1:-}" = "--bulk-editor" ]; then
  shift
  exec .venv/bin/python -m bulk_editor "$@"
fi
exec .venv/bin/python photo_browser.py "$@"
