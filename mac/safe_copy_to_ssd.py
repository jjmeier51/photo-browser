#!/usr/bin/env python3
"""Safe Copy to SSD — copy (or move) whole folders onto the exFAT SSD more carefully than Finder.

Why not Finder: the SSD is exFAT (no journal) and is read by iOS, whose exFAT driver is stricter than
macOS's. Folders filled by Finder ended up with thousands of "._" AppleDouble files (half of the
92,870 entries in one folder), names iOS can't handle, and — after an unplug mid-copy — damaged
directories. This tool:

  * copies one file at a time into a hidden temp file, flushes it all the way to the disk
    (F_FULLFSYNC), then renames it into place and flushes the folder — a file is either complete or
    absent, never half-written;
  * verifies every file by re-reading it from the drive (bypassing the Mac's cache) and comparing a
    checksum with the original — optional, on by default;
  * never copies macOS junk (._ AppleDouble files, .DS_Store) and never creates new ._ files;
  * fixes names exFAT/iOS can't store (\\ / : * ? " < > |, control characters, trailing dots or
    spaces, decomposed accents, over-long names) and reports each rename;
  * keeps modification dates, never overwrites (an identical file already there is skipped; a
    different one gets " (1)"), and warns before a folder would grow past what iOS can open;
  * "Move" puts each original folder in the Trash only after every file in it copied and verified;
  * can pause or stop between files, and ejects the SSD properly when you're done.

Run:  python3 mac/safe_copy_to_ssd.py
      python3 mac/safe_copy_to_ssd.py --cli SRC [SRC…] --to "/Volumes/Extreme SSD/Folder" [--move] [--no-verify]
"""

from __future__ import annotations

import argparse
import hashlib
import os
import queue
import subprocess
import sys
import threading
import time
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path

try:
    import fcntl
except ImportError:  # pragma: no cover - Windows
    fcntl = None  # type: ignore[assignment]

try:
    import tkinter as tk
    from tkinter import filedialog, messagebox, ttk
except ModuleNotFoundError:  # pragma: no cover - CLI still works
    tk = None  # type: ignore[assignment]

