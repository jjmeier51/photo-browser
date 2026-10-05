import XCTest
import CoreImage
@testable import PhotoBrowser

/// Video editor Phase 1 (NFR-10): document round-trips with unknown keys preserved, every command's
/// undo/redo inverse, time mapping, path resolution, name sanitising, and the sandbox audit — the
/// drive layout never produces a path outside the drive root.
final class VideoEditorTests: XCTestCase {

    private func tempDrive() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ve-drive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sampleProject() -> VEProject {
        var p = VEProject(name: "Test")
        let v = VEMediaSource(id: "m1", kind: .video, path: "drive://Trips/clip.mov",
                              identity: VEIdentity(size: 10, mtime: Date(timeIntervalSince1970: 0), hash: "sha256:x"),
                              duration: 10_000_000, width: 1920, height: 1080, originalName: "clip.mov")
        let i = VEMediaSource(id: "m2", kind: .image, path: "media/photo.jpg",
                              identity: VEIdentity(size: 20, mtime: Date(timeIntervalSince1970: 0), hash: "sha256:y"),
                              duration: 0, width: 3000, height: 2000, originalName: "photo.jpg")
        p.media = [v, i]
        p.tracks.main = [VEClip(id: "c1", mediaId: "m1", kind: .video, sourceRange: VERange(start: 0, duration: 10_000_000)),
                         VEClip(id: "c2", mediaId: "m2", kind: .image, sourceRange: VERange(start: 0, duration: 3_000_000))]
        p.refreshCanvas()
        return p
    }

    // MARK: Document

