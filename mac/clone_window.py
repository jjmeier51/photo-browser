"""Photo Browser for Mac ▸ File ▸ "Clone Drive to a New SSD…" — the window (clone_drive.py does the work).

Pick the old drive and the new one, press Clone: the old drive is read (never changed), everything on it is
copied to the same place on the new one — each file read back from the new drive and checked before it gets
its real name — then the two drives are compared and the report shown (and saved in
~/Library/Logs/Photo Browser for Mac/). "Verify" compares two drives without copying. Stopping, a pulled cable or a
restart lose nothing: Clone again carries on where it was.

Everything that touches a drive runs on a worker thread — the scan (and the stat-per-file sum of what's still to
write, which it hands over with the plan), the copy, the comparisons, the check, and the two `diskutil` renames
of "Give the New Drive the Old Drive's Name…". Each worker reports back whatever happens: an error nobody foresaw
comes back as `failed` with its text, so the window is never left "running" with nothing running.
"""
from __future__ import annotations

import os
import threading
import time
import traceback
from pathlib import Path
from typing import Callable

from PySide6.QtCore import QObject, Qt, QUrl, Signal
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import (QCheckBox, QComboBox, QDialog, QFileDialog, QFormLayout, QHBoxLayout, QLabel,
                               QMessageBox, QPlainTextEdit, QProgressBar, QPushButton, QVBoxLayout, QWidget)

import clone_drive as cd


class _Bridge(QObject):
    progress = Signal(int, int, object, object, str, str)     # bytes can pass 2 GB: objects, not ints
    log = Signal(str)
    phase = Signal(str)
    asked = Signal(object, object, object)                    # (plan, blocks, bytes still to write) after the scan
    finished = Signal(object)                                 # the report text, or None when stopped before the copy
    failed = Signal(str)                                      # a worker gave up: what went wrong
    renamed = Signal(bool, str)                               # the drives' names swapped (or not): what to tell


