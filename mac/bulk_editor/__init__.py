"""Photo Browser Bulk Editor — the first Mac companion to the iOS Photo Browser app, kept beside its successor.

(It was "Photo Browser for Mac" until November 2026, when the app in `photo_browser.py` — which does all of this
and far more — took that name. Run it with `./run.sh --bulk-editor` or `python -m bulk_editor`.)

Connect an SSD (or any folder), browse it with the same dark, square-tile look as the iOS app,
and bulk-edit what the phone can't comfortably do at scale: EXIF fields, capture dates, filenames
and captions. Metadata is read and written with ExifTool; thumbnails are cached on disk.
"""

__version__ = "1.0.0"
APP_NAME = "Photo Browser Bulk Editor"
