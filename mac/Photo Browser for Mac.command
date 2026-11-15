#!/bin/sh
# Double-click in Finder to open Photo Browser for Mac (browse the SSD, and move files onto it safely).
# The first run sets up mac/.venv with PySide6 — takes a minute or two, once.
cd "$(dirname "$0")" || exit 1
if [ ! -x .venv/bin/python ] || ! .venv/bin/python -c "import PySide6, numpy" 2>/dev/null; then
  echo "Installing what Photo Browser for Mac needs into mac/.venv …"
  python3 -m venv .venv && .venv/bin/pip install --quiet --upgrade pip && .venv/bin/pip install --quiet -r requirements.txt || {
    echo "Setup failed — see the messages above. Press Return to close."; read -r _; exit 1; }
fi
# Make Book PDF (bookify.py) needs ReportLab and pyphen: added later, so an existing .venv gets them here — quietly,
# and never in the way (offline, Photo Browser for Mac still opens; the Make Book window offers to install them again).
.venv/bin/python -c "import reportlab, pyphen" 2>/dev/null || .venv/bin/pip install --quiet "reportlab>=4.0" "pyphen>=0.14" 2>/dev/null || true
# People (faces.py) needs onnxruntime: added later too, so an existing .venv gets it the same way.
.venv/bin/python -c "import onnxruntime" 2>/dev/null || .venv/bin/pip install --quiet "onnxruntime>=1.17" 2>/dev/null || true
exec .venv/bin/python photo_browser.py "$@"
