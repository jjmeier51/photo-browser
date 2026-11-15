"""Photo Browser for Mac's menu bar — the Mac way to find everything: File, Edit, View, Go, Photos, Window, Help. Every
command acts on the pane you're in (the one with the blue FROM/TO chip) and what's selected there, as
Finder's menus do, and greys out when it can't.

The Photos menu keeps what's used every day at the top (Edit Metadata, Favorite, To AI, Find Duplicates) and
groups the rest the way the right-click menu does — Adjust ▸, Retouch ▸, Video ▸, CapCut ▸, AI ▸, Download ▸ —
so no menu is a screenful. Every command, wherever it lives, is also in **Edit ▸ Find a Command…** (⇧⌘P).

The keyboard shortcuts live here — one action per command — rather than on each pane, so a key is never
bound twice (two live shortcuts for one key make Qt fire neither). Return (open) and Space (Quick Look)
stay on the panes: they belong to the list you're typing in.

`install(window, sf)` takes the main window and the photo_browser module (passed in rather than imported:
run as a script, photo_browser is `__main__`, and importing it by name would load a second copy).
"""
from __future__ import annotations

import os
from pathlib import Path

from PySide6.QtGui import QAction, QActionGroup, QKeySequence

import app_identity


def install(win, sf) -> None:
    bar = win.menuBar()
    pane = lambda: win.active_pane                      # noqa: E731 — read at the moment of use
    acts: list[QAction] = []

    def act(menu, text: str, slot, keys: str | list[str] | None = None, check=None, tip: str = "",
            role=QAction.MenuRole.NoRole) -> QAction:
        a = QAction(text, win)
        a.setMenuRole(role)        # NoRole: macOS doesn't move a command to the app menu because of its wording
        if isinstance(keys, list):
            a.setShortcuts([QKeySequence(k) for k in keys])
        elif keys:
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
        m.setToolTipsVisible(True)
        m.aboutToShow.connect(lambda m=m: refresh(m))
        return m

    def submenu(parent, title: str):
        """A submenu whose commands grey out like the top-level ones."""
        m = parent.addMenu(title)
        m.setToolTipsVisible(True)
        m.aboutToShow.connect(lambda m=m: refresh(m))
        return m

    # -- File
    f = each("File")
    act(f, "New Folder", lambda: pane().new_folder(), "Ctrl+Shift+N", real_folder)
    act(f, "Open", lambda: pane().open_selected(), ["Ctrl+O", "Ctrl+Down"], lambda: bool(sel()))
    act(f, "Open With Default App", lambda: pane().open_external(), None,
        lambda: any(sf.kind_of(p) != "other" for p in sel()))
    act(f, "Quick Look", lambda: pane().quick_look(), None, lambda: bool(sel()) and sf.IS_MAC,
        "A quick look at the selection without opening it — press Space in the file list")
    act(f, "Show in Finder", lambda: sf.subprocess.Popen(["open", "-R", sel()[0]]) if sel() else None, None,
        lambda: bool(sel()) and sf.IS_MAC)
    act(f, "Rename…", lambda: pane().rename_item(sel()[0]) if len(sel()) == 1 else
        pane().rename_many(sel()) if sel() else None, "F2", lambda: bool(sel()),
        "A new name for the selected file or folder — or, with several selected, names for them all by a pattern "
        "(numbers, the capture date…). Tags, Favorites and the iPhone app's own metadata follow")
    act(f, "Rename Files…", lambda: pane().rename_many(sel() if len(sel()) > 1 else [folder_target()]), None,
        lambda: len(sel()) > 1 or folder_target() is not None,
        "The selected items — or every file in the selected folder, or this one — renamed by a pattern: 1, 2, 3… in "
        "the order they were taken, the capture date, text and a number…")
    act(f, "Duplicate", lambda: pane().duplicate_items(sel()), "Ctrl+D", lambda: any(os.path.isfile(p) for p in sel()),
        "A copy of each selected file beside it, with its tags and Favorites")
    act(f, "Remove Leading Spaces from Names…", lambda: pane().remove_leading_spaces(folder_target()), None,
        folder_target, "Every file and folder in the selected folder (or this one) whose name starts with a space "
        "gets the name without it")
    f.addSeparator()
    act(f, "Copy to the Other Side", lambda: win.transfer_selection(False), "Ctrl+Shift+C",
        lambda: not win.split or win.copy_btn.isEnabled())
    act(f, "Move to the Other Side", lambda: win.transfer_selection(True), "Ctrl+Shift+M",
        lambda: not win.split or win.move_btn.isEnabled())
    act(f, "AirDrop to iPhone…", lambda: pane().airdrop(sel()), None, lambda: bool(sel()) and sf.IS_MAC)
    act(f, "Make Book PDF…", lambda: pane().make_book(texts()), None, lambda: bool(texts()),
        "The selected .txt / .md / .rtf typeset like a printed book (bookify) — a PDF beside it")
    f.addSeparator()
    act(f, "Clone Drive to a New SSD…", lambda: sf.open_clone(pane().location if real_folder() else "", win), None, None,
        "Everything on a drive copied to a new one — each file checked, dates, tags and the apps' hidden records "
        "kept — and the two drives compared afterwards. The old drive is only read.")
    f.addSeparator()
    act(f, "Move to Trash", lambda: pane().delete_selection(), "Ctrl+Backspace", lambda: bool(sel()))
    f.addSeparator()
    act(f, "Close Window", lambda: (sf.QApplication.activeWindow() or win).close(), "Ctrl+W")
    act(f, f"Quit {app_identity.APP_NAME}", win.close, "Ctrl+Q", role=QAction.MenuRole.QuitRole)

    # -- Edit
    e = each("Edit")
    undo = act(e, "Undo", win.undo_last, "Ctrl+Z", lambda: bool(win.undo.items),
               "Takes back the last rename, tag or Favorite / To AI change")
    e.aboutToShow.connect(lambda: undo.setText(f"Undo {win.undo.title()}" if win.undo.items else "Undo"))
    e.addSeparator()
    act(e, "Copy Name", lambda: pane().copy_names(sel()), "Ctrl+Shift+Alt+C", lambda: bool(sel()),
        "The selected items' names, on the clipboard")
    act(e, "Copy Path", lambda: pane().copy_names(sel(), full=True), "Ctrl+Alt+C", lambda: bool(sel()),
        "Where the selected items are, on the clipboard — one a line")
    act(e, "Select All", lambda: pane().view().selectAll(), "Ctrl+A")
    e.addSeparator()
    act(e, "Find", lambda: (pane().search.setFocus(), pane().search.selectAll()), "Ctrl+F")
    act(e, "Find a Command…", win.open_palette, "Ctrl+Shift+P", None,
        "Every command in these menus in one list — type a few letters of what you want")
    e.addSeparator()
    act(e, "Tags…", lambda: pane().edit_tags(), "Ctrl+T", lambda: bool(sel()))

    # -- View
    v = each("View")
    modes = QActionGroup(win)
    mode_acts = {}
    for key, label, keys in (("grid", "as Icons", "Ctrl+1"), ("list", "as List", "Ctrl+2"),
                             ("photos", "as Photo Grid", "Ctrl+3")):
        a = act(v, label, lambda key=key: pane().set_mode(key), keys)
        a.setCheckable(True)
        modes.addAction(a)
        mode_acts[key] = a
    v.aboutToShow.connect(lambda: mode_acts.get(pane().mode(), mode_acts["grid"]).setChecked(True))
    tight = act(v, "Tight Icons", lambda: pane().set_tight(not (pane().mode() == "grid" and pane().tight())), None,
                tip="Icon view as a true grid: every picture fills its square, edge to edge, names underneath "
                    "(the spacing slider all the way left)")
    tight.setCheckable(True)
    v.aboutToShow.connect(lambda: tight.setChecked(pane().mode() == "grid" and pane().tight()))

    act(v, "Use This View for Every Folder", lambda: pane().use_view_everywhere(), None,
        tip="Folders remember how they were last shown; this shows them all the way this one is")
    theme = v.addMenu("Theme")
    theme_group = QActionGroup(win)
    theme_acts: list[tuple[QAction, object]] = []

    def theme_item(menu, label: str, look) -> QAction:
        a = QAction(label, win)
        a.setCheckable(True)
        a.triggered.connect(lambda _=False, look=look: sf.set_look(look))
        theme_group.addAction(a)
        menu.addAction(a)
        theme_acts.append((a, look))
        return a
    theme_item(theme, "Match macOS", None)
    theme.addSeparator()
    set_menus = []                                     # a submenu per set: forty themes are too many for one list
    for group_name, looks in sf.themes.groups():
        sub = theme.addMenu(group_name)
        set_menus.append((sub, group_name))
        for look in looks:
            theme_item(sub, look.name, look)
    mine_menu = theme.addMenu(sf.themes.MINE)
    mine_acts: list[QAction] = []
    theme.addSeparator()
    seasons = QAction("Follow the Seasons", win)
    seasons.setCheckable(True)
    seasons.setStatusTip("Through the holidays — Halloween, Thanksgiving, Christmas and the New Year — the window "
                         "wears that season's themes, a different one each day")
    seasons.setToolTip(seasons.statusTip())
    seasons.triggered.connect(lambda on: sf.set_seasonal(bool(on)))
    theme.addAction(seasons)
    surprise = QAction("Surprise Me", win)
    surprise.triggered.connect(lambda _=False: sf.set_look(sf.surprise_look()))
    theme.addAction(surprise)
    theme.addSeparator()
    custom = QAction("Choose or Customize…", win)
    custom.triggered.connect(lambda _=False: sf.open_themes(win))
    theme.addAction(custom)

    def tick_theme() -> None:
        now = sf.current_look()
        for a in mine_acts:                            # My Themes: whatever is saved now
            theme_group.removeAction(a)
            theme_acts[:] = [(x, look) for x, look in theme_acts if x is not a]
        mine_acts.clear()
        mine_menu.clear()
        for look in sf.my_themes():
            mine_acts.append(theme_item(mine_menu, look.name, look))
        mine_menu.setEnabled(bool(mine_acts))
        for a, look in theme_acts:
            a.setChecked((look is None and now is None) or (look is not None and now is not None and look.same_looks(now)))
        in_season = sf.themes.season(sf._today(), sf.december_wears())
        for sub, name in set_menus:                    # the set in season says so
            sub.setTitle(f"{name} — in season" if name in in_season else name)
        seasons.setChecked(sf.seasonal_on())
    theme.aboutToShow.connect(tick_theme)
    covers = act(v, "Folder Covers", lambda: pane().set_folder_covers(not pane().folder_covers), None,
                 tip="Folders show a picture — the cover chosen for them here or on the iPhone, else their first photo")
    covers.setCheckable(True)
    v.aboutToShow.connect(lambda: covers.setChecked(bool(pane().folder_covers)))
    v.addSeparator()
    split = act(v, "Split View", lambda: win.set_split(not win.split), "Ctrl+\\",
                tip="A second pane beside this one, with Move and Copy, for transfers")
    split.setCheckable(True)
    split.setChecked(win.split)
    v.addSeparator()
    vtop = act(v, "Videos at the Top", lambda: pane().set_videos_first(not pane().model.videos_first), None, real_folder,
               "In this folder: the videos first (after the folders), then the photos — remembered for the folder, "
               "and shown the same way on the iPhone")
    vtop.setCheckable(True)
    v.aboutToShow.connect(lambda: vtop.setChecked(bool(pane().model.videos_first)))
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
    order_group = QActionGroup(win)                    # the same two as the header's Sort button
    order_acts = {}
    for label, order in (("Ascending", sf.Qt.SortOrder.AscendingOrder), ("Descending", sf.Qt.SortOrder.DescendingOrder)):
        a = QAction(label, win)
        a.setCheckable(True)
        a.triggered.connect(lambda _=False, order=order: pane().set_sort(pane().current_sort()[0], order))
        order_group.addAction(a)
        sort.addAction(a)
        order_acts[order] = a
    sort.addSeparator()
    sizes = QAction("Calculate Folder Sizes", win)
    sizes.setCheckable(True)
    sizes.setToolTip("Add up what each folder holds (in the background) — shown in the Size column, used by the "
                     "size sort and the size filter")
    sizes.triggered.connect(lambda on: pane().set_show_sizes(bool(on)))
    sort.addAction(sizes)

    def tick_sort() -> None:
        key, order = pane().current_sort()
        sort_acts.get(key, sort_acts["name"]).setChecked(True)
        order_acts[order].setChecked(True)
        sizes.setChecked(bool(pane().model.show_sizes))
    sort.aboutToShow.connect(tick_sort)
    hidden = act(v, "Show Hidden Files", lambda: win.set_show_hidden(not win.show_hidden), "Ctrl+Shift+.", None,
                 "Files and folders whose names start with a dot — the apps' own records on the drive among them")
    hidden.setCheckable(True)
    v.aboutToShow.connect(lambda: hidden.setChecked(bool(win.show_hidden)))
    act(v, "Refresh", lambda: pane().refresh(), "Ctrl+R", None, "Reads this folder — or runs this search — again")
    v.addSeparator()
    act(v, "Bigger Thumbnails", lambda: pane().slider.setValue(min(320, pane().slider.value() + 24)), "Ctrl+=")
    act(v, "Smaller Thumbnails", lambda: pane().slider.setValue(max(48, pane().slider.value() - 24)), "Ctrl+-")

    # -- Go
    g = each("Go")
    act(g, "Back", lambda: pane().go_back(), "Ctrl+[")
    act(g, "Forward", lambda: pane().go_forward(), "Ctrl+]")
    act(g, "Enclosing Folder", lambda: pane().go_up(), "Ctrl+Up", real_folder)
    act(g, "Go to Folder…", lambda: pane().go_to_folder(), "Ctrl+Shift+G", None,
        "Type or paste a path — ~/Pictures, /Volumes/…")
    g.addSeparator()
    home = Path.home()
    act(g, "Home", lambda: pane().go(str(home)), "Ctrl+Shift+H")
    act(g, "Desktop", lambda: pane().go(str(home / "Desktop")), "Ctrl+Shift+D")
    act(g, "Downloads", lambda: pane().go(str(home / "Downloads")), "Ctrl+Alt+L")
    act(g, "Pictures", lambda: pane().go(str(home / "Pictures")))
    act(g, "Places…", lambda: pane().open_places(), "Ctrl+Shift+L", None,
        "Where your photos and videos were taken: a list by country and town, and a map")
    act(g, "People…", lambda: pane().open_people(), "Ctrl+Shift+E", None,
        "The people in your photos, grouped by face on this Mac and named by you")
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
    fav = act(t, "Favorite", lambda: pane().toggle_label("favorite"), "Ctrl+Shift+F", lambda: bool(sel()),
              "Favorite the selection (or unfavorite it, when it all is) — the iPhone app's Favorites")
    to_ai = act(t, "To AI", lambda: pane().toggle_label("ai"), "Ctrl+Shift+A", lambda: bool(sel()),
                "Mark the selection To AI (or take it off) — the iPhone app's To AI")

    def label_titles() -> None:
        """Favorite / Unfavorite and To AI / Remove To AI, as the right-click menu says them."""
        s, store = sel(), sf.tag_store()
        try:
            every = lambda label: bool(s) and all(label in store.labels(p, fresh=False) for p in s)   # noqa: E731
            fav.setText("Unfavorite" if every("favorite") else "Favorite")
            to_ai.setText("Remove To AI" if every("ai") else "To AI")
        except Exception:  # noqa: BLE001 — the titles are a nicety
            pass
    t.aboutToShow.connect(label_titles)
    t.addSeparator()

    def dup_target():
        """Several folders selected: all of them, looked at as one; else the folder selected or shown."""
        s = sel()
        if len(s) > 1 and all(os.path.isdir(p) for p in s):
            return s
        return folder_target()
    act(t, "Find People…", lambda: pane().open_people(folder_target()), None, folder_target,
        "Finds the faces in the photos of the selected folder (or this one) and groups them into people — on this "
        "Mac; you give the names")
    act(t, "Find Duplicates…", lambda: pane().find_duplicates(dup_target()), None, dup_target,
        "Likely copies in the selected folder or folders (or this one)")
    t.addSeparator()

    adjust = submenu(t, "Adjust")
    act(adjust, "Crop…", lambda: pane().crop_photos(photos()), None, lambda: bool(photos()),
        "One crop, drawn once, on every selected photo")
    for label, quarters in (("Rotate Left", 3), ("Rotate Right", 1), ("Rotate 180°", 2)):
        act(adjust, label, lambda quarters=quarters: pane().rotate_items(sel(), quarters), None,
            lambda: bool(photos() or videos()), "The selected photos and videos turned in place")
    adjust.addSeparator()
    act(adjust, "Convert WebP to JPEG…", lambda: pane().convert_webp(webp_targets()), None, lambda: bool(webp_targets()),
        "Every WebP selected (or in the selected folder, or this one) as a full-resolution, quality-95 JPEG")

    retouch = submenu(t, "Retouch")
    act(retouch, "AI Upscale 2×…", lambda: pane().ai_upscale(photos()), None, lambda: bool(photos()),
        "The selected photos at twice the size, with Real-ESRGAN on this Mac")
    act(retouch, "Erase Area…", lambda: pane().erase_area(photos()), None, lambda: bool(photos()),
        "Boxes drawn over a stamp or mark on one photo, erased from every selected one")
    act(retouch, "Remove Watermark…", lambda: pane().remove_watermark(watermarkable()), None,
        lambda: bool(watermarkable()),
        "Your own see-through watermark, learned once and taken out of every selected photo (or every photo inside "
        "the selected folders)")
    act(retouch, "Remove Objects…", lambda: pane().remove_objects(photos()[0]) if len(photos()) == 1 else None, None,
        lambda: len(photos()) == 1, "Draw round anything in the photo and it's gone — filled in from the photo itself")

    video = submenu(t, "Video")
    act(video, "Export All Frames…", lambda: pane().export_frames(videos()), None, lambda: bool(videos()),
        "Every frame of the selected videos as pictures, in a folder beside them")
    act(video, "Upscale Video…", lambda: pane().upscale_videos(videos()), None, lambda: bool(videos()),
        "The selected videos upscaled to 1080p or 4K — replaced, or saved as new videos beside them")

    cc = submenu(t, "CapCut")
    act(cc, "Send to CapCut", lambda: pane().send_to_capcut(sendable()), "Ctrl+Shift+K", lambda: bool(sendable()),
        "Opens CapCut with the selected clips (or this folder's) beside it, in order, to drag in — and brings "
        "CapCut's exports back")
    act(cc, "Import from CapCut…", lambda: pane().import_from_capcut(folder_target()), None, None,
        "CapCut's finished videos, onto the drive — into this folder, or back where their clips came from")

    ai = submenu(t, "AI")
    act(ai, "Edit with AI…", lambda: pane().ai_edit(photos()), None, lambda: bool(photos()),
        "The selected photo — or every selected photo, with the same prompt, the results back together")
    act(ai, "Create with AI…", lambda: pane().ai_create(folder_target()), None, folder_target,
        "A new picture from a prompt, saved into this folder's “AI” folder")
    act(ai, "Astria.ai Browser…", lambda: pane().astria_browser(folder_target() or str(home / "Pictures")), None, None,
        "Everything made on Astria: browse, search, download")
    ai.addSeparator()
    act(ai, "Make AI Model…", lambda: pane().make_ai_model(
        photos() if len(photos()) >= 5 else ([folder_target()] if folder_target() else photos())),
        None, lambda: len(photos()) >= 5 or bool(folder_target()),
        "A person, pet, object or style from 5–500 photos: the best varied ones are kept, and pictures of it can be "
        "made on this Mac or with Seedream and Nano Banana")
    act(ai, "AI Models…", lambda: pane().open_ai_models(), None, None, "The models made so far, and pictures from them")

    dl = submenu(t, "Download")
    act(dl, "Download from SimpCity…", lambda: sf.open_simpcity(folder_target(), win), None, folder_target)
    act(dl, "Get Reaction Scores", lambda: sf.open_simpcity(sf.simpcity_scores_folder(folder_target()), win,
                                                            scores_only=True), None,
        lambda: folder_target() is not None and sf.simpcity_scores_folder(folder_target()) is not None)
    act(dl, "Download Instagram Profile…", lambda: sf.open_social("instagram", folder_target(), win), None,
        folder_target)
    act(dl, "Download Facebook Profile…", lambda: sf.open_social("facebook", folder_target(), win), None,
        folder_target)
    act(dl, "Download TikTok Profile…", lambda: sf.open_tiktok(folder_target(), win), None, folder_target,
        "A TikTok profile's videos, watermark-free, into its @handle folder (the iPhone app's) — with every "
        "video's like count read again")
    act(dl, "Download from Fanfix…", lambda: sf.open_fanfix(folder_target(), win), None, folder_target,
        "Your purchased content from Fanfix creators, into a folder for each creator")
    act(dl, sf.passes_label(folder_target()) if folder_target() else "Download Passes…",
        lambda: sf.open_passes(folder_target(), win), None, folder_target)
    dl.addSeparator()
    act(dl, "Browse taylorpictures.net…", lambda: pane().open_taylor(
        folder_target() or str(win.settings.value("taylor/root") or "")), None,
        lambda: folder_target() is not None or bool(win.settings.value("taylor/root")))

    # -- Window
    w = each("Window")
    act(w, "Minimize", win.showMinimized, "Ctrl+M")
    act(w, "Zoom", lambda: win.showNormal() if win.isMaximized() else win.showMaximized())
    w.addSeparator()
    act(w, "Bring All to Front", sf.raise_all_windows, None, None,
        "Every Photo Browser for Mac window in front of other apps' windows — what a click on the Dock icon does")
    w.addSeparator()
    act(w, "Photo Browser for Mac", lambda: (win.showNormal() if win.isMinimized() else None, win.raise_(),
                                   win.activateWindow()))
    others = []

    def fill_windows() -> None:
        """Every other window that's open — viewers, Edit with AI, downloaders, minimized ones too."""
        for a in others:
            w.removeAction(a)
        others.clear()
        seen = [win]
        for x in list(sf._VIEWERS) + list(sf.QApplication.topLevelWidgets()):
            try:
                if x in seen or not x.isWindow() or not (x.isVisible() or x.isMinimized()):
                    continue
                if x.windowType() in (sf.Qt.WindowType.Popup, sf.Qt.WindowType.ToolTip, sf.Qt.WindowType.SplashScreen):
                    continue
                title = x.windowTitle()
            except RuntimeError:
                continue
            seen.append(x)
            if not title:
                continue
            a = QAction(title, win)
            a.triggered.connect(lambda _=False, x=x: (x.showNormal(), x.raise_(), x.activateWindow()))
            w.addAction(a)
            others.append(a)
    w.aboutToShow.connect(fill_windows)

    # -- Help
    h = each("Help")
    act(h, f"{app_identity.APP_NAME} Help", lambda: win.open_help(0), "Ctrl+?", None,
        "The guide to everything the app does, with a search field")
    act(h, "Keyboard Shortcuts", lambda: win.open_help(1), None, None, "Every command that has a key")
    act(h, "Find a Command…", win.open_palette, None, None, "⇧⌘P — type a few letters of what you want")
    h.addSeparator()
    act(h, "Welcome…", lambda: win.show_welcome(), None, None, "The few lines shown on the first launch")
    act(h, f"About {app_identity.APP_NAME}", win.about, None, None, "", QAction.MenuRole.AboutRole)
    win.menu_actions = {a.text(): a for a in acts}
