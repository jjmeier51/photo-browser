#!/usr/bin/env python3
"""PornPics gallery downloader — a small desktop tool (tkinter, standard library only).

Paste a gallery URL such as
    https://www.pornpics.com/galleries/beautiful-woman-posing-48115884/
and every full-size photo in it is saved into a folder named after the gallery
("Beautiful Woman Posing") inside the destination you choose.

How it finds the photos: the gallery page lists each picture as an anchor
(`<a class='rel-link' href='https://cdni.pornpics.com/1280/…/48115884_008_9394.jpg'>`).
The 1280 path is the full-size image; the matching 460 path is the thumbnail. We take the
anchors in page order (falling back to any `cdni.pornpics.com` link on the page, upgraded
from /460/ to /1280/), de-duplicate them and download with a browser-like User-Agent and
the gallery as Referer. Files that already exist with a non-zero size are skipped, so a
re-run only fetches what's missing.

Run:  python3 pornpics_downloader.py
"""

from __future__ import annotations

import html
import os
import queue
import re
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

try:  # Tk ships with python.org and Xcode's python3; Homebrew needs `brew install python-tk`.
    import tkinter as tk
    from tkinter import filedialog, messagebox, ttk
except ModuleNotFoundError:  # pragma: no cover - the download logic still imports for tests/CLI
    tk = None  # type: ignore[assignment]

USER_AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")
GALLERY_RE = re.compile(r"^https?://(?:www\.)?pornpics\.com/galleries/([a-z0-9-]+?)-?(\d+)/?(?:[?#].*)?$", re.I)
REL_LINK_RE = re.compile(r"<a\s[^>]*class=['\"]rel-link['\"][^>]*href=['\"](https?://cdni\.pornpics\.com/[^'\"]+)['\"]", re.I)
ANY_CDN_RE = re.compile(r"https?://cdni\.pornpics\.com/\d+/[^\s'\"<>]+?\.(?:jpe?g|png|webp|gif)", re.I)
TITLE_RE = re.compile(r"<h1[^>]*>(.*?)</h1>", re.I | re.S)
SMALL_WORDS = {"a", "an", "and", "as", "at", "but", "by", "for", "in", "of", "on", "or", "the", "to", "with"}
FORBIDDEN = '\\/:*?"<>|'


# ----------------------------------------------------------------------------- parsing


def gallery_name_from_url(url: str) -> str | None:
    """`…/galleries/beautiful-woman-posing-48115884/` → "Beautiful Woman Posing"."""
    m = GALLERY_RE.match(url.strip())
    if not m:
        return None
    words = [w for w in m.group(1).split("-") if w]
    out = []
    for i, w in enumerate(words):
        out.append(w if (i and w in SMALL_WORDS) else w.capitalize())
    return " ".join(out) or f"Gallery {m.group(2)}"


def gallery_id_from_url(url: str) -> str | None:
    m = GALLERY_RE.match(url.strip())
    return m.group(2) if m else None


def page_title(page: str) -> str | None:
    m = TITLE_RE.search(page)
    if not m:
        return None
    text = html.unescape(re.sub(r"<[^>]+>", "", m.group(1))).strip()
    return text or None


def full_size(url: str) -> str:
    """Thumbnail paths (/460/) point at the same file under /1280/."""
    return re.sub(r"(cdni\.pornpics\.com/)\d+/", r"\g<1>1280/", url, count=1)


def photo_urls(page: str) -> list[str]:
    """Full-size photo URLs in page order, de-duplicated."""
    found = [html.unescape(u) for u in REL_LINK_RE.findall(page)]
    if not found:
        found = [full_size(html.unescape(u)) for u in ANY_CDN_RE.findall(page)]
    seen: set[str] = set()
    out: list[str] = []
    for u in found:
        key = u.rsplit("/", 1)[-1].lower()
        if key not in seen:
            seen.add(key)
            out.append(u)
    return out


def safe_folder_name(name: str) -> str:
    cleaned = "".join("-" if c in FORBIDDEN else c for c in name).strip(" .")
    return cleaned[:150] or "Gallery"


# ----------------------------------------------------------------------------- network