class CloneWindow(QDialog):
    def __init__(self, parent, volumes: Callable[[], list], start: str = "", done: Callable[[str], None] | None = None) -> None:
        super().__init__(parent)
        self.volumes, self.done_cb = volumes, done
        self.running = False
        self.renaming = False
        self.job: cd.Clone | None = None
        self.stop_flag = False
        self.report_path = ""
        self.different: list[str] = []
        self.bridge = _Bridge()
        self.bridge.progress.connect(self._progress)
        self.bridge.log.connect(self._log)
        self.bridge.phase.connect(self._phase)
        self.bridge.asked.connect(self._scanned)
        self.bridge.finished.connect(self._finished)
        self.bridge.failed.connect(self._failed)
        self.bridge.renamed.connect(self._names_swapped)
        self.setWindowTitle("Clone Drive to a New SSD")
        self.resize(780, 620)
        self.old = QComboBox()
        self.new = QComboBox()
        for box in (self.old, self.new):
            box.setMinimumWidth(380)
        self._fill(start)
        pick_old = QPushButton("Choose…")
        pick_old.clicked.connect(lambda: self._choose(self.old))
        pick_new = QPushButton("Choose…")
        pick_new.clicked.connect(lambda: self._choose(self.new))

        def row(box: QComboBox, button: QPushButton) -> QWidget:
            w = QWidget()
            lay = QHBoxLayout(w)
            lay.setContentsMargins(0, 0, 0, 0)
            lay.addWidget(box, 1)
            lay.addWidget(button)
            return w
        form = QFormLayout()
        form.addRow("Old drive (only read):", row(self.old, pick_old))
        form.addRow("New drive:", row(self.new, pick_new))
        self.deep = QCheckBox("Afterwards, read every byte of both drives again (the surest check — takes about as "
                              "long as the copy)")
        self.intro = QLabel(
            "Copies everything — every file and folder, their dates, tags and attributes, and the hidden records the "
            "iPhone app and the downloaders keep on the drive — to the same place on the new drive. Each file is read "
            "back from the new drive and checked before it counts. Nothing on the old drive is changed.\n\n"
            "First, on the iPhone: open the old drive in Photo Browser ▸ Drive Health ▸ Back Up Metadata Now, so the "
            "drive carries everything the phone knows.")
        self.intro.setWordWrap(True)
        self.status = QLabel("")
        self.status.setWordWrap(True)
        self.bar = QProgressBar()
        self.bar.setRange(0, 1000)
        self.bar.setVisible(False)
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumBlockCount(20000)
        self.go = QPushButton("Clone")
        self.go.setDefault(True)
        self.go.clicked.connect(lambda: self._begin("clone"))
        self.verify = QPushButton("Verify")
        self.verify.setToolTip("Compare the two drives without copying anything")
        self.verify.clicked.connect(lambda: self._begin("verify"))
        self.pause = QPushButton("Pause")
        self.pause.setCheckable(True)
        self.pause.setEnabled(False)
        self.pause.toggled.connect(self._pause)
        self.stop = QPushButton("Stop")
        self.stop.setEnabled(False)
        self.stop.clicked.connect(self._stop)
        self.show_report = QPushButton("Show Report")
        self.show_report.setVisible(False)
        self.show_report.clicked.connect(lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(self.report_path)))
        self.again = QPushButton("")
        self.again.setVisible(False)
        self.again.clicked.connect(lambda: self._begin("recopy"))
        self.check = QPushButton("Check Files")
        self.check.setToolTip("Reads every file on the new drive again and compares it with the checksum recorded "
                              "when it was written — the way to find a file that has gone bad on the drive.\n"
                              "The old drive isn't needed. Nothing is changed.")
        self.check.clicked.connect(lambda: self._begin_check(False))
        self.record = QPushButton("")
        self.record.setToolTip("Reads the files that have no checksum yet (added or changed since) and records "
                               "them, so the next check covers them")
        self.record.setVisible(False)
        self.record.clicked.connect(lambda: self._begin_check(True))
        self.match = QPushButton("")
        self.match.setToolTip("Give the items listed as copied with different dates or attributes the old drive's.\n"
                              "No file's contents are touched; a file changed on the new drive is left as it is.")
        self.match.setVisible(False)
        self.match.clicked.connect(lambda: self._begin("details"))
        self.rename = QPushButton("Give the New Drive the Old Drive's Name…")
        self.rename.setToolTip("So every path that names the drive still points at the library")
        self.rename.setVisible(False)
        self.rename.clicked.connect(self._swap_names)
        buttons = QHBoxLayout()
        buttons.addWidget(self.show_report)
        buttons.addWidget(self.again)
        buttons.addWidget(self.record)
        buttons.addWidget(self.match)
        buttons.addWidget(self.rename)
        buttons.addStretch(1)
        buttons.addWidget(self.pause)
        buttons.addWidget(self.stop)
        buttons.addWidget(self.check)
        buttons.addWidget(self.verify)
        buttons.addWidget(self.go)
        lay = QVBoxLayout(self)
        lay.addWidget(self.intro)
        lay.addLayout(form)
        lay.addWidget(self.deep)
        lay.addWidget(self.status)
        lay.addWidget(self.bar)
        lay.addWidget(self.log, 1)
        lay.addLayout(buttons)

    # -- the two drives
    def _fill(self, start: str) -> None:
        vols = [str(v) for v in self.volumes()]
        for box in (self.old, self.new):
            box.clear()
            for v in vols:
                box.addItem(os.path.basename(v.rstrip("/")) or v, v)
        if start:
            i = self.old.findData(start)
            if i < 0:
                self.old.addItem(os.path.basename(start.rstrip("/")) or start, start)
                i = self.old.count() - 1
            self.old.setCurrentIndex(i)
        other = next((i for i in range(self.new.count()) if self.new.itemData(i) != self.old.currentData()), -1)
        if other >= 0:
            self.new.setCurrentIndex(other)
        else:
            self.new.setCurrentIndex(-1)

    def _choose(self, box: QComboBox) -> None:
        path = QFileDialog.getExistingDirectory(self, "Choose the drive (its top folder)", "/Volumes")
        if not path:
            return
        i = box.findData(path)
        if i < 0:
            box.addItem(os.path.basename(path.rstrip("/")) or path, path)
            i = box.count() - 1
        box.setCurrentIndex(i)

    # -- running
    def _begin(self, what: str) -> None:
        if self.running or self.renaming:
            return
        src, dst = self.old.currentData(), self.new.currentData()
        if not src or not dst:
            QMessageBox.information(self, "Clone Drive", "Choose the old drive and the new drive first.")
            return
        blocks = cd.preflight(src, dst)
        if blocks:
            QMessageBox.warning(self, "Clone Drive", "\n\n".join(blocks))
            return
        self.what, self.src, self.dst = what, src, dst
        self.running, self.stop_flag = True, False
        self.job = None
        for w in (self.go, self.verify, self.check, self.record, self.old, self.new, self.deep, self.again, self.match):
            w.setEnabled(False)
        self.record.setVisible(False)
        self.stop.setEnabled(True)
        self.show_report.setVisible(False)
        self.again.setVisible(False)
        self.match.setVisible(False)
        self.rename.setVisible(False)
        self.bar.setVisible(True)
        self.bar.setRange(0, 0)
        self.started = time.monotonic()
        self._phase(f"Reading “{os.path.basename(src.rstrip('/')) or src}”…")
        threading.Thread(target=self._scan, daemon=True, name="clone-scan").start()

    def _guarded(self, work: Callable[[], None], doing: str) -> None:
        """Runs a worker's body so that it always reports back: an exception becomes `failed` (with its last
        line for the status and the whole of it for the log) instead of a thread that dies without a word."""
        try:
            work()
        except Exception as e:  # noqa: BLE001 — whatever it is, the window has to hear of it
            self.bridge.log.emit(traceback.format_exc().rstrip())
            self.bridge.failed.emit(f"{doing} stopped on an error: {type(e).__name__}: {e}")

    def _scan(self) -> None:
        self._guarded(self._scan_work, "Reading the old drive")

    def _scan_work(self) -> None:
        plan = cd.scan(self.src, progress=lambda n: self.bridge.phase.emit(f"Reading the old drive — {n:,} items…"),
                       stop=lambda: self.stop_flag)
        need, blocks = 0, []
        if self.what == "clone" and not self.stop_flag:
            # A stat for every file: worked out here once, and handed to the question the window then asks.
            self.bridge.phase.emit("Looking at what's already on the new drive…")
            need = cd.bytes_missing(self.src, self.dst, plan)
            blocks = cd.preflight(self.src, self.dst, plan, need=need)
        self.bridge.asked.emit(plan, blocks, need)

    def _scanned(self, plan: cd.Scan, blocks: list[str], need: int = 0) -> None:
        if self.stop_flag:
            self._finished(None)
            return
        self.plan = plan
        self._log(f"On the old drive: {plan.files:,} files in {plan.folders:,} folders, {cd.human(plan.bytes)}"
                  + (f"; {plan.left_out:,} items of system bookkeeping left out" if plan.left_out else "") + ".")
        for rel, why in plan.unreadable[:20]:
            self._log(f"   ! couldn't read {rel}: {why}")
        if blocks:
            QMessageBox.warning(self, "Clone Drive", "\n\n".join(blocks))
            self._finished(None)
            return
        if self.what == "clone":
            name_old = os.path.basename(self.src.rstrip("/")) or self.src
            name_new = os.path.basename(self.dst.rstrip("/")) or self.dst
            text = (f"Copy {plan.files:,} files ({cd.human(need)} still to write) from “{name_old}” to “{name_new}”?\n\n"
                    f"“{name_old}” is only read. Nothing of yours on “{name_new}” is overwritten.")
            if plan.unreadable:
                text += f"\n\n{len(plan.unreadable):,} item(s) on the old drive couldn't be read — they're listed in the log."
            if QMessageBox.question(self, "Clone Drive", text) != QMessageBox.StandardButton.Yes:
                self._finished(None)
                return
        if self.what == "details":
            name_new = os.path.basename(self.dst.rstrip("/")) or self.dst
            if QMessageBox.question(
                    self, "Clone Drive",
                    f"Give {len(self.details):,} item(s) on “{name_new}” the old drive's dates and attributes?\n\n"
                    "Only dates and attributes are set — no file's contents are touched, and the old drive is only "
                    "read. A file that was changed on the new drive since the clone is left as it is.") \
                    != QMessageBox.StandardButton.Yes:
                self._finished(None)
                return
        self.bar.setRange(0, 1000)
        self.pause.setEnabled(self.what in ("clone", "recopy"))
        threading.Thread(target=self._work, daemon=True, name="clone").start()

    def _begin_check(self, update: bool) -> None:
        """Check Files: the new drive read again against its recorded checksums (clone_drive.check_drive)."""
        if self.running or self.renaming:
            return
        dst = self.new.currentData()
        if not dst or not os.path.isdir(dst):
            QMessageBox.information(self, "Clone Drive", "Choose the drive to check as the new drive.")
            return
        self.what, self.dst = "check", dst
        self.running, self.stop_flag = True, False
        self.job = None
        for w in (self.go, self.verify, self.check, self.record, self.old, self.new, self.deep, self.again, self.match):
            w.setEnabled(False)
        for w in (self.show_report, self.again, self.match, self.record, self.rename):
            w.setVisible(False)
        self.stop.setEnabled(True)
        self.bar.setVisible(True)
        self.bar.setRange(0, 1000)
        self.started = time.monotonic()
        self._phase("Recording the files that have no checksum yet…" if update else "Reading every file again…")
        threading.Thread(target=self._check_work, args=(dst, update), daemon=True, name="clone-check").start()

    def _check_work(self, dst: str, update: bool) -> None:
        def work() -> None:
            awake = cd.keep_awake()
            try:
                c = cd.check_drive(dst, update=update, stop=lambda: self.stop_flag,
                                   progress=lambda i, total, name: self.bridge.progress.emit(
                                       i, total, 0, 0, os.path.basename(name), "checking files"))
            finally:
                if awake is not None:
                    awake.terminate()
            self.result, self.cmp, self.checked = None, None, (c, update)
            self.bridge.finished.emit(cd.check_report(dst, c, update))
        self._guarded(work, "Checking the files")

    def _work(self) -> None:
        def work() -> None:
            awake = cd.keep_awake()                      # a clone runs for hours: the Mac mustn't doze off
            try:
                self._work_awake()
            finally:
                if awake is not None:
                    awake.terminate()
        self._guarded(work, {"verify": "Comparing the drives", "details": "Matching dates and attributes",
                             "recopy": "Copying again"}.get(self.what, "The clone"))

    def _work_awake(self) -> None:
        plan, src, dst = self.plan, self.src, self.dst
        result = None
        if self.what in ("clone", "recopy"):
            if self.what == "clone":
                cleared = cd.clear_leftovers(dst)
                if cleared:
                    self.bridge.log.emit(f"Cleared {cleared:,} temporary file(s) an earlier run left.")
            self.job = cd.Clone(src, dst, plan, progress=lambda *a: self.bridge.progress.emit(*a),
                                log=lambda s: self.bridge.log.emit(s))
            if self.stop_flag:
                self.job.cancel()
            if self.what == "clone":
                self.bridge.phase.emit("Copying…")
                result = self.job.run()
            else:
                self.bridge.phase.emit(f"Copying {len(self.different):,} file(s) again…")
                result = self.job.recopy(list(self.different))
        if self.what == "details":
            rels = list(self.details)
            self.bridge.phase.emit(f"Matching the dates and attributes of {len(rels):,} item(s)…")
            done, left = cd.match_details(
                src, dst, rels, stop=lambda: self.stop_flag,
                progress=lambda i, total, name: self.bridge.progress.emit(i, total, 0, 0, os.path.basename(name), "matching"))
            for rel, why in left[:200]:
                self.bridge.log.emit(f"Left as it is: {rel} — {why}")
            self.bridge.log.emit(f"{done:,} item(s) given the old drive's dates and attributes; {len(left):,} left as they are.")
        deep = (self.deep.isChecked() and self.what != "details") or self.what == "recopy"
        cmp = None
        if not (result is not None and result.stopped):
            self.bridge.phase.emit("Comparing the two drives" + (" — every byte…" if deep else "…"))
            last = [0.0]

            def tick(done: int, total: int, name: str) -> None:
                if time.monotonic() - last[0] > 0.2 or done == total:
                    last[0] = time.monotonic()
                    self.bridge.progress.emit(done, total, 0, 0, os.path.basename(name), "comparing")
            sums = cd.load_sums(dst) if deep else None   # a byte-for-byte comparison records what it read —
            cmp = cd.compare(src, dst, plan, deep=deep, progress=tick, stop=lambda: self.stop_flag, collect=sums)
            if sums is not None and sums.appended:       # onto the drive as it goes; here only tidied
                cd.compact_sums(dst)
        text = cd.report(src, dst, plan, result, cmp)
        self.result, self.cmp = result, cmp
        self.bridge.finished.emit(text)

    def _progress(self, df: int, tf: int, db, tb, name: str, phase: str) -> None:
        if phase in ("comparing", "matching", "checking files"):
            self.bar.setValue(int(1000 * df / max(tf, 1)))
            word = {"comparing": "Comparing", "matching": "Matching dates and attributes"}.get(phase, "Checking files")
            self.status.setText(f"{word} — {df:,} of {tf:,} items" + (f"  ·  {name}" if name else ""))
            return
        frac = (db / tb) if tb else (df / max(tf, 1))
        self.bar.setValue(int(1000 * frac))
        line = f"{'Checking' if phase == 'checking' else 'Copying'} — {df:,} of {tf:,} files, {cd.human(db)} of {cd.human(tb)}"
        secs = time.monotonic() - self.started
        if frac > 0.01 and secs > 20 and frac < 1:
            left = secs / frac * (1 - frac)
            line += f"  ·  about {left / 3600:.1f} h left" if left >= 5400 else f"  ·  about {max(left / 60, 1):.0f} min left"
        if name:
            line += f"  ·  {name}"
        self.status.setText(line)

    def _phase(self, line: str) -> None:
        self.status.setText(line)

    def _log(self, line: str) -> None:
        self.log.appendPlainText(line)

    def _pause(self, on: bool) -> None:
        if self.job is not None:
            self.job.pause(on)
        self.pause.setText("Resume" if on else "Pause")

    def _stop(self) -> None:
        self.stop_flag = True
        if self.job is not None:
            self.job.cancel()
        self.stop.setEnabled(False)
        self.status.setText("Stopping after the file in hand — nothing half-copied is left behind…")

    def _failed(self, message: str) -> None:
        """A worker gave up on something unforeseen (its traceback is in the log). The window is usable again;
        what was copied before it is whole and checked, and Clone again carries on from there."""
        self._finished(None)
        self.log.appendPlainText(message)
        self.status.setText(message + " — nothing half-copied is left behind; the details are in the log above.")

    def _finished(self, text) -> None:
        self.running = False
        self.bar.setVisible(False)
        for w in (self.go, self.verify, self.check, self.record, self.old, self.new, self.deep, self.again, self.match):
            w.setEnabled(True)
        self.pause.setChecked(False)
        self.pause.setEnabled(False)
        self.stop.setEnabled(False)
        if text is None:
            self.status.setText("Stopped." if self.stop_flag else "")
            return
        self.log.appendPlainText("\n" + text)
        self.report_path = cd.save_report(text)
        self.show_report.setVisible(bool(self.report_path))
        if self.what == "check":
            c, update = self.checked
            if c.stopped:
                line = "Stopped before the end."
            elif c.damaged or c.unreadable:
                line = (f"{len(c.damaged) + len(c.unreadable):,} file(s) aren't what was recorded — damaged, or edited "
                        "without their date changing — or can't be read. They're listed above.")
            elif update:
                line = f"Recorded {c.recorded:,} file(s). Check Files reads them all against their checksums."
            elif not c.intact and (c.unrecorded or c.changed):
                line = "No checksums recorded for this drive yet — Record New Files reads every file once and keeps them."
            else:
                line = f"{c.intact:,} file(s) read back exactly as written."
            pending = 0 if update or c.stopped else c.unrecorded + c.changed
            if pending:
                self.record.setText(f"Record {pending:,} New File{'s' if pending != 1 else ''}")
                self.record.setVisible(True)
                if c.intact:
                    line += f" {pending:,} more have no checksum yet."
            self.status.setText(line)
            return
        result, cmp = getattr(self, "result", None), getattr(self, "cmp", None)
        self.different = [rel for rel, what in cmp.different if what == "the contents differ"] if cmp is not None else []
        if self.different:
            self.again.setText(f"Copy {len(self.different):,} Different File{'s' if len(self.different) != 1 else ''} Again")
            self.again.setVisible(True)
        self.details = [rel for rel, _what in cmp.metadata] if cmp is not None and not cmp.stopped else []
        if self.details:
            self.match.setText(f"Match Dates and Attributes ({len(self.details):,})")
            self.match.setVisible(True)
        problems = (len(result.problems) if result is not None else 0) + (cmp.problems if cmp is not None else 0)
        if (result is not None and result.stopped) or (cmp is not None and cmp.stopped):
            line = "Stopped before the end — press Clone again to carry on where it was."
        elif problems:
            line = f"Finished with {problems:,} thing(s) to look at — they're listed above and in the report."
        else:
            line = "Done — everything on the old drive is on the new one, checked. " + \
                   ("Every byte of both drives was read again." if cmp is not None and cmp.deep else
                    "Each file was read back from the new drive as it was copied.")
        self.status.setText(line)
        clean = not problems and not (result is not None and result.stopped) and cmp is not None and not cmp.stopped
        self.rename.setVisible(clean and cd.IS_MAC and os.path.ismount(self.src) and os.path.ismount(self.dst)
                               and os.path.basename(self.src.rstrip("/")) != os.path.basename(self.dst.rstrip("/")))
        if self.done_cb is not None:
            self.done_cb(self.dst)

    def _swap_names(self) -> None:
        name = os.path.basename(self.src.rstrip("/"))
        aside = cd.old_drive_name(name, cd.fs_type(self.src))
        if QMessageBox.question(
                self, "Clone Drive",
                f"Rename the old drive to “{aside}” and the new drive to “{name}”?\n\nNothing on either drive "
                "changes but its name. With the old name, everything that points at the library by the drive's "
                "name — on this Mac and on the iPhone — finds it on the new drive.") != QMessageBox.StandardButton.Yes:
            return
        # Two `diskutil rename`s, each of which may take a while (a drive that's asleep, or busy): off this thread,
        # with the window saying so and nothing else startable until they're done.
        self.renaming = True
        busy = (self.go, self.verify, self.check, self.record, self.old, self.new, self.deep, self.again, self.match,
                self.rename)
        for w in busy:
            w.setEnabled(False)
        self.bar.setRange(0, 0)
        self.bar.setVisible(True)
        self.status.setText(f"Renaming the drives — “{name}” becomes “{aside}”, the new drive “{name}”…")
        src, dst = self.src, self.dst

        def work() -> None:
            try:
                ok, message = cd.swap_names(src, dst)
            except Exception as e:  # noqa: BLE001 — always answer, or the window stays busy for good
                ok, message = False, f"Couldn't rename the drives: {type(e).__name__}: {e}"
            self.bridge.renamed.emit(ok, message)
        threading.Thread(target=work, daemon=True, name="clone-rename").start()

    def _names_swapped(self, ok: bool, message: str) -> None:
        self.renaming = False
        self.bar.setVisible(False)
        self.bar.setRange(0, 1000)
        for w in (self.go, self.verify, self.check, self.record, self.old, self.new, self.deep, self.again, self.match,
                  self.rename):
            w.setEnabled(True)
        self.log.appendPlainText(message)
        self.status.setText(message)
        if ok:
            self.rename.setVisible(False)
            self._fill("")
        else:
            QMessageBox.warning(self, "Clone Drive", message)

    def reject(self) -> None:
        if self.renaming:
            self.status.setText("Renaming the drives — a moment…")      # two short commands that can't be cut off
            return
        if self.running:
            if QMessageBox.question(self, "Clone Drive", "A clone is running. Stop it and close? (Clone again later "
                                    "carries on where it was.)") != QMessageBox.StandardButton.Yes:
                return
            self._stop()
        super().reject()
