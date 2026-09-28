import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoBrowser

/// Unit tests for the move/copy duplicate rules. The plan is pure over `PhotoFacts`, so most cases
/// build facts by hand; the hash cases write small synthetic images to a temp folder and go through
/// the real ImageIO + dHash path. See `PhotoBrowserTests/README.md` for adding the test target.
final class DuplicateDetectionTests: XCTestCase {
    typealias D = DuplicateDetection
    typealias Facts = DuplicateDetection.PhotoFacts

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dupetests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Helpers

    private func facts(_ name: String, size: Int64 = 1000, w: Int = 4000, h: Int = 3000,
                       date: String? = "2024:06:13 10:15:00", sub: String? = nil,
                       make: String? = "Apple", model: String? = "iPhone 15 Pro",
                       exposure: Double? = 1 / 120, fNumber: Double? = 1.8, focal: Double? = 6.9, iso: Double? = 80,
                       hash: UInt64? = 0x0123_4567_89AB_CDEF, folder: String = "dest") -> Facts {
        var f = Facts(url: URL(fileURLWithPath: "/\(folder)/\(name)"))
        f.size = size; f.width = w; f.height = h
        f.captureDate = date.flatMap(D.parseEXIFDate); f.subSecond = sub
        f.make = make; f.model = model
        f.exposureTime = exposure; f.fNumber = fNumber; f.focalLength = focal; f.iso = iso
        f.hash = hash
        return f
    }