JUNK_NAMES = {".DS_Store", ".localized", "Icon\r", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems"}
EXFAT_ILLEGAL = set('\\/:*?"<>|')
IOS_FOLDER_LIMIT = 8000          # folders much larger than this have failed to open on iOS
CHUNK = 8 * 1024 * 1024
F_FULLFSYNC = getattr(fcntl, "F_FULLFSYNC", None) if fcntl else None
F_NOCACHE = getattr(fcntl, "F_NOCACHE", 48 if sys.platform == "darwin" else None) if fcntl else None


# ----------------------------------------------------------------------------- helpers


def is_junk(name: str) -> bool:
    return name in JUNK_NAMES or name.startswith("._")


def safe_name(name: str) -> str:
    """A name exFAT can store and iOS reads reliably (NFC, no forbidden characters, ≤ 255 UTF-16)."""
    n = unicodedata.normalize("NFC", name)
    n = "".join("-" if (c in EXFAT_ILLEGAL or ord(c) < 0x20 or ord(c) == 0x7F) else c for c in n)
    n = n.rstrip(" .") or "untitled"
    if len(n.encode("utf-16-le")) // 2 > 255:
        stem, dot, ext = n.rpartition(".")
        if not dot or len(ext) > 10:
            stem, ext = n, ""
        while len((stem + (("." + ext) if ext else "")).encode("utf-16-le")) // 2 > 250:
            stem = stem[:-1]
        n = stem.rstrip(" .") + (("." + ext) if ext else "")
    return n


def rename_note(old: str, new: str) -> str:
    if unicodedata.normalize("NFC", old) == new:
        return f"{new}  (accents re-encoded in the standard form iOS expects; looks the same)"
    return f"{old} → {new}"


def full_sync(fd: int) -> None:
    """Flush to stable storage (F_FULLFSYNC on macOS — plain fsync stops at the drive's cache)."""
    if F_FULLFSYNC is not None:
        try:
            fcntl.fcntl(fd, F_FULLFSYNC)
            return
        except OSError:
            pass
    os.fsync(fd)


def sync_dir(path: Path) -> None:
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        full_sync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def hash_file(path: Path, no_cache: bool = False) -> str:
    h = hashlib.blake2b(digest_size=20)
    fd = os.open(path, os.O_RDONLY)
    try:
        if no_cache and F_NOCACHE is not None:
            try:
                fcntl.fcntl(fd, F_NOCACHE, 1)    # re-read from the drive, not the Mac's memory
            except OSError:
                pass
        while chunk := os.read(fd, CHUNK):
            h.update(chunk)
    finally:
        os.close(fd)
    return h.hexdigest()


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


def volume_root(path: Path) -> Path:
    p = path.resolve()
    while not os.path.ismount(p) and p.parent != p:
        p = p.parent
    return p


# ----------------------------------------------------------------------------- plan


@dataclass
class FileJob:
    src: Path
    dst: Path          # final path (sanitized name)
    size: int
    renamed: bool


@dataclass
class FolderJob:
    src: Path
    dst: Path
    files: list[FileJob] = field(default_factory=list)
    dirs: list[Path] = field(default_factory=list)     # destination folders to create, parents first
    junk: int = 0


@dataclass
class Plan:
    folders: list[FolderJob]
    total_bytes: int
    total_files: int
    renames: list[tuple[str, str]]
    big_folders: list[tuple[str, int]]
    free_bytes: int


def make_plan(sources: list[Path], dest: Path) -> Plan:
    folders: list[FolderJob] = []
    renames: list[tuple[str, str]] = []
    big: list[tuple[str, int]] = []
    total = count = 0
    for src in sources:
        job = FolderJob(src=src, dst=dest / safe_name(src.name))
        if job.dst.name != src.name:
            renames.append((str(src), job.dst.name))
        for root, dirnames, filenames in os.walk(src):
            dirnames[:] = sorted(d for d in dirnames if not is_junk(d) and not d.startswith("."))
            rel = Path(root).relative_to(src)
            out_dir = job.dst.joinpath(*[safe_name(p) for p in rel.parts])
            job.dirs.append(out_dir)
            real = [f for f in sorted(filenames) if not is_junk(f) and not f.startswith(".")]
            job.junk += len(filenames) - len(real)
            existing = len(os.listdir(out_dir)) if out_dir.is_dir() else 0
            if existing + len(real) > IOS_FOLDER_LIMIT:
                big.append((str(out_dir), existing + len(real)))
            for f in real:
                p = Path(root) / f
                if p.is_symlink() or not p.is_file():
                    continue
                name = safe_name(f)
                if name != f:
                    renames.append((str(p), name))
                size = p.stat().st_size
                job.files.append(FileJob(p, out_dir / name, size, name != f))
                total += size
                count += 1
        folders.append(job)
    probe = dest if dest.exists() else dest.parent
    while not probe.exists() and probe.parent != probe:
        probe = probe.parent
    return Plan(folders, total, count, renames, big, os.statvfs(probe).f_bavail * os.statvfs(probe).f_frsize)


# ----------------------------------------------------------------------------- copy engine


class Copier:
    """Runs a plan on a worker thread; reports through callbacks (log, progress, done)."""

    def __init__(self, plan: Plan, verify: bool, move: bool, log, progress, done) -> None:
        self.plan, self.verify, self.move = plan, verify, move
        self.log, self.progress, self.done = log, progress, done
        self.stop = threading.Event()
        self.unpaused = threading.Event()
        self.unpaused.set()

    def start(self) -> threading.Thread:
        t = threading.Thread(target=self._run, daemon=True)
        t.start()
        return t

    def _run(self) -> None:
        stats = {"copied": 0, "skipped": 0, "failed": 0, "trashed": 0}
        done_bytes = 0
        t0 = time.time()
        for job in self.plan.folders:
            if self.stop.is_set():
                break
            self.log(f"\n▶ {job.src}  →  {job.dst}")
            failed_here = 0
            for d in job.dirs:
                if not d.exists():
                    d.mkdir(parents=True, exist_ok=True)
                    sync_dir(d)
                    sync_dir(d.parent)
            for fj in job.files:
                self.unpaused.wait()
                if self.stop.is_set():
                    break
                elapsed = max(time.time() - t0, 0.001)
                self.progress(done_bytes, self.plan.total_bytes, fj.src.name, done_bytes / elapsed)
                try:
                    result = self._copy_one(fj)
                    stats[result] += 1
                except InterruptedError:
                    self.log(f"   stopped during {fj.src.name} — its partial copy was removed")
                    break
                    if fj.renamed and result == "copied":
                        self.log(f"   renamed for exFAT/iOS: {rename_note(fj.src.name, fj.dst.name)}")
                except Exception as e:  # noqa: BLE001 — one bad file must not stop the rest
                    stats["failed"] += 1
                    failed_here += 1
                    self.log(f"   FAILED {fj.src.name}: {e}")
                done_bytes += fj.size
            sync_dir(job.dst)
            if self.move and not self.stop.is_set():
                if failed_here:
                    self.log(f"   kept the original folder — {failed_here} file(s) failed")
                elif self._trash(job.src):
                    stats["trashed"] += 1
                    self.log("   original folder moved to the Trash")
        self.progress(done_bytes, self.plan.total_bytes, "", 0)
        os.sync()
        self.done(stats, self.stop.is_set())

    def _copy_one(self, fj: FileJob) -> str:
        """'copied' | 'skipped' (identical file already there). Raises on failure."""
        dst = fj.dst
        if dst.exists():
            # Identical copy already there — under this name, or under a " (n)" name an earlier run
            # used because a different file held it — means nothing to do (re-runs never duplicate).
            src_hash = hash_file(fj.src) if self.verify else None
            stem, ext = dst.stem, dst.suffix
            i = 0
            candidate = dst
            while candidate.exists():
                if candidate.stat().st_size == fj.size and (src_hash is None or hash_file(candidate) == src_hash):
                    return "skipped"
                i += 1
                candidate = dst.with_name(f"{stem} ({i}){ext}")
            dst = candidate
            self.log(f"   a different “{fj.dst.name}” is already there — saving as “{dst.name}”")
        tmp = dst.with_name(f".{dst.name}.sctmp")
        h = hashlib.blake2b(digest_size=20)
        st = fj.src.stat()
        try:
            with open(fj.src, "rb") as fin, open(tmp, "wb") as fout:
                while chunk := fin.read(CHUNK):
                    h.update(chunk)
                    fout.write(chunk)
                    if self.stop.is_set():
                        raise InterruptedError("stopped")
                fout.flush()
                full_sync(fout.fileno())
            if tmp.stat().st_size != fj.size:
                raise IOError(f"size mismatch after copy ({tmp.stat().st_size} vs {fj.size})")
            if self.verify and hash_file(tmp, no_cache=True) != h.hexdigest():
                raise IOError("checksum mismatch — the drive returned different bytes")
            os.utime(tmp, ns=(st.st_atime_ns, st.st_mtime_ns))
            os.rename(tmp, dst)
            sync_dir(dst.parent)
            return "copied"
        except BaseException:
            try:
                tmp.unlink()
            except OSError:
                pass
            raise

    def _trash(self, folder: Path) -> bool:
        if sys.platform == "darwin":
            r = subprocess.run(["osascript", "-e", f'tell application "Finder" to delete (POSIX file "{folder}" as alias)'],
                               capture_output=True, text=True)
            if r.returncode == 0 and not folder.exists():
                return True
        trash = Path.home() / ".Trash"
        try:
            if trash.is_dir():
                target = trash / folder.name
                n = 1
                while target.exists():
                    target = trash / f"{folder.name} {n}"
                    n += 1
                folder.rename(target)
                return True
        except OSError as e:
            self.log(f"   couldn't move the original to the Trash: {e}")
        return False


def describe_plan(plan: Plan) -> list[str]:
    lines = [f"{plan.total_files} files, {human(plan.total_bytes)} in {len(plan.folders)} folder(s); "
             f"{human(plan.free_bytes)} free on the destination."]
    junk = sum(f.junk for f in plan.folders)
    if junk:
        lines.append(f"{junk} macOS junk files (._*, .DS_Store) will be left behind.")
    if plan.renames:
        lines.append(f"{len(plan.renames)} name(s) will be changed so exFAT/iOS can store them, e.g.:")
        lines += [f"   {rename_note(Path(a).name, b)}" for a, b in plan.renames[:8]]
    for path, n in plan.big_folders:
        lines.append(f"WARNING: “{path}” would hold {n:,} items — iOS can fail to open folders that "
                     f"large (over ~{IOS_FOLDER_LIMIT:,}). Consider splitting it.")
    if plan.total_bytes > plan.free_bytes:
        lines.append("NOT ENOUGH SPACE on the destination.")
    return lines


# ----------------------------------------------------------------------------- GUI


class App(tk.Tk if tk else object):  # type: ignore[misc]
    def __init__(self) -> None:
        super().__init__()
        self.title("Safe Copy to SSD")
        self.minsize(720, 560)
        self.events: queue.Queue = queue.Queue()
        self.sources: list[Path] = []
        self.copier: Copier | None = None
        vols = sorted(p for p in Path("/Volumes").glob("*") if p.is_dir() and p.name != "Macintosh HD") \
            if Path("/Volumes").is_dir() else []
        self.dest = tk.StringVar(value=str(vols[0]) if vols else "")
        self.verify = tk.BooleanVar(value=True)
        self.mode = tk.StringVar(value="copy")
        self.status = tk.StringVar(value="Add the folders to copy, pick where on the SSD they go, then Start.")
        self._build()
        self.after(100, self._pump)

    def _build(self) -> None:
        pad = {"padx": 10, "pady": 4}
        frm = ttk.Frame(self)
        frm.pack(fill="both", expand=True)
        frm.columnconfigure(0, weight=1)

        ttk.Label(frm, text="Folders to copy (each lands on the SSD under its own name):").grid(row=0, column=0, sticky="w", **pad)
        box = ttk.Frame(frm)
        box.grid(row=1, column=0, sticky="nsew", **pad)
        box.columnconfigure(0, weight=1)
        self.listbox = tk.Listbox(box, height=6, selectmode="extended")
        self.listbox.grid(row=0, column=0, sticky="nsew")
        side = ttk.Frame(box)
        side.grid(row=0, column=1, sticky="n", padx=(8, 0))
        ttk.Button(side, text="Add Folder…", command=self._add).pack(fill="x")
        ttk.Button(side, text="Remove", command=self._remove).pack(fill="x", pady=(6, 0))

        row = ttk.Frame(frm)
        row.grid(row=2, column=0, sticky="ew", **pad)
        row.columnconfigure(1, weight=1)
        ttk.Label(row, text="Copy into:").grid(row=0, column=0, sticky="w")
        ttk.Entry(row, textvariable=self.dest).grid(row=0, column=1, sticky="ew", padx=6)
        ttk.Button(row, text="Choose…", command=self._choose_dest).grid(row=0, column=2)

        opts = ttk.Frame(frm)
        opts.grid(row=3, column=0, sticky="w", **pad)
        ttk.Radiobutton(opts, text="Copy (keep the originals)", value="copy", variable=self.mode).pack(side="left")
        ttk.Radiobutton(opts, text="Move (originals to the Trash once verified)", value="move",
                        variable=self.mode).pack(side="left", padx=(12, 0))
        ttk.Checkbutton(opts, text="Verify every file", variable=self.verify).pack(side="left", padx=(12, 0))

        btns = ttk.Frame(frm)
        btns.grid(row=4, column=0, sticky="w", **pad)
        self.start_btn = ttk.Button(btns, text="Start", command=self._start)
        self.start_btn.pack(side="left")
        self.pause_btn = ttk.Button(btns, text="Pause", command=self._pause, state="disabled")
        self.pause_btn.pack(side="left", padx=(8, 0))
        self.stop_btn = ttk.Button(btns, text="Stop", command=self._stop, state="disabled")
        self.stop_btn.pack(side="left", padx=(8, 0))
        self.eject_btn = ttk.Button(btns, text="Eject SSD", command=self._eject)
        self.eject_btn.pack(side="left", padx=(24, 0))

        self.bar = ttk.Progressbar(frm, mode="determinate", maximum=1000)
        self.bar.grid(row=5, column=0, sticky="ew", **pad)
        ttk.Label(frm, textvariable=self.status).grid(row=6, column=0, sticky="w", **pad)
        self.logbox = tk.Text(frm, height=14, wrap="word", state="disabled")
        self.logbox.grid(row=7, column=0, sticky="nsew", padx=10, pady=(4, 10))
        frm.rowconfigure(7, weight=1)
        frm.rowconfigure(1, weight=0)

    # -- list / destination
    def _add(self) -> None:
        d = filedialog.askdirectory(title="Folder to copy to the SSD", mustexist=True)
        if d and Path(d) not in self.sources:
            self.sources.append(Path(d))
            self.listbox.insert("end", d)

    def _remove(self) -> None:
        for i in reversed(self.listbox.curselection()):
            self.listbox.delete(i)
            del self.sources[i]

    def _choose_dest(self) -> None:
        d = filedialog.askdirectory(title="Where on the SSD", initialdir=self.dest.get() or "/Volumes")
        if d:
            self.dest.set(d)

    # -- run
    def _start(self) -> None:
        dest = Path(self.dest.get().strip())
        if not self.sources:
            messagebox.showinfo("Safe Copy", "Add at least one folder to copy.")
            return
        if not dest.is_dir():
            messagebox.showerror("Safe Copy", "Choose an existing destination folder on the SSD.")
            return
        for s in self.sources:
            if dest.resolve() == s.resolve() or str(dest.resolve()).startswith(str(s.resolve()) + os.sep):
                messagebox.showerror("Safe Copy", f"The destination is inside “{s.name}”.")
                return
        self._log("Checking…")
        self.update_idletasks()
        plan = make_plan(self.sources, dest)
        summary = describe_plan(plan)
        for line in summary:
            self._log(line)
        if plan.total_bytes > plan.free_bytes:
            messagebox.showerror("Safe Copy", "There isn't enough free space on the destination.")
            return
        move = self.mode.get() == "move"
        question = "\n".join(summary[:4] + ([s for s in summary if s.startswith("WARNING")][:2]))
        question += "\n\n" + ("Move these folders? Originals go to the Trash only after they verify."
                              if move else "Start copying?")
        if not messagebox.askokcancel("Safe Copy", question):
            return
        q = self.events
        self.copier = Copier(plan, self.verify.get(), move,
                             log=lambda s: q.put(("log", s)),
                             progress=lambda d, t, n, r: q.put(("progress", (d, t, n, r))),
                             done=lambda st, stopped: q.put(("done", (st, stopped))))
        self.copier.start()
        self.start_btn.configure(state="disabled")
        self.pause_btn.configure(state="normal", text="Pause")
        self.stop_btn.configure(state="normal")
        self.eject_btn.configure(state="disabled")

    def _pause(self) -> None:
        if not self.copier:
            return
        if self.copier.unpaused.is_set():
            self.copier.unpaused.clear()
            self.pause_btn.configure(text="Resume")
            self.status.set("Paused — the current file finishes first. Safe to leave it here.")
        else:
            self.copier.unpaused.set()
            self.pause_btn.configure(text="Pause")

    def _stop(self) -> None:
        if self.copier:
            self.copier.stop.set()
            self.copier.unpaused.set()
            self.status.set("Stopping — the current file is discarded, everything finished stays.")

    def _eject(self) -> None:
        dest = Path(self.dest.get().strip())
        if not dest.exists():
            return
        vol = volume_root(dest)
        if vol == Path("/"):
            messagebox.showinfo("Eject", "The destination isn't on an external drive.")
            return
        os.sync()
        r = subprocess.run(["diskutil", "eject", str(vol)], capture_output=True, text=True)
        msg = (r.stdout or r.stderr).strip()
        self._log(msg)
        if r.returncode == 0:
            messagebox.showinfo("Eject", f"“{vol.name}” was ejected. It's safe to unplug it.")
        else:
            messagebox.showerror("Eject", f"Couldn't eject — something is still using it:\n{msg}")

    # -- events from the worker
    def _pump(self) -> None:
        try:
            while True:
                kind, payload = self.events.get_nowait()
                if kind == "log":
                    self._log(payload)
                elif kind == "progress":
                    d, t, n, rate = payload
                    self.bar["value"] = int(1000 * d / t) if t else 1000
                    eta = f" · about {int((t - d) / rate / 60) + 1} min left" if rate > 0 and t > d else ""
                    self.status.set(f"{human(d)} of {human(t)}{eta} · {n}" if n else "Finishing…")
                elif kind == "done":
                    st, stopped = payload
                    head = "Stopped." if stopped else "Done."
                    self._log(f"\n{head} {st['copied']} copied, {st['skipped']} already there, {st['failed']} failed"
                              + (f", {st['trashed']} original folder(s) moved to the Trash" if st["trashed"] else ""))
                    self.status.set(f"{head} Eject the SSD with the button before unplugging it.")
                    self.start_btn.configure(state="normal")
                    self.pause_btn.configure(state="disabled", text="Pause")
                    self.stop_btn.configure(state="disabled")
                    self.eject_btn.configure(state="normal")
                    self.copier = None
        except queue.Empty:
            pass
        self.after(150, self._pump)

    def _log(self, line: str) -> None:
        self.logbox.configure(state="normal")
        self.logbox.insert("end", line + "\n")
        self.logbox.see("end")
        self.logbox.configure(state="disabled")


# ----------------------------------------------------------------------------- CLI


def run_cli(args: argparse.Namespace) -> None:
    dest = Path(args.to)
    if not dest.is_dir():
        sys.exit(f"Destination isn't a folder: {dest}")
    plan = make_plan([Path(s) for s in args.cli], dest)
    for line in describe_plan(plan):
        print(line)
    if plan.total_bytes > plan.free_bytes:
        sys.exit("Not enough space.")
    finished = threading.Event()
    result: dict = {}

    def done(st, stopped):
        result.update(st)
        finished.set()

    Copier(plan, not args.no_verify, args.move, log=print,
           progress=lambda d, t, n, r: None, done=done).start()
    finished.wait()
    print(f"\nDone: {result['copied']} copied, {result['skipped']} already there, {result['failed']} failed"
          + (f", {result['trashed']} original folder(s) moved to the Trash" if result["trashed"] else ""))


def main() -> None:
    ap = argparse.ArgumentParser(description="Copy/move folders to the exFAT SSD safely.")
    ap.add_argument("--cli", nargs="+", metavar="SRC", help="copy these folders without the window")
    ap.add_argument("--to", help="destination folder (with --cli)")
    ap.add_argument("--move", action="store_true", help="(with --cli) originals to the Trash once verified")
    ap.add_argument("--no-verify", action="store_true", help="(with --cli) skip the re-read checksum")
    args = ap.parse_args()
    if args.cli:
        if not args.to:
            sys.exit("--cli needs --to DEST")
        run_cli(args)
        return
    if tk is None:
        sys.exit("tkinter isn't available in this Python (use /usr/bin/python3, or --cli).")
    App().mainloop()


if __name__ == "__main__":
    main()
