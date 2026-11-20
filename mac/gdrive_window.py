"""The Google Drive window of Photo Browser for Mac — pick files and folders in Drive, download them into a folder
on the drive with their dates (gdrive.py does the work; this is the window).

Right-click a folder ▸ Download ▸ **Download from Google Drive…** (or the File menu). The window shows:

- who's signed in, **Sign In with Google** (the consent page opens in the Mac's own browser — gdrive.py says why
  not in a browser of the app's) and **Set Up…** (the Client ID / secret / API key, with the steps to get them);
- a place — My Drive, Shared with me, Starred, Shared drives — or a search, as a tree: tick files, or a folder for
  everything inside it (folders open when clicked, read only then);
- a box for **links** (one or several, files or folders): they're added to the list ticked. With nothing set up, a
  file shared "anyone with the link" can still be added and downloaded;
- where it's going, **Download**, a progress bar, **Stop**, and a log of what happened to each file.

Listing and downloading run on worker threads (four files at a time); everything shown is handed back through
`_Bridge`. While a download runs the window sets `running`, so Quit asks first.
"""
from __future__ import annotations

import os
import shutil
import tempfile
import threading
import time
import webbrowser
from concurrent.futures import ThreadPoolExecutor, as_completed

from PySide6.QtCore import QObject, Qt, QUrl, Signal
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import (QComboBox, QDialog, QFileDialog, QFormLayout, QHBoxLayout, QLabel, QLineEdit,
                               QMessageBox, QPlainTextEdit, QProgressBar, QPushButton, QTreeWidget, QTreeWidgetItem,
                               QVBoxLayout, QWidget)

import gdrive as G

ITEM = Qt.ItemDataRole.UserRole
LOADED = Qt.ItemDataRole.UserRole + 1
PLACES = (("My Drive", "root"), ("Shared with me", "shared"), ("Starred", "starred"), ("Shared drives", "drives"))