def fetch(url: str, referer: str | None = None, timeout: int = 30) -> bytes:
    headers = {"User-Agent": USER_AGENT, "Accept": "*/*", "Accept-Language": "en-US,en;q=0.9"}
    if referer:
        headers["Referer"] = referer
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def download_gallery(url: str, dest_root: Path, folder_name: str, log, progress, stop: threading.Event) -> tuple[int, int, int]:
    """Download every photo of `url` into `dest_root/folder_name`. Returns (saved, skipped, failed)."""
    log(f"Fetching gallery page…")
    page = fetch(url).decode("utf-8", errors="replace")
    urls = photo_urls(page)
    if not urls:
        raise RuntimeError("No photos were found on that page. Is it a gallery URL?")
    title = page_title(page)
    if title:
        log(f"Page title: {title}")
    folder = dest_root / safe_folder_name(folder_name)
    folder.mkdir(parents=True, exist_ok=True)
    log(f"{len(urls)} photos → {folder}")
    saved = skipped = failed = 0
    for i, u in enumerate(urls, 1):
        if stop.is_set():
            log("Stopped.")
            break
        name = urllib.parse.unquote(u.rsplit("/", 1)[-1].split("?")[0])
        target = folder / name
        progress(i - 1, len(urls), name)
        if target.exists() and target.stat().st_size > 0:
            skipped += 1
            continue
        tmp = folder / (name + ".part")
        try:
            data = None
            for attempt in range(3):
                try:
                    data = fetch(u, referer=url)
                    break
                except (urllib.error.URLError, TimeoutError, OSError) as e:
                    if attempt == 2:
                        raise
                    log(f"  retry {attempt + 1} for {name}: {e}")
            if not data:
                raise RuntimeError("empty response")
            tmp.write_bytes(data)
            os.replace(tmp, target)
            saved += 1
        except Exception as e:  # noqa: BLE001 — one bad file must not stop the gallery
            failed += 1
            log(f"  failed {name}: {e}")
            try:
                tmp.unlink()
            except OSError:
                pass
    progress(len(urls), len(urls), "")
    return saved, skipped, failed


# ----------------------------------------------------------------------------- GUI


