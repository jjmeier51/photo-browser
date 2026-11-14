import Foundation

/// Folder covers shared with Safe Finder — a cover chosen on the Mac is the folder's cover here,
/// and the other way round.
///
/// Here a cover is an image in the app's own `folderCovers` directory, named in
/// `Library.folderCovers` (folder path → file name). For the drive that's open, the same choice
/// is also kept **on the drive**: the image in `<drive>/.Photo Browser Metadata/covers/<name>`
/// (the folder the metadata backup already copies covers into — names are random, so nothing
/// collides) and the choice in `<drive>/.Photo Browser Metadata/folder-covers.json`:
///
///     {"format": "photobrowser-folder-covers", "version": 1,
///      "covers": {"<folder, drive-relative>": {"file": "<name in covers/>", "at": stamp}}}
///
/// Safe Finder reads and writes the same file (`mac/folder_covers.py`).
///
/// `at` is when the cover was chosen (Unix time); **the later choice wins**. Two special values:
/// `"file": ""` means the cover was *removed* then (so the other side doesn't put its older one
/// back), and `"at": 0` marks a cover nobody chose — the random photo `ensureRandomCover` gives
/// every folder — which any chosen cover replaces. `Library.coverStamps` holds the `at` of the
/// covers chosen here; a folder without a stamp has an automatic one.
///
/// `Library.syncFolderCovers` does one merge, off the main actor, with the tag sync (drive opened
/// or back, foreground, a moment after a cover is chosen). It copies only the images the other
/// side lacks, and at most `autoCopiesPerSync` automatic covers a time — a library has thousands,
/// and the drive may be slow. A cover that can't be copied simply isn't offered yet.
nonisolated enum FolderCovers {
    static let fileName = "folder-covers.json"
    static let format = "photobrowser-folder-covers"
    static let stampsKey = "photoBrowser.coverStamps"
    static let autoCopiesPerSync = 250

    nonisolated struct Choice: Equatable, Sendable {
        var file: String        // "" = removed
        var at: Double          // 0 = picked automatically
    }

    static func file(root: URL) -> URL {
        MetadataBackup.driveBackupDirectory(root: root).appendingPathComponent(fileName)
    }

    static func coversDirectory(root: URL) -> URL {
        MetadataBackup.driveBackupDirectory(root: root)
            .appendingPathComponent(MetadataBackup.coversSubfolder, isDirectory: true)
    }

    /// A file name that can only be a name — never a path out of the covers folder.
    static func safeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 120, !name.hasPrefix(".") else { return false }
        return name.unicodeScalars.allSatisfy {
            ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_")
        }
    }

    /// What the drive's file says: folder (drive-relative, "" = the drive itself) → choice.
    static func read(root: URL) -> [String: Choice] {
        guard let data = try? Data(contentsOf: file(root: root)),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              doc["format"] as? String == format,
              let raw = doc["covers"] as? [String: Any] else { return [:] }
        var out: [String: Choice] = [:]
        for (folder, value) in raw {
            guard let entry = value as? [String: Any], let name = entry["file"] as? String,
                  let at = entry["at"] as? NSNumber, name.isEmpty || safeName(name) else { continue }
            out[folder] = Choice(file: name, at: at.doubleValue)
        }
        return out
    }

    /// Best-effort: a drive that's gone or read-only just keeps the file it had.
    static func write(_ entries: [String: Choice], root: URL) {
        var covers: [String: Any] = [:]
        for (folder, choice) in entries { covers[folder] = ["file": choice.file, "at": choice.at] }
        let doc: [String: Any] = ["format": format, "version": 1, "by": "Photo Browser",
                                  "updated": Date().timeIntervalSince1970, "covers": covers]
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]) else { return }
        let dest = file(root: root)
        let dir = dest.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) { try? DriveWriter.createDirectory(at: dir) }
        try? DriveWriter.writeDataSync(data, to: dest)
    }

    /// What one merge decided.
    nonisolated struct Outcome: Sendable {
        /// Folder (drive-relative) → the choice to take up here: a cover whose image is now in the
        /// app's covers directory, or a removal.
        var adopt: [String: Choice] = [:]
    }

    /// Merges `mine` (this phone's covers for the drive) with the drive's file: copies the images
    /// each side lacks, writes the file when it gained anything, and says what to take up here.
    static func merge(mine: [String: Choice], root: URL, appCovers: URL) -> Outcome {
        let fm = FileManager.default
        let theirs = read(root: root)
        let driveCovers = coversDirectory(root: root)
        var out = theirs
        var outcome = Outcome()
        var autoCopies = 0
        var madeDirectory = fm.fileExists(atPath: driveCovers.path)

        func onDrive(_ name: String) -> Bool { fm.fileExists(atPath: driveCovers.appendingPathComponent(name).path) }

        for (folder, my) in mine {
            if let their = theirs[folder], their.at > my.at || their == my { continue }     // theirs stands
            // Mine is the later (or only) choice: it goes to the drive, image first.
            if !onDrive(my.file) {
                if my.at == 0 {
                    guard autoCopies < autoCopiesPerSync else { continue }      // the rest next time
                    autoCopies += 1
                }
                if !madeDirectory {
                    try? DriveWriter.createDirectory(at: driveCovers)
                    madeDirectory = true
                }
                guard (try? DriveWriter.copyItem(at: appCovers.appendingPathComponent(my.file),
                                                 to: driveCovers.appendingPathComponent(my.file))) != nil else { continue }
            }
            out[folder] = my
        }
        for (folder, their) in theirs {
            if let my = mine[folder], my.at >= their.at { continue }
            // Theirs is the later (or only) choice.
            let folderURL = folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                out[folder] = nil                       // a folder that's gone (renamed, deleted): forgotten
                continue
            }
            if their.file.isEmpty {
                outcome.adopt[folder] = their
                continue
            }
            let local = appCovers.appendingPathComponent(their.file)
            if !fm.fileExists(atPath: local.path) {
                guard (try? fm.copyItem(at: driveCovers.appendingPathComponent(their.file), to: local)) != nil else { continue }
            }
            outcome.adopt[folder] = their
        }
        if out != theirs { write(out, root: root) }
        return outcome
    }
}