    func testRoundTripPreservesUnknownKeys() throws {
        let json = """
        {"schemaVersion":1,"id":"7D0E4F0C-7E0B-4E7B-9E9C-7D0E4F0C7E0B","name":"X","createdAt":"2026-01-01T00:00:00Z","modifiedAt":"2026-01-01T00:00:00Z",
         "settings":{"frameRate":25},"media":[],"tracks":{"main":[{"id":"a","mediaId":"m","sourceRange":{"start":0,"duration":1000000},"futureField":{"k":[1,2]}}]},
         "transitions":[],"beats":{},"somethingNew":"keep me"}
        """
        let p = try VEJSON.decoder.decode(VEProject.self, from: Data(json.utf8))
        XCTAssertEqual(p.settings.frameRate, 25)
        XCTAssertEqual(p.settings.resolution, .p1080)        // defaulted
        XCTAssertEqual(p.extra["somethingNew"], .string("keep me"))
        XCTAssertEqual(p.tracks.main[0].extra["futureField"], .object(["k": .array([.number(1), .number(2)])]))
        let out = try VEJSON.encoder.encode(p)
        let back = try VEJSON.decoder.decode(VEProject.self, from: out)
        XCTAssertEqual(back, p)
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("somethingNew"))
    }

    func testDeterministicEncoding() throws {
        let p = sampleProject()
        XCTAssertEqual(try VEJSON.encoder.encode(p), try VEJSON.encoder.encode(p))
    }

    // MARK: Time mapping

    func testTimelineDurationWithSpeed() {
        var c = VEClip(mediaId: "m", kind: .video, sourceRange: VERange(start: 0, duration: 10_000_000))
        c.speed.rate = 2
        XCTAssertEqual(c.timelineDuration, 5_000_000)
        XCTAssertEqual(c.sourceTime(atOffset: 1_000_000), 2_000_000)
        c.speed.rate = 0.5
        XCTAssertEqual(c.timelineDuration, 20_000_000)
        var still = VEClip(mediaId: "m", kind: .image, sourceRange: VERange(start: 0, duration: 3_000_000))
        still.speed.rate = 4   // ignored for stills
        XCTAssertEqual(still.timelineDuration, 3_000_000)
    }

    func testMainStartsAndTransitions() {
        var p = sampleProject()
        XCTAssertEqual(p.mainStarts(), [0, 10_000_000])
        XCTAssertEqual(p.duration, 13_000_000)
        p.transitions = [VETransition(afterMainClip: "c1", id: "basic.dissolve", duration: 500_000)]
        XCTAssertEqual(p.mainStarts(), [0, 9_500_000])
        XCTAssertEqual(p.duration, 12_500_000)
        XCTAssertEqual(p.mainClip(at: 9_700_000)?.clip.id, "c1")    // earlier clip wins in the overlap
        XCTAssertEqual(p.mainCuts(), [0, 9_500_000, 12_500_000])
    }

    func testFrameSnappingAndFormatting() {
        XCTAssertEqual(VETimeUtil.frame(30), 33_333)
        XCTAssertEqual(VETimeUtil.snapToFrame(50_000, fps: 30), 66_666)   // 50 ms → nearest frame boundary (2 frames)
        XCTAssertEqual(VETimeUtil.format(65_300_000, fps: 30), "1:05.3")
        XCTAssertEqual(VETimeUtil.format(65_500_000, fps: 30, frames: true), "1:05:15")
    }

    // MARK: Filters, HDR, export dates

    func testFilterRoundTripAndDefaults() throws {
        var p = sampleProject()
        p.tracks.main[0].filter = VEFilter(id: "vivid", intensity: 0.4)
        let data = try VEJSON.encoder.encode(p)
        let back = try VEJSON.decoder.decode(VEProject.self, from: data)
        XCTAssertEqual(back.tracks.main[0].filter, VEFilter(id: "vivid", intensity: 0.4))
        XCTAssertNil(back.tracks.main[1].filter)
        // A filter written without an intensity is the full look; "none" and 0 are inactive.
        let lenient = try VEJSON.decoder.decode(VEFilter.self, from: Data(#"{"id":"mono"}"#.utf8))
        XCTAssertEqual(lenient.intensity, 1)
        XCTAssertTrue(lenient.isActive)
        XCTAssertFalse(VEFilter(id: "none").isActive)
        XCTAssertFalse(VEFilter(id: "mono", intensity: 0).isActive)
        XCTAssertNotNil(VEFilterCatalog.def("vivid"))
        XCTAssertEqual(Set(VEFilterCatalog.all.map(\.id)).count, VEFilterCatalog.all.count)   // ids unique
    }

    func testHDRResolvesFromMediaAndMode() {
        var p = sampleProject()
        XCTAssertFalse(p.hasHDRMedia)
        p.refreshHDR()
        XCTAssertFalse(p.settings.hdr)
        p.media[0].colorTransfer = "HLG"
        XCTAssertTrue(p.media[0].isHDR)
        p.refreshHDR()
        XCTAssertTrue(p.settings.hdr, "Auto follows the media")
        p.settings.hdrMode = .off
        p.refreshHDR()
        XCTAssertFalse(p.settings.hdr)
        p.settings.hdrMode = .on
        p.media[0].colorTransfer = "SDR"
        p.refreshHDR()
        XCTAssertTrue(p.settings.hdr, "On forces HDR without HDR media")
        // Only media on the timeline counts.
        p.settings.hdrMode = .auto
        p.media.append(VEMediaSource(id: "m3", kind: .video, path: "media/unused.mov", identity: p.media[0].identity,
                                     duration: 1_000_000, width: 1920, height: 1080, originalName: "unused.mov"))
        p.media[2].colorTransfer = "PQ"
        p.refreshHDR()
        XCTAssertFalse(p.settings.hdr)
    }

    func testOldestCaptureDateAcrossUsedMedia() {
        var p = sampleProject()
        XCTAssertNil(p.oldestCaptureDate)
        p.media[0].createdAt = Date(timeIntervalSince1970: 2_000)
        p.media[1].createdAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(p.oldestCaptureDate, Date(timeIntervalSince1970: 1_000))
        p.media.append(VEMediaSource(id: "m3", kind: .video, path: "media/unused.mov", identity: p.media[0].identity,
                                     duration: 1_000_000, width: 1920, height: 1080, originalName: "unused.mov"))
        p.media[2].createdAt = Date(timeIntervalSince1970: 10)
        XCTAssertEqual(p.oldestCaptureDate, Date(timeIntervalSince1970: 1_000), "media not on the timeline doesn't vote")
    }

    func testRotationFromPreferredTransform() {
        // A portrait phone clip: 90° clockwise on screen.
        XCTAssertEqual(VEMediaService.rotation(from: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)), .rotate90)
        XCTAssertEqual(VEMediaService.rotation(from: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920)), .rotate270)
        XCTAssertEqual(VEMediaService.rotation(from: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)), .rotate180)
        XCTAssertEqual(VEMediaService.rotation(from: .identity), .none)
        // The oriented size swaps for 90/270 and the compositor's orient() produces that extent.
        var s = VEMediaSource(id: "m", kind: .video, path: "drive://a.mov", identity: VEIdentity(size: 1, mtime: Date(), hash: ""),
                              duration: 1, width: 1920, height: 1080, originalName: "a.mov")
        s.transform = .rotate90
        XCTAssertEqual(s.displaySize, VESize(width: 1080, height: 1920))
        let frame = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let oriented = VELayerMath.orient(frame, rotation: .rotate90)
        XCTAssertEqual(oriented.extent, CGRect(x: 0, y: 0, width: 1080, height: 1920))
    }

    // MARK: Canvas

    func testCanvasSizes() {
        XCTAssertEqual(VECanvas.make(ratio: .r9x16, resolution: .p1080, originalAspect: nil).size, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(VECanvas.make(ratio: .r16x9, resolution: .p1080, originalAspect: nil).size, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(VECanvas.make(ratio: .r1x1, resolution: .p720, originalAspect: nil).size, CGSize(width: 720, height: 720))
        XCTAssertEqual(VECanvas.make(ratio: .r4x3, resolution: .p1080, originalAspect: nil).size, CGSize(width: 1440, height: 1080))
        let wide = VECanvas.make(ratio: .r235x1, resolution: .p1080, originalAspect: nil)
        XCTAssertEqual(wide.height, 1080)
        XCTAssertEqual(wide.width % 2, 0)
        XCTAssertEqual(wide.width, 2538)
        let orig = VECanvas.make(ratio: .original, resolution: .p2160, originalAspect: 3.0 / 2.0)
        XCTAssertEqual(orig.size, CGSize(width: 3240, height: 2160))
    }

    func testLayerPlacementFitsCanvas() {
        // An untouched 16:9 clip on a 9:16 canvas is fitted to the canvas width and centred.
        let corners = VELayerMath.corners(sourceSize: CGSize(width: 1920, height: 1080), crop: VECrop(), canvasSize: CGSize(width: 1080, height: 1920), transform: VETransform())
        let xs = corners.map(\.x), ys = corners.map(\.y)
        XCTAssertEqual(xs.min()!, 0, accuracy: 0.5)
        XCTAssertEqual(xs.max()!, 1080, accuracy: 0.5)
        XCTAssertEqual((ys.min()! + ys.max()!) / 2, 960, accuracy: 0.5)
        XCTAssertEqual(ys.max()! - ys.min()!, 607.5, accuracy: 0.5)
    }

    // MARK: Names and paths

    func testSanitizeAndUnique() throws {
        XCTAssertEqual(VENames.sanitize(" My: Trip/2026? "), "My- Trip-2026-")
        XCTAssertEqual(VENames.sanitize("   "), "Project")
        let dir = try tempDrive()
        FileManager.default.createFile(atPath: dir.appendingPathComponent("Trip.vep").path, contents: nil)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("trip (2).vep").path, contents: nil)   // case-insensitive collision
        XCTAssertEqual(VENames.unique("Trip", ext: "vep", in: dir), "Trip (3).vep")
    }

    func testPathResolution() throws {
        let drive = try tempDrive()
        let store = VEDriveStore(driveRoot: drive)
        let pkg = VEDriveLayout.projects(store.editorRoot).appendingPathComponent("P.vep", isDirectory: true)
        XCTAssertEqual(store.resolve("drive://Trips/a.mov", package: pkg).path, drive.appendingPathComponent("Trips/a.mov").path)
        XCTAssertEqual(store.resolve("media/b.mov", package: pkg).path, pkg.appendingPathComponent("media/b.mov").path)
        XCTAssertEqual(store.resolve("Library/LUTs/x.cube", package: pkg).path, store.editorRoot.appendingPathComponent("Library/LUTs/x.cube").path)
        XCTAssertEqual(store.reference(for: drive.appendingPathComponent("Trips/a.mov"), package: pkg), "drive://Trips/a.mov")
        XCTAssertEqual(store.reference(for: pkg.appendingPathComponent("media/b.mov"), package: pkg), "media/b.mov")
        XCTAssertEqual(store.reference(for: VEDriveLayout.library(store.editorRoot, "Music").appendingPathComponent("s.mp3"), package: pkg), "Library/Music/s.mp3")
        XCTAssertNil(store.reference(for: URL(fileURLWithPath: "/tmp/elsewhere.mov"), package: pkg))
    }

    /// STO-3 sandbox audit: every layout path is under the drive root, and a document save lands
    /// in the package with a `.bak` of the previous version.
    func testLayoutStaysOnDriveAndAtomicSave() throws {
        let drive = try tempDrive()
        let store = VEDriveStore(driveRoot: drive)
        try store.ensureLayout()
        let pkg = VEDriveLayout.projects(store.editorRoot).appendingPathComponent("P.vep", isDirectory: true)
        try store.ensurePackageLayout(pkg)
        let all = [store.editorRoot, VEDriveLayout.settingsFile(store.editorRoot), VEDriveLayout.logs(store.editorRoot), VEDriveLayout.projects(store.editorRoot),
                   VEDriveLayout.exports(store.editorRoot), VEDriveLayout.library(store.editorRoot), VEDriveLayout.document(pkg), VEDriveLayout.documentBackup(pkg),
                   VEDriveLayout.lock(pkg), VEDriveLayout.cover(pkg)] + VEDriveLayout.packageFolders(pkg)
        for u in all { XCTAssertTrue(store.isUnderDrive(u), u.path) }
        let doc = VEDriveLayout.document(pkg)
        try store.saveDocument(Data("v1".utf8), to: doc, backupName: "project.json.bak")
        try store.saveDocument(Data("v2".utf8), to: doc, backupName: "project.json.bak")
        XCTAssertEqual(try String(contentsOf: doc), "v2")
        XCTAssertEqual(try String(contentsOf: VEDriveLayout.documentBackup(pkg)), "v1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pkg.appendingPathComponent("project.json.tmp").path))
    }

    // MARK: Undo / redo

    @MainActor
    func testUndoRedoRoundTrip() async throws {
        let drive = try tempDrive()
        let store = VEDriveStore(driveRoot: drive)
        try store.ensureLayout()
        let doc = try await VEDocument.create(name: "Undo", settings: VEProjectSettings(), store: store)
        let sample = sampleProject()
        doc.perform("Seed") { $0.media = sample.media; $0.tracks = sample.tracks }
        let seeded = doc.project.editableState
        // Split c1 at 4 s.
        doc.perform("Split") { p in
            var left = p.tracks.main[0]; var right = left; right.id = "c1b"
            left.sourceRange.duration = 4_000_000; right.sourceRange.start = 4_000_000; right.sourceRange.duration = 6_000_000
            p.tracks.main[0] = left; p.tracks.main.insert(right, at: 1)
        }
        XCTAssertEqual(doc.project.tracks.main.count, 3)
        XCTAssertEqual(doc.project.duration, 13_000_000)
        doc.perform("Delete") { $0.tracks.main.remove(at: 1) }
        XCTAssertEqual(doc.project.duration, 7_000_000)
        doc.undo()
        XCTAssertEqual(doc.project.tracks.main.count, 3)
        doc.undo()
        XCTAssertEqual(doc.project.editableState, seeded)
        doc.redo(); doc.redo()
        XCTAssertEqual(doc.project.duration, 7_000_000)
        // A no-op edit pushes nothing.
        doc.perform("Nothing") { _ in }
        XCTAssertTrue(doc.canUndo)
        doc.undo(); doc.undo(); doc.undo()
        XCTAssertFalse(doc.canUndo)
        // Transactions coalesce.
        doc.beginTransaction("Slide")
        for v in stride(from: 0.1, through: 1.0, by: 0.1) { doc.updateTransaction { $0.tracks.main[0].opacity = v } }
        doc.commitTransaction()
        XCTAssertEqual(doc.undoStack.undoList.count, 1)
        doc.beginTransaction("Cancelled")
        doc.updateTransaction { $0.tracks.main[0].opacity = 0.2 }
        doc.cancelTransaction()
        XCTAssertEqual(doc.project.tracks.main[0].opacity, 1.0, accuracy: 0.0001)
        await doc.saveNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: VEDriveLayout.document(doc.packageURL).path))
        await doc.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: VEDriveLayout.lock(doc.packageURL).path))
    }

    @MainActor
    func testRecoveryFromBackup() async throws {
        let drive = try tempDrive()
        let store = VEDriveStore(driveRoot: drive)
        try store.ensureLayout()
        let doc = try await VEDocument.create(name: "Recover", settings: VEProjectSettings(), store: store)
        doc.perform("Rename") { $0.name = "Good" }
        await doc.saveNow()
        doc.perform("Rename") { $0.name = "Also good" }
        await doc.saveNow()
        await doc.close()
        // Corrupt the live document; the backup is the previous good save.
        try Data("{not json".utf8).write(to: VEDriveLayout.document(doc.packageURL))
        let reopened = try await VEDocument.open(packageURL: doc.packageURL, store: store)
        XCTAssertTrue(reopened.recoveredFromBackup)
        XCTAssertEqual(reopened.project.name, "Good")
        await reopened.close()
    }

    // MARK: Export settings

    func testExportBitrateTable() {
        XCTAssertEqual(VEExportSettings.recommendedMbps(resolution: .p1080, frameRate: 30, codec: .h264), 12)
        XCTAssertEqual(VEExportSettings.recommendedMbps(resolution: .p1080, frameRate: 60, codec: .hevc), 12)
        XCTAssertEqual(VEExportSettings.recommendedMbps(resolution: .p2160, frameRate: 60, codec: .h264), 70)
        XCTAssertEqual(VEExportSettings.recommendedMbps(resolution: .p1080, frameRate: 24, codec: .h264), 9.6, accuracy: 0.001)
        XCTAssertEqual(VEExportSettings.recommendedMbps(resolution: .p1080, frameRate: 50, codec: .h264), 15, accuracy: 0.001)
        var s = VEExportSettings(resolution: .p1080, frameRate: 30, quality: .lower, customMbps: 0, codec: .h264, fileName: "x", saveToPhotos: false, hdr: false)
        XCTAssertEqual(s.videoBitrateBps, 7_200_000)
        s.quality = .higher
        XCTAssertEqual(s.videoBitrateBps, 19_200_000)
        XCTAssertEqual(VEExportSettings.codecDefault(for: .p2160), .hevc)
        XCTAssertEqual(VEExportSettings.codecDefault(for: .p720), .h264)
    }
}