class App(tk.Tk if tk else object):  # type: ignore[misc]
    def __init__(self) -> None:
        super().__init__()
        self.title("PornPics Downloader")
        self.minsize(560, 420)
        self.events: queue.Queue = queue.Queue()
        self.stop = threading.Event()
        self.worker: threading.Thread | None = None
        default_dest = Path.home() / "Pictures" / "PornPics"
        self.dest = tk.StringVar(value=str(default_dest))
        self.url = tk.StringVar()
        self.folder = tk.StringVar()
        self.status = tk.StringVar(value="Paste a gallery URL.")
        self._auto_named = True
        self._build()
        self.url.trace_add("write", self._url_changed)
        self.after(100, self._pump)

    def _build(self) -> None:
        pad = {"padx": 10, "pady": 4}
        frm = ttk.Frame(self)
        frm.pack(fill="both", expand=True)
        frm.columnconfigure(1, weight=1)

        ttk.Label(frm, text="Gallery URL").grid(row=0, column=0, sticky="w", **pad)
        ttk.Entry(frm, textvariable=self.url).grid(row=0, column=1, columnspan=2, sticky="ew", **pad)

        ttk.Label(frm, text="Folder name").grid(row=1, column=0, sticky="w", **pad)
        e = ttk.Entry(frm, textvariable=self.folder)
        e.grid(row=1, column=1, columnspan=2, sticky="ew", **pad)
        e.bind("<KeyRelease>", lambda _e: setattr(self, "_auto_named", False))

        ttk.Label(frm, text="Save into").grid(row=2, column=0, sticky="w", **pad)
        ttk.Entry(frm, textvariable=self.dest).grid(row=2, column=1, sticky="ew", **pad)
        ttk.Button(frm, text="Choose…", command=self._choose).grid(row=2, column=2, sticky="e", **pad)

        row = ttk.Frame(frm)
        row.grid(row=3, column=0, columnspan=3, sticky="ew", **pad)
        self.btn = ttk.Button(row, text="Download", command=self._start)
        self.btn.pack(side="left")
        self.stop_btn = ttk.Button(row, text="Stop", command=self.stop.set, state="disabled")
        self.stop_btn.pack(side="left", padx=(8, 0))
        ttk.Button(row, text="Open folder", command=self._open_folder).pack(side="left", padx=(8, 0))
        ttk.Label(row, textvariable=self.status).pack(side="left", padx=(14, 0))

        self.bar = ttk.Progressbar(frm, mode="determinate")
        self.bar.grid(row=4, column=0, columnspan=3, sticky="ew", **pad)

        self.log = tk.Text(frm, height=12, wrap="word", state="disabled")
        self.log.grid(row=5, column=0, columnspan=3, sticky="nsew", padx=10, pady=(4, 10))
        frm.rowconfigure(5, weight=1)

    # -- events from the worker thread land on the Tk thread through the queue
    def _pump(self) -> None:
        try:
            while True:
                kind, payload = self.events.get_nowait()
                if kind == "log":
                    self._append(payload)
                elif kind == "progress":
                    done, total, name = payload
                    self.bar["maximum"] = max(1, total)
                    self.bar["value"] = done
                    self.status.set(f"{done}/{total}  {name}" if total else "")
                elif kind == "done":
                    saved, skipped, failed = payload
                    self._append(f"Done: {saved} saved, {skipped} already present, {failed} failed.")
                    self.status.set("Done.")
                    self._finish()
                elif kind == "error":
                    self._append(f"Error: {payload}")
                    self.status.set("Failed.")
                    self._finish()
        except queue.Empty:
            pass
        self.after(100, self._pump)

    def _append(self, line: str) -> None:
        self.log.configure(state="normal")
        self.log.insert("end", line + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def _url_changed(self, *_: object) -> None:
        if self._auto_named or not self.folder.get().strip():
            name = gallery_name_from_url(self.url.get())
            if name:
                self.folder.set(name)
                self._auto_named = True

    def _choose(self) -> None:
        d = filedialog.askdirectory(initialdir=self.dest.get() or str(Path.home()))
        if d:
            self.dest.set(d)

    def _open_folder(self) -> None:
        path = Path(self.dest.get()) / safe_folder_name(self.folder.get() or "")
        if not path.exists():
            path = Path(self.dest.get())
        if not path.exists():
            messagebox.showinfo("Open folder", "Nothing has been downloaded yet.")
            return
        if sys.platform == "darwin":
            os.system(f'open "{path}"')
        elif os.name == "nt":
            os.startfile(str(path))  # type: ignore[attr-defined]
        else:
            os.system(f'xdg-open "{path}"')

    def _start(self) -> None:
        url = self.url.get().strip()
        if not GALLERY_RE.match(url):
            messagebox.showerror("Gallery URL", "That doesn't look like a pornpics.com gallery URL\n"
                                 "(expected https://www.pornpics.com/galleries/<name>-<id>/).")
            return
        folder = self.folder.get().strip() or gallery_name_from_url(url) or "Gallery"
        dest = Path(self.dest.get().strip() or str(Path.home() / "Pictures" / "PornPics"))
        self.stop.clear()
        self.btn.configure(state="disabled")
        self.stop_btn.configure(state="normal")
        self.bar["value"] = 0
        self.status.set("Starting…")
        q = self.events
        stop = self.stop

        def run() -> None:
            try:
                result = download_gallery(url, dest, folder,
                                          log=lambda s: q.put(("log", s)),
                                          progress=lambda d, t, n: q.put(("progress", (d, t, n))),
                                          stop=stop)
                q.put(("done", result))
            except Exception as e:  # noqa: BLE001 — surfaced in the log
                q.put(("error", str(e)))

        self.worker = threading.Thread(target=run, daemon=True)
        self.worker.start()

    def _finish(self) -> None:
        self.btn.configure(state="normal")
        self.stop_btn.configure(state="disabled")


def main() -> None:
    args = sys.argv[1:]
    if args and args[0] in ("-h", "--help"):
        print(__doc__)
        print("Usage: pornpics_downloader.py [GALLERY_URL]            open the window (URL pre-filled)\n"
              "       pornpics_downloader.py --cli GALLERY_URL [DEST]  download without a window")
        return
    if args and args[0] == "--cli":
        if len(args) < 2:
            sys.exit("usage: pornpics_downloader.py --cli GALLERY_URL [DEST]")
        url = args[1]
        dest = Path(args[2]) if len(args) > 2 else Path.home() / "Pictures" / "PornPics"
        name = gallery_name_from_url(url)
        if not name:
            sys.exit("That doesn't look like a pornpics.com gallery URL.")
        saved, skipped, failed = download_gallery(url, dest, name, log=print,
                                                  progress=lambda d, t, n: print(f"\r{d}/{t} {n:40.40}", end="", flush=True),
                                                  stop=threading.Event())
        print(f"\nDone: {saved} saved, {skipped} already present, {failed} failed.")
        return
    if tk is None:
        sys.exit("tkinter isn't available in this Python. On macOS with Homebrew: brew install python-tk\n"
                 "(or use /usr/bin/python3, which includes it). You can also run with --cli.")
    app = App()
    if args:
        app.url.set(args[0])
    app.mainloop()


if __name__ == "__main__":
    main()
