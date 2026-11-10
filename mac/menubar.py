"""Safe Finder's menu bar — the Mac way to find everything: File, Edit, View, Go, Photos, Window, Help. Every
command acts on the pane you're in (the one with the blue FROM/TO chip) and what's selected there, as
Finder's menus do, and greys out when it can't.

The keyboard shortcuts live here — one action per command — rather than on each pane, so a key is never
bound twice (two live shortcuts for one key make Qt fire neither). Return (open) and Space (Quick Look)
stay on the panes: they belong to the list you're typing in.

`install(window, sf)` takes the main window and the safe_finder module (passed in rather than imported:
run as a script, safe_finder is `__main__`, and importing it by name would load a second copy).
"""
from __future__ import annotations

import os
from pathlib import Path

from PySide6.QtCore import QUrl
from PySide6.QtGui import QAction, QActionGroup, QDesktopServices, QKeySequence


def install(win, sf) -> None:
    bar = win.menuBar()
    pane = lambda: win.active_pane                      # noqa: E731 — read at the moment of use
    acts: list[QAction] = []

    def act(menu, text: str, slot, keys: str | None = None, check=None, tip: str = "") -> QAction:
        a = QAction(text, win)
        if keys:
            a.setShortcut(QKeySequence(keys))
        if tip:
            a.setStatusTip(tip)
            a.setToolTip(tip)
        a.triggered.connect(lambda _=False: slot())
        a.setData(check)
        menu.addAction(a)
        win.addAction(a)                                # its shortcut works wherever the window has focus
        acts.append(a)
        return a

    def refresh(menu) -> None:
        for a in menu.actions():
            check = a.data()
            if callable(check):
                try:
                    a.setEnabled(bool(check()))
                except Exception:  # noqa: BLE001 — a check that fails just leaves the command on
                    a.setEnabled(True)

    def sel() -> list[str]:
        try:
            return pane().selected_paths()
        except Exception:  # noqa: BLE001
            return []

    def real_folder() -> bool:
        p = pane()
        return not p.is_virtual and os.path.isdir(p.location)

    def folder_target() -> str | None:
        """The one folder selected, else the folder you're in."""
        s = sel()
        if len(s) == 1 and os.path.isdir(s[0]):
            return s[0]
        return pane().location if real_folder() else None

    def photos() -> list[str]:
        return [p for p in sel() if os.path.splitext(p)[1].lower() in sf.batch_crop.CROPPABLE]

    def editable() -> list[str]:
        """Selected photos and videos that can hold metadata, and selected folders (everything inside)."""
        return [p for p in sel() if os.path.isdir(p) or sf.metadata_edit.can_edit(p)]

    def watermarkable() -> list[str]:
        """Selected photos and folders (the photos inside)."""
        return [p for p in sel() if os.path.isdir(p) or os.path.splitext(p)[1].lower() in sf.batch_crop.CROPPABLE]

    def videos() -> list[str]:
        return [p for p in sel() if sf.kind_of(p) == "video"]

    def webp_targets() -> list[str]:
        """Selected WebPs, else selected folders, else the folder you're in."""
        s = sel()
        webps = [p for p in s if sf.webp_convert.is_webp(p) and not os.path.isdir(p)]
        return webps or [p for p in s if os.path.isdir(p)] or ([pane().location] if real_folder() else [])

    def sendable() -> list[str]:
        """Selected photos, videos and folders for CapCut — else the folder you're in."""
        s = [p for p in sel() if os.path.isdir(p) or sf.capcut.is_clip(p)]
        return s or ([pane().location] if real_folder() else [])

    def texts() -> list[str]:
        return [p for p in sel() if os.path.splitext(p)[1].lower() in (".txt", ".text", ".md", ".markdown", ".rtf")
                and not os.path.isdir(p)]

    def each(menu_title: str):
        m = bar.addMenu(menu_title)
        m.aboutToShow.connect(lambda m=m: refresh(m))
        return m

    # -- File
    f = each("File")
    act(f, "New Folder", lambda: pane().new_folder(), "Ctrl+Shift+N", real_folder)
    act(f, "Open", lambda: pane().open_selected(), "Ctrl+Down", lambda: bool(sel()))
    act(f, "Open With Default App", lambda: pane().open_external(), None,
        lambda: any(sf.kind_of(p) != "other" for p in sel()))
    act(f, "Quick Look  (Space)", lambda: pane().quick_look(), None, lambda: bool(sel()) and sf.IS_MAC)
    act(f, "Show in Finder", lambda: sf.subprocess.Popen(["open", "-R", sel()[0]]) if sel() else None, None,
        lambda: bool(sel()) and sf.IS_MAC)
    f.addSeparator()
    act(f, "Copy to the Other Side", lambda: win.transfer_selection(False), "Ctrl+Shift+C",
        lambda: not win.split or win.copy_btn.isEnabled())
    act(f, "Move to the Other Side", lambda: win.transfer_selection(True), "Ctrl+Shift+M",
        lambda: not win.split or win.move_btn.isEnabled())
    act(f, "AirDrop to iPhone…", lambda: pane().airdrop(sel()), None, lambda: bool(sel()) and sf.IS_MAC)
    act(f, "Make Book PDF…", lambda: pane().make_book(texts()), None, lambda: bool(texts()),
        "The selected .txt / .md / .rtf typeset like a printed book (bookify) — a PDF beside it")
    f.addSeparator()
    act(f, "Move to Trash", lambda: pane().delete_selection(), "Ctrl+Backspace", lambda: bool(sel()))

    # -- Edit
    e = each("Edit")
    act(e, "Select All", lambda: pane().view().selectAll(), "Ctrl+A")
    act(e, "Find", lambda: (pane().search.setFocus(), pane().search.selectAll()), "Ctrl+F")
    e.addSeparator()
    act(e, "Tags…", lambda: pane().edit_tags(), "Ctrl+T", lambda: bool(sel()))

    # -- View
    v = each("View")
    modes = QActionGroup(win)
    mode_acts = {}
    for key, label, keys in (("grid", "as Icons", "Ctrl+1"), ("list", "as List", "Ctrl+2"),
                             ("photos", "as Photos", "Ctrl+3")):
        a = act(v, label, lambda key=key: pane().set_mode(key), keys)
        a.setCheckable(True)
        modes.addAction(a)
        mode_acts[key] = a
    v.aboutToShow.connect(lambda: mode_acts.get(pane().mode(), mode_acts["grid"]).setChecked(True))
    v.addSeparator()
    split = act(v, "Split View", lambda: win.set_split(not win.split), "Ctrl+\\",
                tip="A second pane beside this one, with Move and Copy, for transfers")
    split.setCheckable(True)
    split.setChecked(win.split)
    v.addSeparator()
    sort = v.addMenu("Sort By")
    sort_group = QActionGroup(win)
    sort_acts = {}
    for key, label in sf.SORT_KEYS:
        a = QAction(label, win)
        a.setCheckable(True)
        a.triggered.connect(lambda _=False, key=key: pane().choose_sort(key))
        sort_group.addAction(a)
        sort.addAction(a)
        sort_acts[key] = a
    sort.addSeparator()
    flip = QAction("Reverse Order", win)
    flip.triggered.connect(lambda: (lambda k, o: pane().set_sort(k, sf.Qt.SortOrder.AscendingOrder
                                                                  if o == sf.Qt.SortOrder.DescendingOrder
                                                                  else sf.Qt.SortOrder.DescendingOrder))(*pane().current_sort()))
    sort.addAction(flip)
    sort.aboutToShow.connect(lambda: sort_acts.get(pane().current_sort()[0], sort_acts["name"]).setChecked(True))
    v.addSeparator()
    act(v, "Bigger Thumbnails", lambda: pane().slider.setValue(min(320, pane().slider.value() + 24)), "Ctrl+=")
    act(v, "Smaller Thumbnails", lambda: pane().slider.setValue(max(48, pane().slider.value() - 24)), "Ctrl+-")

    # -- Go
    g = each("Go")
    act(g, "Back", lambda: pane().go_back(), "Ctrl+[")
    act(g, "Forward", lambda: pane().go_forward(), "Ctrl+]")
    act(g, "Enclosing Folder", lambda: pane().go_up(), "Ctrl+Up", real_folder)
    g.addSeparator()
    home = Path.home()
    act(g, "Home", lambda: pane().go(str(home)), "Ctrl+Shift+H")
    act(g, "Desktop", lambda: pane().go(str(home / "Desktop")), "Ctrl+Shift+D")
    act(g, "Downloads", lambda: pane().go(str(home / "Downloads")), "Ctrl+Alt+L")
    act(g, "Pictures", lambda: pane().go(str(home / "Pictures")))
    act(g, "All Videos", lambda: win._navigate(sf.VIDEOS))
    act(g, "Empty Folders", lambda: win._navigate(sf.EMPTY))
    act(g, "Favorites", lambda: win._navigate(sf.LABEL + "favorite"))
    act(g, "To AI", lambda: win._navigate(sf.LABEL + "ai"))
    drives = g.addMenu("Drives")

    def fill_drives() -> None:
        drives.clear()
        vols = sf.external_volumes()
        if not vols:
            a = drives.addAction("No drive connected")
            a.setEnabled(False)
        for vol in vols:
            drives.addAction(vol.name, lambda vol=vol: pane().go(str(vol)))
    drives.aboutToShow.connect(fill_drives)

    # -- Photos: the tools
    t = each("Photos")
    act(t, "Edit Metadata…", lambda: pane().edit_metadata(editable()) if editable() else None, "Ctrl+I",
        lambda: bool(editable()),
        "Capture date, location, caption, keywords, camera and any other tag — of everything selected")
    act(t, "Favorite", lambda: pane().toggle_label("favorite"), "Ctrl+Shift+F", lambda: bool(sel()),
        "Favorite the selection (or unfavorite it, when it all is) — the iPhone app's Favorites")
    act(t, "To AI", lambda: pane().toggle_label("ai"), "Ctrl+Shift+A", lambda: bool(sel()),
        "Mark the selection To AI (or take it off) — the iPhone app's To AI")
    t.addSeparator()
    act(t, "Find Duplicates…", lambda: pane().find_duplicates(folder_target()), None, folder_target,
        "Likely copies in the selected folder (or this one)")
    act(t, "Export All Frames…", lambda: pane().export_frames(videos()), None, lambda: bool(videos()))
    t.addSeparator()
    act(t, "Send to CapCut", lambda: pane().send_to_capcut(sendable()), "Ctrl+Shift+K", lambda: bool(sendable()),
        "Opens CapCut with the selected clips (or this folder's) beside it, in order, to drag in — and brings "
        "CapCut's exports back")
    act(t, "Import from CapCut…", lambda: pane().import_from_capcut(folder_target()), None, None,
        "CapCut's finished videos, onto the drive — into this folder, or back where their clips came from")
    t.addSeparator()
    act(t, "Convert WebP to JPEG…", lambda: pane().convert_webp(webp_targets()), None, lambda: bool(webp_targets()),
        "Every WebP selected (or in the selected folder, or this one) as a full-resolution, quality-95 JPEG")
    act(t, "Crop…", lambda: pane().crop_photos(photos()), None, lambda: bool(photos()))
    act(t, "AI Upscale 2×…", lambda: pane().ai_upscale(photos()), None, lambda: bool(photos()))
    act(t, "Erase Area…", lambda: pane().erase_area(photos()), None, lambda: bool(photos()))
    act(t, "Remove Watermark…", lambda: pane().remove_watermark(watermarkable()), None, lambda: bool(watermarkable()),
        "Your own see-through watermark, learned once and taken out of every selected photo (or every photo inside "
        "the selected folders)")
    act(t, "Remove Objects…", lambda: pane().remove_objects(photos()[0]) if len(photos()) == 1 else None, None,
        lambda: len(photos()) == 1, "Draw round anything in the photo and it's gone — filled in from the photo itself")
    t.addSeparator()
    act(t, "Edit with AI…", lambda: pane().ai_edit(photos()[0]), None, lambda: len(photos()) == 1)
    act(t, "Create with AI…", lambda: pane().ai_create(folder_target()), None, folder_target)
    act(t, "Astria.ai Browser…", lambda: pane().astria_browser(folder_target() or str(home / "Pictures")))
    t.addSeparator()
    act(t, "Download from SimpCity…", lambda: sf.open_simpcity(folder_target(), win), None, folder_target)
    act(t, "Get Reaction Scores", lambda: sf.open_simpcity(sf.simpcity_scores_folder(folder_target()), win,
                                                           scores_only=True), None,
        lambda: folder_target() is not None and sf.simpcity_scores_folder(folder_target()) is not None)
    act(t, "Download Instagram Profile…", lambda: sf.open_social("instagram", folder_target(), win), None,
        folder_target)
    act(t, "Download Facebook Profile…", lambda: sf.open_social("facebook", folder_target(), win), None,
        folder_target)
    act(t, "Download TikTok Profile…", lambda: sf.open_tiktok(folder_target(), win), None, folder_target,
        "A TikTok profile's videos, watermark-free, into its @handle folder (the iPhone app's) — with every "
        "video's like count read again")
    act(t, "Download from Fanfix…", lambda: sf.open_fanfix(folder_target(), win), None, folder_target,
        "Your purchased content from Fanfix creators, into a folder for each creator")
    act(t, sf.passes_label(folder_target()) if folder_target() else "Download Passes…",
        lambda: sf.open_passes(folder_target(), win), None, folder_target)
    act(t, "Browse taylorpictures.net…", lambda: pane().open_taylor(
        folder_target() or str(win.settings.value("taylor/root") or "")), None,
        lambda: folder_target() is not None or bool(win.settings.value("taylor/root")))

    # -- Window
    w = each("Window")
    act(w, "Minimize", win.showMinimized, "Ctrl+M")
    act(w, "Zoom", lambda: win.showNormal() if win.isMaximized() else win.showMaximized())
    w.addSeparator()
    act(w, "Safe Finder", lambda: (win.showNormal() if win.isMinimized() else None, win.raise_(),
                                   win.activateWindow()))
    others = []

    def fill_windows() -> None:
        for a in others:
            w.removeAction(a)
        others.clear()
        for x in list(sf._VIEWERS):
            try:
                title = x.windowTitle()
            except RuntimeError:
                continue
            if not title:
                continue
            a = QAction(title, win)
            a.triggered.connect(lambda _=False, x=x: (x.showNormal(), x.raise_(), x.activateWindow()))
            w.addAction(a)
            others.append(a)
    w.aboutToShow.connect(fill_windows)

    # -- Help
    h = each("Help")
    readme = Path(__file__).with_name("README.md")
    act(h, "Safe Finder Help", lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(str(readme))))
    win.menu_actions = {a.text(): a for a in acts}