    /// Writes a synthetic image: a flat colour with a bright square whose position drives the dHash.
    @discardableResult
    private func writeImage(_ name: String, squareAt x: Int, size: Int = 320, in folder: URL? = nil) throws -> URL {
        let dir = folder ?? tmp!
        let w = size, h = size * 3 / 4
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw NSError(domain: "test", code: 1) }
        ctx.setFillColor(red: 0.15, green: 0.2, blue: 0.4, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: x, y: h / 4, width: w / 4, height: h / 2))
        // A gradient stripe so the hash is not degenerate.
        for i in 0..<w {
            ctx.setFillColor(red: CGFloat(i) / CGFloat(w), green: 0.5, blue: 0.2, alpha: 1)
            ctx.fill(CGRect(x: i, y: 0, width: 1, height: h / 8))
        }
        guard let cg = ctx.makeImage() else { throw NSError(domain: "test", code: 2) }
        let url = dir.appendingPathComponent(name)
        let type = url.pathExtension.lowercased() == "png" ? UTType.png : UTType.jpeg
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw NSError(domain: "test", code: 3) }
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    // MARK: - Stem

    func testPNGUpscalerSuffixIsStripped() {
        XCTAssertEqual(D.stem(forName: "IMG_1234_402C6DBE.png"), "img_1234")
        XCTAssertEqual(D.stem(forName: "IMG_1234_402c6dbe0a1b.PNG"), "img_1234")
        XCTAssertEqual(D.stem(forName: "IMG_1234.png"), "img_1234")
        // Too short / not hex / not a PNG: untouched.
        XCTAssertEqual(D.stem(forName: "IMG_1234_ABCDE.png"), "img_1234_abcde")
        XCTAssertEqual(D.stem(forName: "IMG_1234_402C6DBZ.png"), "img_1234_402c6dbz")
        XCTAssertEqual(D.stem(forName: "IMG_1234_402C6DBE.jpg"), "img_1234_402c6dbe")
    }

    // MARK: - Same-photo test

    func testSameNameDifferentPictureDoesNotMatch() {
        // Same stem, everything else says "different": another aspect, another date, another hash.
        let a = facts("Frame 2.jpg", w: 1920, h: 1080, date: "2024:01:01 12:00:00", hash: 0)
        let b = facts("Frame 2.PNG", w: 1080, h: 1350, date: "2024:02:02 12:00:00", hash: ~0)
        XCTAssertEqual(D.samePhoto(a, b), .different)
        XCTAssertTrue(D.plan(incoming: a, candidates: [b]).isPassthrough)
        // Even with identical aspect/date, a far-apart hash is a different picture.
        let c = facts("Frame 2.PNG", hash: ~0)
        XCTAssertEqual(D.samePhoto(facts("Frame 2.jpg", hash: 0), c), .different)
    }

    func testSamePictureDifferentNameNoEXIFMatchesViaHash() throws {
        // Real files: no EXIF at all, different names, same rendered picture (one JPEG, one PNG).
        let jpg = try writeImage("holiday.jpg", squareAt: 40)
        let png = try writeImage("something_else.png", squareAt: 40)
        var a = D.readFacts(jpg), b = D.readFacts(png)
        XCTAssertNil(a.captureDate); XCTAssertNil(b.captureDate)
        a.hash = PerceptualHash.dHash(jpg); b.hash = PerceptualHash.dHash(png)
        XCTAssertNotNil(a.hash); XCTAssertNotNil(b.hash)
        XCTAssertEqual(D.samePhoto(a, b), .same(verified: true))
        // …and the plan treats the PNG as a duplicate of the incoming original (Rule B).
        let plan = D.plan(incoming: a, candidates: [b])
        XCTAssertEqual(plan.operations, [.placeIncoming, .relocateExisting(png, into: D.duplicatePNGsFolder)])
    }

    func testBurstShotsWithIdenticalEXIFDoNotMatchBecauseHashDiffers() throws {
        // Two different pictures, identical EXIF-style facts; the hash is what separates them.
        let first = try writeImage("burst_1.jpg", squareAt: 10)
        let second = try writeImage("burst_2.jpg", squareAt: 200)
        var a = facts("burst_1.jpg", sub: "123", hash: nil); a.url = first
        var b = facts("burst_2.jpg", sub: "123", hash: nil); b.url = second
        a.hash = PerceptualHash.dHash(first); b.hash = PerceptualHash.dHash(second)
        XCTAssertNotNil(a.hash); XCTAssertNotNil(b.hash)
        XCTAssertGreaterThan(PerceptualHash.distance(a.hash!, b.hash!), D.maxHashDistance)
        XCTAssertEqual(D.samePhoto(a, b), .different)
        XCTAssertTrue(D.plan(incoming: a, candidates: [b]).isPassthrough)
    }

    func testMissingHashIsUnverifiedNotAMismatch() {
        let a = facts("a.jpg", hash: nil), b = facts("b.jpg", hash: nil)
        XCTAssertEqual(D.samePhoto(a, b), .same(verified: false))
        let plan = D.plan(incoming: a, candidates: [b])
        XCTAssertTrue(plan.unverified)
        XCTAssertFalse(plan.isPassthrough)
    }

    func testDateSubSecondAndExposureRules() {
        let base = facts("x.jpg")
        XCTAssertEqual(D.samePhoto(base, facts("y.jpg", date: "2024:06:13 10:15:01")), .different, "date differs by a second")
        XCTAssertEqual(D.samePhoto(facts("x.jpg", sub: "12"), facts("y.jpg", sub: "34")), .different, "sub-seconds differ")
        XCTAssertEqual(D.samePhoto(facts("x.jpg", sub: "12"), facts("y.jpg", sub: nil)), .same(verified: true), "one side lacks sub-seconds")
        XCTAssertEqual(D.samePhoto(base, facts("y.jpg", date: nil)), .same(verified: true), "one side lacks a date")
        XCTAssertEqual(D.samePhoto(base, facts("y.jpg", fNumber: 1.83)), .same(verified: true), "within 5%")
        XCTAssertEqual(D.samePhoto(base, facts("y.jpg", fNumber: 2.8)), .different, "beyond 5%")
        XCTAssertEqual(D.samePhoto(base, facts("y.jpg", model: "iPhone 12")), .different, "camera differs")
        XCTAssertEqual(D.samePhoto(base, facts("y.jpg", w: 3000, h: 4000)), .same(verified: true), "rotated orientation")
        XCTAssertEqual(D.samePhoto(base, facts("y.jpg", w: 4000, h: 4000)), .different, "aspect differs")
    }

    // MARK: - Rule A

    func testRuleAIncomingReplacesExistingWhenSameSizeAndNotNewer() {
        let existing = facts("IMG_0001.jpg", size: 5000, date: "2024:06:13 10:15:00")
        let incoming = facts("IMG_0001.jpg", size: 5000, date: "2024:06:13 10:15:00", folder: "src")
        let plan = D.plan(incoming: incoming, candidates: [existing])
        XCTAssertEqual(plan.operations, [.relocateExisting(existing.url, into: D.duplicatesFolder), .placeIncoming])
        XCTAssertTrue(plan.log.contains { $0.contains("Rule A") && $0.contains("replaces") })
    }

    func testRuleAIncomingReplacesExistingWhenADateIsMissing() {
        let existing = facts("IMG_0001.heic", size: 5000, date: nil)
        let incoming = facts("IMG_0001.heic", size: 5000, folder: "src")
        XCTAssertEqual(D.plan(incoming: incoming, candidates: [existing]).operations,
                       [.relocateExisting(existing.url, into: D.duplicatesFolder), .placeIncoming])
    }

    func testRuleAIncomingGoesToDuplicatesWhenSizeDiffersOrItIsNewer() {
        let existing = facts("IMG_0001.jpg", size: 5000, date: "2024:06:13 10:15:00")
        // Different byte size → incoming set aside, existing untouched.
        let bigger = facts("IMG_0001.jpg", size: 6000, folder: "src")
        XCTAssertEqual(D.plan(incoming: bigger, candidates: [existing]).operations, [.divertIncoming(into: D.duplicatesFolder)])
        // Same size but the incoming capture is later. The dates still match "to the second" (rule 2
        // compares whole seconds), so the pair is the same photo — and the newer one is the copy.
        var newer = facts("IMG_0001.jpg", size: 5000, folder: "src")
        newer.captureDate = existing.captureDate!.addingTimeInterval(0.5)
        XCTAssertEqual(D.plan(incoming: newer, candidates: [existing]).operations, [.divertIncoming(into: D.duplicatesFolder)])
    }

    // MARK: - Rule B

    func testRuleBMovesEveryMatchingPNG() {
        let png1 = facts("IMG_0001_402C6DBE.png", size: 9000)
        let png2 = facts("IMG_0001.png", size: 8000)
        let unrelated = facts("IMG_0001_other.png", hash: ~0)                 // same stem family, different picture
        let incoming = facts("IMG_0001.jpg", folder: "src")
        let plan = D.plan(incoming: incoming, candidates: [png1, png2, unrelated])
        XCTAssertEqual(plan.operations.first, .placeIncoming)
        XCTAssertEqual(Set(plan.operations.dropFirst()),
                       [.relocateExisting(png1.url, into: D.duplicatePNGsFolder), .relocateExisting(png2.url, into: D.duplicatePNGsFolder)])
    }

    func testRuleAThenRuleBWhenBothApply() {
        let existing = facts("IMG_0001.jpg", size: 5000)
        let png = facts("IMG_0001_402C6DBE.png")
        let incoming = facts("IMG_0001.jpg", size: 5000, folder: "src")
        let plan = D.plan(incoming: incoming, candidates: [png, existing])
        XCTAssertEqual(plan.operations, [.relocateExisting(existing.url, into: D.duplicatesFolder), .placeIncoming,
                                         .relocateExisting(png.url, into: D.duplicatePNGsFolder)])
    }

    func testIncomingPNGMatchingAnOriginalIsDiverted() {
        let original = facts("IMG_0001.jpg")
        let incoming = facts("IMG_0001_402C6DBE.png", folder: "src")
        XCTAssertEqual(D.plan(incoming: incoming, candidates: [original]).operations, [.divertIncoming(into: D.duplicatePNGsFolder)])
        // PNG vs PNG: unchanged behaviour.
        XCTAssertTrue(D.plan(incoming: incoming, candidates: [facts("IMG_0001.png")]).isPassthrough)
    }

    func testVideosAndUnknownFormatsPassThrough() {
        let mov = facts("clip.mov"), incoming = facts("clip.mov", folder: "src")
        XCTAssertTrue(D.plan(incoming: incoming, candidates: [mov]).isPassthrough)
    }

    // MARK: - Helper-folder naming

    func testNameClashInDuplicatesGetsUnderscoreSuffix() throws {
        let dup = tmp.appendingPathComponent(D.duplicatesFolder, isDirectory: true)
        let first = D.uniqueURL(for: "IMG_0001.jpg", in: dup)
        XCTAssertEqual(first.lastPathComponent, "IMG_0001.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dup.path), "helper folder is created on first use")
        try Data([1]).write(to: first)
        let second = D.uniqueURL(for: "IMG_0001.jpg", in: dup)
        XCTAssertEqual(second.lastPathComponent, "IMG_0001_1.jpg")
        try Data([2]).write(to: second)
        XCTAssertEqual(D.uniqueURL(for: "IMG_0001.jpg", in: dup).lastPathComponent, "IMG_0001_2.jpg")
        XCTAssertEqual(D.uniqueURL(for: "noext", in: dup).lastPathComponent, "noext")
    }

    // MARK: - End to end through the real move path

    func testMoveItemsAppliesRuleBOnDisk() async throws {
        let dest = tmp.appendingPathComponent("dest", isDirectory: true)
        let src = tmp.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let png = try writeImage("IMG_0001_402C6DBE.png", squareAt: 60, in: dest)
        let unrelated = try writeImage("IMG_0002.png", squareAt: 220, in: dest)
        let incoming = try writeImage("IMG_0001.jpg", squareAt: 60, in: src)

        let outcome = await FileActions.moveItems([incoming], to: dest, renameOnCollision: true) { _ in }
        XCTAssertEqual(outcome.moved.map(\.to.lastPathComponent), ["IMG_0001.jpg"])
        XCTAssertEqual(outcome.relocated.map(\.from), [png])
        XCTAssertEqual(outcome.relocated.first?.to.deletingLastPathComponent().lastPathComponent, D.duplicatePNGsFolder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("IMG_0001.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: png.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "a different picture is left alone")
    }
}
