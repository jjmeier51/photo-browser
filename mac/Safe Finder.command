#!/bin/sh
# Double-click in Finder to open Safe Finder (moves files onto the SSD safely).
# The first run sets up mac/.venv with PySide6 — takes a minute or two, once.
cd "$(dirname "$0")" || exit 1
if [ ! -x .venv/bin/python ] || ! .venv/bin/python -c "import PySide6" 2>/dev/null; then
  echo "First run: installing what Safe Finder needs into mac/.venv …"
  python3 -m venv .venv && .venv/bin/pip install --quiet --upgrade pip && .venv/bin/pip install --quiet -r requirements.txt || {
    echo "Setup failed — see the messages above. Press Return to close."; read -r _; exit 1; }
fi
exec .venv/bin/python safe_finder.py "$@"