def size_text(n: int) -> str:
    if n <= 0:
        return ""
    for unit, div in (("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10)):
        if n >= div:
            return f"{n / div:.1f} {unit}" if n < 100 * div else f"{n / div:.0f} {unit}"
    return f"{n} bytes"


def when_text(ts: float) -> str:
    return time.strftime("%d %b %Y", time.localtime(ts)) if ts > 0 else ""


class _Bridge(QObject):
    call = Signal(object, object)

    def __init__(self) -> None:
        super().__init__()
        self.call.connect(lambda fn, arg: fn(arg))


class SetupDialog(QDialog):
    """Set Up…: the person's own Google Cloud client (and, optionally, an API key), with how to get them."""

    def __init__(self, auth: G.Auth, parent=None) -> None:
        super().__init__(parent)
        self.auth = auth
        self.setWindowTitle("Google Drive — Set Up")
        self.setMinimumWidth(620)
        v = QVBoxLayout(self)
        steps = QLabel(G.SETUP_STEPS)
        steps.setWordWrap(True)
        steps.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        v.addWidget(steps)
        form = QFormLayout()
        self.client_id = QLineEdit(auth.client_id)
        self.client_id.setPlaceholderText("…apps.googleusercontent.com")
        self.client_secret = QLineEdit(G.secret("client-secret"))
        self.client_secret.setEchoMode(QLineEdit.EchoMode.Password)
        self.api_key = QLineEdit(auth.api_key)
        self.api_key.setPlaceholderText("optional — for “anyone with the link” items, without signing in")
        form.addRow("Client ID", self.client_id)
        form.addRow("Client secret", self.client_secret)
        form.addRow("API key", self.api_key)
        v.addLayout(form)
        row = QHBoxLayout()
        console = QPushButton("Open Google Cloud Console")
        console.clicked.connect(lambda: QDesktopServices.openUrl(QUrl(G.CONSOLE)))
        row.addWidget(console)
        row.addStretch(1)
        cancel = QPushButton("Cancel")
        cancel.clicked.connect(self.reject)
        save = QPushButton("Save")
        save.setObjectName("Primary")
        save.setDefault(True)
        save.clicked.connect(self._save)
        row.addWidget(cancel)
        row.addWidget(save)
        v.addLayout(row)

    def _save(self) -> None:
        self.auth.save_setup(self.client_id.text(), self.client_secret.text(), self.api_key.text())
        self.accept()


class DriveWindow(QWidget):
    finished = Signal(str, list)           # (the folder downloaded into, the files that arrived)

    def __init__(self, folder: str, parent=None) -> None:
        super().__init__(parent, Qt.WindowType.Window)
        self.setWindowTitle("Google Drive")
        self.resize(860, 680)
        self.dest = folder
        self.auth = G.Auth()
        self.client = G.Client(self.auth)
        self.bridge = _Bridge()
        self.running = False               # a download under way (Quit asks — MainWindow.busy_windows)
        self.signing_in = False
        self.stop = threading.Event()
        self.cancel_sign_in = threading.Event()
        self.public: dict[str, tuple[G.Item, str]] = {}      # files added by link with nothing set up
        self.serial = 0                    # the listing on show (an answer for an older one is dropped)

        v = QVBoxLayout(self)
        top = QHBoxLayout()
        self.account = QLabel("")
        self.sign_btn = QPushButton("Sign In with Google…")
        self.sign_btn.clicked.connect(self._sign)
        self.out_btn = QPushButton("Sign Out")
        self.out_btn.clicked.connect(self._sign_out)
        setup = QPushButton("Set Up…")
        setup.clicked.connect(self._setup)
        top.addWidget(self.account, 1)
        top.addWidget(self.sign_btn)
        top.addWidget(self.out_btn)
        top.addWidget(setup)
        v.addLayout(top)

        bar = QHBoxLayout()
        self.place = QComboBox()
        for label, key in PLACES:
            self.place.addItem(label, key)
        self.place.currentIndexChanged.connect(lambda _i: self.reload())
        self.search = QLineEdit()
        self.search.setPlaceholderText("Search Drive by name")
        self.search.setClearButtonEnabled(True)
        self.search.returnPressed.connect(self.reload)
        reload_btn = QPushButton("Reload")
        reload_btn.clicked.connect(self.reload)
        bar.addWidget(self.place)
        bar.addWidget(self.search, 1)
        bar.addWidget(reload_btn)
        v.addLayout(bar)

        links = QHBoxLayout()
        self.links = QLineEdit()
        self.links.setPlaceholderText("…or paste Google Drive links here — files or folders, one or several")
        self.links.returnPressed.connect(self._add_links)
        add = QPushButton("Add Links")
        add.clicked.connect(self._add_links)
        links.addWidget(self.links, 1)
        links.addWidget(add)
        v.addLayout(links)

        self.tree = QTreeWidget()
        self.tree.setColumnCount(3)
        self.tree.setHeaderLabels(["Name", "Modified", "Size"])
        self.tree.setColumnWidth(0, 520)
        self.tree.setColumnWidth(1, 120)
        self.tree.setAlternatingRowColors(True)
        self.tree.setAccessibleName("Google Drive items")
        self.tree.itemExpanded.connect(self._expanded)
        self.tree.itemChanged.connect(lambda _it, _col: self._update())
        v.addWidget(self.tree, 1)
        self.hint = QLabel("")
        self.hint.setWordWrap(True)
        self.hint.setObjectName("SheetSub")
        v.addWidget(self.hint)

        into = QHBoxLayout()
        self.into = QLabel("")
        choose = QPushButton("Choose…")
        choose.clicked.connect(self._choose)
        into.addWidget(self.into, 1)
        into.addWidget(choose)
        v.addLayout(into)

        self.progress = QProgressBar()
        self.progress.setVisible(False)
        v.addWidget(self.progress)
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumHeight(120)
        self.log.setVisible(False)
        v.addWidget(self.log)

        bottom = QHBoxLayout()
        self.status = QLabel("")
        self.status.setObjectName("SheetSub")
        self.stop_btn = QPushButton("Stop")
        self.stop_btn.clicked.connect(self._stop)
        self.stop_btn.setEnabled(False)
        self.go = QPushButton("Download")
        self.go.setObjectName("Primary")
        self.go.clicked.connect(self.download)
        bottom.addWidget(self.status, 1)
        bottom.addWidget(self.stop_btn)
        bottom.addWidget(self.go)
        v.addLayout(bottom)

        self._show_account()
        self._show_dest()
        self.reload()

    # ------------------------------------------------------------------ small things
    def _say(self, text: str) -> None:
        self.status.setText(text)

    def _note(self, line: str) -> None:
        self.log.setVisible(True)
        self.log.appendPlainText(time.strftime("%H:%M:%S ") + line)

    def _show_dest(self) -> None:
        self.into.setText(f"Into “{os.path.basename(self.dest.rstrip(os.sep)) or self.dest}” — {self.dest}")

    def _choose(self) -> None:
        picked = QFileDialog.getExistingDirectory(self, "Download Into", self.dest)
        if picked:
            self.dest = picked
            self._show_dest()

    def _show_account(self) -> None:
        signed = self.auth.signed_in()
        if self.signing_in:
            self.account.setText("Waiting for you to finish signing in, in your browser…")
        elif signed:
            self.account.setText(f"Signed in to Google Drive as {self.auth.email}" if self.auth.email
                                 else "Signed in to Google Drive")
        elif self.auth.api_key:
            self.account.setText("Not signed in — an API key is set: links shared with “anyone with the link” work")
        else:
            self.account.setText("Not signed in")
        self.sign_btn.setText("Cancel Sign-In" if self.signing_in else "Sign In with Google…")
        self.sign_btn.setVisible(self.signing_in or not signed)
        self.out_btn.setVisible(signed and not self.signing_in)
        browse = signed
        self.place.setEnabled(browse)
        self.search.setEnabled(browse)

    def _setup(self) -> None:
        if SetupDialog(self.auth, self).exec():
            self._show_account()
            self.reload()

    # ------------------------------------------------------------------ signing in and out
    def _sign(self) -> None:
        if self.signing_in:
            self.cancel_sign_in.set()
            return
        if not self.auth.can_sign_in():
            self._setup()
            if not self.auth.can_sign_in():
                return
        self.signing_in = True
        self.cancel_sign_in.clear()
        self._show_account()
        bridge, auth, cancel = self.bridge, self.auth, self.cancel_sign_in

        def work() -> None:
            try:
                auth.sign_in(webbrowser.open, cancel.is_set)
                result = ""
            except G.Stopped:
                result = "cancelled"
            except G.DriveError as e:
                result = str(e)
            except Exception as e:  # noqa: BLE001 — whatever went wrong, the window says so
                result = f"The sign-in failed ({type(e).__name__}: {e})."
            bridge.call.emit(self._signed, result)
        threading.Thread(target=work, daemon=True).start()

    def _signed(self, problem: str) -> None:
        self.signing_in = False
        self._show_account()
        if problem and problem != "cancelled":
            QMessageBox.warning(self, "Google Drive", problem)
        self.raise_()
        self.activateWindow()
        self.reload()

    def _sign_out(self) -> None:
        auth, bridge = self.auth, self.bridge
        threading.Thread(target=lambda: (auth.sign_out(), bridge.call.emit(lambda _a: (self._show_account(), self.reload()), None)),
                         daemon=True).start()

    # ------------------------------------------------------------------ the list
    def _row(self, item: G.Item, parent=None, checked: bool = False) -> QTreeWidgetItem:
        it = QTreeWidgetItem([("📁 " if item.is_folder else "") + item.name, when_text(item.modified),
                              "" if item.is_folder else ("Google document" if item.is_doc else size_text(item.size))])
        it.setData(0, ITEM, item)
        if item.is_doc:
            it.setFlags(it.flags() & ~Qt.ItemFlag.ItemIsUserCheckable)
            it.setToolTip(0, "One of Google's own documents — there's no file to download (export it from Drive)")
            it.setDisabled(True)
        else:
            it.setFlags(it.flags() | Qt.ItemFlag.ItemIsUserCheckable)
            it.setCheckState(0, Qt.CheckState.Checked if checked else Qt.CheckState.Unchecked)
        if item.is_folder:
            it.setChildIndicatorPolicy(QTreeWidgetItem.ChildIndicatorPolicy.ShowIndicator)
            it.setToolTip(0, "Tick it to download everything inside")
        (parent.addChild if parent is not None else self.tree.addTopLevelItem)(it)
        return it

    def reload(self) -> None:
        """The place (or search) on show, read again. Links added by hand stay."""
        self.serial += 1
        serial = self.serial
        kept = [self.tree.topLevelItem(i) for i in range(self.tree.topLevelItemCount())]
        kept = [(it.data(0, ITEM), it.checkState(0) == Qt.CheckState.Checked) for it in kept if it.data(0, LOADED) == "link"]
        self.tree.blockSignals(True)
        self.tree.clear()
        for item, checked in kept:
            self._row(item, checked=checked).setData(0, LOADED, "link")
        self.tree.blockSignals(False)
        self._update()
        if not self.auth.signed_in():
            self.hint.setText("Sign in to browse your Drive — or paste links above. " + (
                "" if self.auth.can_sign_in() or self.auth.api_key else
                "First time? Press Set Up… for the one-time steps. A single file shared with “anyone with the link” "
                "can be pasted and downloaded without any of it."))
            return
        words = self.search.text().strip()
        which = self.place.currentData()
        self.hint.setText("Reading Drive…")
        client, bridge = self.client, self.bridge

        def work() -> None:
            try:
                got = client.search(words) if words else client.place(which)
                bridge.call.emit(lambda items: self._listed(serial, items, ""), got)
            except G.DriveError as e:
                bridge.call.emit(lambda why: self._listed(serial, [], why), str(e))
            except Exception as e:  # noqa: BLE001
                bridge.call.emit(lambda why: self._listed(serial, [], why), f"{type(e).__name__}: {e}")
        threading.Thread(target=work, daemon=True).start()

    def _listed(self, serial: int, items: list, why: str) -> None:
        if serial != self.serial:
            return
        self.tree.blockSignals(True)
        for item in items:
            self._row(item)
        self.tree.blockSignals(False)
        if why:
            self.hint.setText(why)
            self._show_account()                       # (a sign-in Google ended shows as signed out)
        else:
            self.hint.setText("Tick files — or a folder, for everything inside it — then Download. Click a folder's "
                              "arrow to look inside." if items else "Nothing here.")
        self._update()

    def _expanded(self, it: QTreeWidgetItem) -> None:
        item = it.data(0, ITEM)
        if item is None or not item.is_folder or it.data(0, LOADED) in ("yes", "loading"):
            return
        was = it.data(0, LOADED)
        it.setData(0, LOADED, "loading")
        client, bridge = self.client, self.bridge

        def work() -> None:
            try:
                bridge.call.emit(lambda kids: self._filled(it, kids, "", was), client.children(item.real_id))
            except G.DriveError as e:
                bridge.call.emit(lambda why: self._filled(it, [], why, was), str(e))
        threading.Thread(target=work, daemon=True).start()

    def _filled(self, it: QTreeWidgetItem, kids: list, why: str, was) -> None:
        try:
            it.data(0, ITEM)
        except RuntimeError:                           # the list was reloaded meanwhile
            return
        self.tree.blockSignals(True)
        for kid in kids:
            self._row(kid, it)
        self.tree.blockSignals(False)
        it.setData(0, LOADED, "yes" if not why else was)
        if why:
            self._say(why)
        elif not kids:
            it.setChildIndicatorPolicy(QTreeWidgetItem.ChildIndicatorPolicy.DontShowIndicator)

    def _add_links(self) -> None:
        ids = G.ids_in(self.links.text())
        if not ids:
            self._say("No Google Drive link in that.")
            return
        self.links.clear()
        self._say(f"Looking at {len(ids)} link{'s' if len(ids) != 1 else ''}…")
        client, bridge, auth = self.client, self.bridge, self.auth
        with_api = auth.signed_in() or bool(auth.api_key)

        def work() -> None:
            found, problems, public = [], [], {}
            for file_id in ids:
                try:
                    if with_api:
                        found.append(client.info(file_id))
                    else:
                        item, url, why = G.public_item(file_id)
                        if item is None:
                            problems.append(f"{file_id}: {why}")
                        else:
                            found.append(item)
                            public[item.id] = (item, url)
                except G.DriveError as e:
                    problems.append(f"{file_id}: {e}")
            bridge.call.emit(self._links_added, (found, problems, public))
        threading.Thread(target=work, daemon=True).start()

    def _links_added(self, result) -> None:
        found, problems, public = result
        self.public.update(public)
        have = {self.tree.topLevelItem(i).data(0, ITEM).id for i in range(self.tree.topLevelItemCount())
                if self.tree.topLevelItem(i).data(0, ITEM) is not None}
        self.tree.blockSignals(True)
        for item in found:
            if item.id not in have:
                row = self._row(item, checked=not item.is_doc)
                row.setData(0, LOADED, "link")
                self.tree.insertTopLevelItem(0, self.tree.takeTopLevelItem(self.tree.indexOfTopLevelItem(row)))
        self.tree.blockSignals(False)
        for line in problems:
            self._note(line)
        self._say(f"Added {len(found)} from the link{'s' if len(found) != 1 else ''}."
                  + (f" {len(problems)} couldn't be added — see below." if problems else ""))
        self._update()

    def picked(self) -> list[G.Item]:
        """The ticked items — a ticked folder stands for everything in it, so what's ticked inside one isn't
        listed again."""
        out: list[G.Item] = []

        def visit(it: QTreeWidgetItem) -> None:
            item = it.data(0, ITEM)
            if item is not None and it.checkState(0) == Qt.CheckState.Checked and not item.is_doc:
                out.append(item)
                if item.is_folder:
                    return
            for i in range(it.childCount()):
                visit(it.child(i))
        for i in range(self.tree.topLevelItemCount()):
            visit(self.tree.topLevelItem(i))
        return out

    def _update(self) -> None:
        if self.running:
            return
        items = self.picked()
        folders = sum(1 for i in items if i.is_folder)
        files = len(items) - folders
        parts = [f"{files} file{'s' if files != 1 else ''}"] if files else []
        if folders:
            parts.append(f"{folders} folder{'s' if folders != 1 else ''}")
        self.go.setText("Download " + " and ".join(parts) if parts else "Download")
        self.go.setEnabled(bool(items))

    # ------------------------------------------------------------------ downloading
    def _stop(self) -> None:
        self.stop.set()
        self._say("Stopping — files already arrived are kept…")

    def download(self) -> None:
        items = self.picked()
        if self.running or not items:
            return
        if not os.path.isdir(self.dest):
            QMessageBox.warning(self, "Google Drive", f"“{self.dest}” isn't there — choose where to download into.")
            return
        self.running = True
        self.stop.clear()
        self.go.setEnabled(False)
        self.stop_btn.setEnabled(True)
        self.progress.setVisible(True)
        self.progress.setRange(0, 0)
        self._say("Reading what's to download…")
        dest, client, bridge, stop, public = self.dest, self.client, self.bridge, self.stop, dict(self.public)
        say = lambda text: bridge.call.emit(self._say, text)             # noqa: E731
        note = lambda text: bridge.call.emit(self._note, text)           # noqa: E731

        def work() -> None:
            arrived: list[str] = []
            summary = ""
            tmp = tempfile.mkdtemp(prefix="pb-gdrive-")
            try:
                by_link = [i for i in items if i.id in public and not (client.auth.signed_in() or client.auth.api_key)]
                rest = [i for i in items if i not in by_link]
                plan = client.plan(rest, dest, stop.is_set, say) if rest else G.Plan()
                for line in plan.unread:
                    note(f"Couldn't read a folder — {line}")
                G.make_folders(plan)
                total = plan.bytes + sum(i.size for i in by_link)
                count = len(plan.jobs) + len(by_link)
                bridge.call.emit(lambda n: self.progress.setRange(0, max(1, n)), 1000)
                done_bytes: dict[str, int] = {}
                lock = threading.Lock()
                finished = [0]
                failed: list[str] = []

                def progress_of(key: str):
                    def tick(have: int, _total) -> None:
                        with lock:
                            done_bytes[key] = have
                            got = sum(done_bytes.values())
                        if total:
                            bridge.call.emit(self.progress.setValue, int(1000 * min(1.0, got / total)))
                    return tick

                def one(job_or_item):
                    if stop.is_set():
                        return None
                    if isinstance(job_or_item, G.Job):
                        return client.download(job_or_item, tmp, stop.is_set, progress_of(job_or_item.item.real_id))
                    item, url = public[job_or_item.id]
                    return G.public_download(item, url, dest, tmp, stop.is_set, progress_of(item.id))

                say(f"Downloading {count} file{'s' if count != 1 else ''}"
                    + (f" ({size_text(total)})" if total else "") + "…")
                with ThreadPoolExecutor(max_workers=G.LANES, thread_name_prefix="gdrive") as pool:
                    futures = [pool.submit(one, x) for x in list(plan.jobs) + by_link]
                    for fut in as_completed(futures):
                        d = fut.result()
                        if d is None:
                            continue
                        finished[0] += 1
                        if d.path and d.why == "already here":
                            plan.here += 1
                        elif d.path:
                            arrived.append(d.path)
                            if not d.dated:
                                note(f"{os.path.basename(d.path)}: downloaded, but its date couldn't be set")
                        elif d.why != "stopped":
                            failed.append(d.job.item.name)
                            note(f"{d.job.item.name}: {d.why}")
                        say(f"{finished[0]} of {count} — {len(arrived)} downloaded"
                            + (f", {len(failed)} failed" if failed else ""))
                G.date_folders(plan)
                bits = [f"{len(arrived)} downloaded" if arrived else "Nothing new downloaded"]
                if plan.here:
                    bits.append(f"{plan.here} already here")
                if failed:
                    bits.append(f"{len(failed)} failed (see below)")
                if plan.docs:
                    bits.append(f"{plan.docs} Google document{'s' if plan.docs != 1 else ''} left (not files)")
                if stop.is_set():
                    bits.append("stopped")
                summary = ", ".join(bits) + "."
            except G.Stopped:
                summary = "Stopped."
            except G.DriveError as e:
                summary = str(e)
            except Exception as e:  # noqa: BLE001 — never a silent end
                summary = f"The download stopped: {type(e).__name__}: {e}"
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
            bridge.call.emit(self._downloaded, (summary, arrived, dest))
        threading.Thread(target=work, daemon=True).start()

    def _downloaded(self, result) -> None:
        summary, arrived, dest = result
        self.running = False
        self.stop_btn.setEnabled(False)
        self.progress.setVisible(False)
        self._say(summary)
        self._note(summary)
        self._show_account()
        self._update()
        self.finished.emit(dest, list(arrived))

    def closeEvent(self, event) -> None:  # noqa: N802
        if self.running and QMessageBox.question(
                self, "Google Drive", "A download is under way. Stop it and close? (Files already downloaded are "
                "kept.)") != QMessageBox.StandardButton.Yes:
            event.ignore()
            return
        self.stop.set()
        self.cancel_sign_in.set()
        super().closeEvent(event)

