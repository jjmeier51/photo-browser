#!/bin/sh
# Launch Photo Browser for Mac. First run creates a virtualenv and installs the dependencies.
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
exec .venv/bin/python -m photobrowser_mac "$@"