extension Library {
    /// Notes that `folder`'s cover was just chosen (rather than picked automatically), so it wins
    /// over an older choice made in Safe Finder — and goes to the drive shortly.
    func noteCoverChosen(for folder: URL) {
        coverStamps[folder.path] = Date().timeIntervalSince1970
        FilePrefs.shared.set(coverStamps, forKey: FolderCovers.stampsKey)
        scheduleTagSync(after: 1)          // `syncDriveTags` runs `syncFolderCovers`
    }

    /// One merge with the drive's `folder-covers.json`: covers chosen in Safe Finder come in,
    /// covers set here go out.
    func syncFolderCovers() async {
        guard let root = rootURL, !waitingForDrive, !pureTransferMode else { return }
        let rootPath = root.path
        let canonicalRoot = Self.canonicalPath(rootPath)
        var mine: [String: FolderCovers.Choice] = [:]       // drive-relative folder (NFC) → choice
        var stored: [String: String] = [:]                  // drive-relative folder → the key it's kept under here
        for (path, name) in folderCovers {
            let canonical = Self.canonicalPath(path)
            let rel: String
            if canonical == canonicalRoot {
                rel = ""
            } else if canonical.hasPrefix(canonicalRoot + "/") {
                rel = String(canonical.dropFirst(canonicalRoot.count + 1)).precomposedStringWithCanonicalMapping
            } else {
                continue                                    // another drive's folder
            }
            guard FolderCovers.safeName(name) else { continue }
            mine[rel] = FolderCovers.Choice(file: name, at: coverStamps[path] ?? 0)
            stored[rel] = path
        }
        let appCovers = coverImagesDirectory
        let snapshot = mine
        let outcome = await Task.detached(priority: .utility) {
            FolderCovers.merge(mine: snapshot, root: root, appCovers: appCovers)
        }.value
        guard rootURL?.path == rootPath, !outcome.adopt.isEmpty else { return }     // another drive was opened meanwhile
        var covers = folderCovers
        var stamps = coverStamps
        var dropped: [String] = []
        for (rel, choice) in outcome.adopt {
            let key = stored[rel] ?? (rel.isEmpty ? rootPath : rootPath + "/" + rel)
            let had = covers[key]
            if choice.file.isEmpty {
                // Removed in Safe Finder. Only a cover *chosen* here goes; an automatic one is what
                // "no cover" looks like in this app, and stays.
                guard let had, (stamps[key] ?? 0) > 0 else { continue }
                covers[key] = nil
                stamps[key] = nil
                dropped.append(had)
            } else if had != choice.file {
                covers[key] = choice.file
                stamps[key] = choice.at > 0 ? choice.at : nil
                if let had { dropped.append(had) }
            } else if choice.at > 0, stamps[key] != choice.at {
                stamps[key] = choice.at
            }
        }
        if covers != folderCovers {
            folderCovers = covers
            FilePrefs.shared.set(folderCovers, forKey: "photoBrowser.folderCovers")
        }
        if stamps != coverStamps {
            coverStamps = stamps
            FilePrefs.shared.set(coverStamps, forKey: FolderCovers.stampsKey)
        }
        // The images no folder shows any more (another folder may share one — Instagram's person
        // and @handle folders do).
        let inUse = Set(folderCovers.values)
        let gone = dropped.filter { !inUse.contains($0) }
        if !gone.isEmpty {
            Task.detached(priority: .utility) {
                for name in gone { try? FileManager.default.removeItem(at: appCovers.appendingPathComponent(name)) }
            }
        }
    }
}
