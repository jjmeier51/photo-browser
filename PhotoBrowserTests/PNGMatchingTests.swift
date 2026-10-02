import XCTest
@testable import PhotoBrowser

/// Unit tests for the Compare PNGs rules (`PNGMatching`), which are pure over `Candidate` values —
/// no disk, no ImageIO. See `PhotoBrowserTests/README.md` for adding the test target.
final class PNGMatchingTests: XCTestCase {
    typealias M = PNGMatching

    private func cand(_ name: String, aspect: Double? = 4.0 / 3.0, hash: UInt64? = 0x0123_4567_89AB_CDEF) -> M.Candidate {
        M.Candidate(url: URL(fileURLWithPath: "/folder/\(name)"), aspect: aspect, hash: hash)
    }
    /// A hash `bits` Hamming-bits away from the default one.
    private func far(_ bits: Int) -> UInt64 {
        var h: UInt64 = 0x0123_4567_89AB_CDEF
        for i in 0..<bits { h ^= (1 << UInt64(i)) }
        return h
    }

    // MARK: - Name keys

    func testNameKeyStripsExtensionCaseAndCopySuffixes() {
        XCTAssertEqual(M.nameKey("IMG_2225.PNG"), "img_2225")
        XCTAssertEqual(M.nameKey("IMG_2225 (1).jpg"), "img_2225")
        XCTAssertEqual(M.nameKey("IMG_2225 copy 2.heic"), "img_2225")
        XCTAssertEqual(M.nameKey("IMG_2225 copy (3).png"), "img_2225")
    }

    func testNameKeyKeepsNumbersThatArePartOfTheName() {
        XCTAssertEqual(M.nameKey("Frame 97.png"), "frame 97")
        XCTAssertEqual(M.nameKey("Frame 97_XHDN3.png"), "frame 97_xhdn3")
    }

    // MARK: - Similar names

    func testIdenticalKeysAreSimilar() {
        XCTAssertTrue(M.similarNames(M.nameKey("IMG_2225.png"), M.nameKey("IMG_2225.jpg")))
        XCTAssertTrue(M.similarNames(M.nameKey("IMG_2225 (1).png"), M.nameKey("IMG_2225.heic")))
    }

    func testTaggedSuffixIsSimilar() {
        XCTAssertTrue(M.similarNames("frame 97", "frame 97_xhdn3"))
        XCTAssertTrue(M.similarNames("img_1234", "img_1234_402c6dbe"))
        XCTAssertTrue(M.similarNames("img_1234", "img_1234-upscaled"))
        XCTAssertTrue(M.similarNames("img_1234", "img_1234_1"))        // short copy number
    }

    func testDifferentFramesAreNotSimilar() {
        XCTAssertFalse(M.similarNames("frame 9", "frame 97"))
        XCTAssertFalse(M.similarNames("frame", "frame 97"))             // a bare space is not a tag separator
        XCTAssertFalse(M.similarNames("frame 97", "frame 98"))
        XCTAssertFalse(M.similarNames("img_1234", "img_1234_5678"))     // a long all-digit tag is a different shot
        XCTAssertFalse(M.similarNames("", "img_1234"))
    }

    // MARK: - Pair reasons

    func testPNGAndJPEGWithSameNameMatchByName() {
        let r = M.reasons(cand("IMG_2225.png", hash: far(20)), cand("IMG_2225.jpg"))
        XCTAssertEqual(r, [.name])
    }

    func testPNGAndJPEGThatLookAlikeMatchVisually() {
        let r = M.reasons(cand("export.png", hash: far(3)), cand("IMG_0001.jpg"))
        XCTAssertEqual(r, [.visual])
    }

    func testBothReasonsWhenNameAndLookAgree() {
        let r = M.reasons(cand("IMG_2225_402C6DBE.png", hash: far(1)), cand("IMG_2225.heic"))
        XCTAssertEqual(r, [.name, .visual])
    }

    func testVisualMatchNeedsSameAspect() {
        XCTAssertTrue(M.reasons(cand("a.png", aspect: 1.0), cand("b.jpg", aspect: 16.0 / 9.0)).isEmpty)
        XCTAssertEqual(M.reasons(cand("a.png", aspect: 1.5), cand("b.jpg", aspect: 1.5)), [.visual])
        XCTAssertEqual(M.reasons(cand("a.png", aspect: nil), cand("b.jpg", aspect: 1.5)), [.visual])   // unknown never blocks
    }

    func testVisualMatchRespectsTheDistanceThreshold() {
        XCTAssertEqual(M.reasons(cand("a.png", hash: far(M.maxHashDistance)), cand("b.jpg")), [.visual])
        XCTAssertTrue(M.reasons(cand("a.png", hash: far(M.maxHashDistance + 1)), cand("b.jpg")).isEmpty)
    }

    func testTwoOriginalsNeverMatchHere() {
        XCTAssertTrue(M.reasons(cand("IMG_1.jpg"), cand("IMG_1.heic")).isEmpty)       // same look, same name — not a PNG
    }

    func testFrameFilesOnlyMatchOtherPNGsByName() {
        // Frame PNG ↔ tagged Frame PNG: by name.
        XCTAssertEqual(M.reasons(cand("Frame 97.png", hash: nil), cand("Frame 97_XHDN3.png", hash: nil)), [.name])
        // Frame PNG ↔ identically named JPEG: never (frames don't pair with originals).
        XCTAssertTrue(M.reasons(cand("Frame 97.png", hash: nil), cand("Frame 97.jpg")).isEmpty)
        // Frame PNG ↔ visually identical non-frame PNG: never (frames are name-only).
        XCTAssertTrue(M.reasons(cand("Frame 97.png", hash: 0x1), cand("still.png", hash: 0x1)).isEmpty)
        // Different frames: never, however alike they look.
        XCTAssertTrue(M.reasons(cand("Frame 97.png", hash: 0x1), cand("Frame 98.png", hash: 0x1)).isEmpty)
    }

    // MARK: - Pairs and clusters

    func testPairsAreUnorderedAndReportedOnce() {
        let items = [cand("a.png"), cand("a.jpg"), cand("b.png", hash: far(30)), cand("a (1).png")]
        let pairs = M.pairs(items)
        // a.png↔a.jpg, a.png↔a (1).png, a.jpg↔a (1).png; b.png matches nothing.
        XCTAssertEqual(pairs.count, 3)
        XCTAssertTrue(pairs.allSatisfy { $0.a < $0.b })
        XCTAssertFalse(pairs.contains { $0.a == 2 || $0.b == 2 })
    }

    func testClustersMergeLinkedFilesAndTheirReasons() {
        let items = [
            cand("IMG_1.png", hash: far(2)),              // 0: name ↔ 1, visual ↔ 2
            cand("IMG_1.jpg", hash: far(30)),             // 1
            cand("export.jpg", hash: far(1)),             // 2
            cand("Frame 5.png", hash: nil),               // 3: name ↔ 4
            cand("Frame 5_ab12.png", hash: nil),          // 4
            cand("lonely.png", hash: far(40)),            // 5
        ]
        let clusters = M.cluster(count: items.count, pairs: M.pairs(items))
        XCTAssertEqual(clusters.count, 2)
        let first = clusters.first { $0.indices.contains(0) }!
        XCTAssertEqual(first.indices, [0, 1, 2])
        XCTAssertEqual(first.reasons, [.name, .visual])
        let frames = clusters.first { $0.indices.contains(3) }!
        XCTAssertEqual(frames.indices, [3, 4])
        XCTAssertEqual(frames.reasons, [.name])
    }

    func testCandidateFiltersToPNGsAndOriginals() {
        XCTAssertTrue(M.isCandidate(URL(fileURLWithPath: "/x/a.PNG")))
        XCTAssertTrue(M.isCandidate(URL(fileURLWithPath: "/x/a.heic")))
        XCTAssertTrue(M.isCandidate(URL(fileURLWithPath: "/x/a.dng")))
        XCTAssertFalse(M.isCandidate(URL(fileURLWithPath: "/x/a.gif")))
        XCTAssertFalse(M.isCandidate(URL(fileURLWithPath: "/x/a.mov")))
    }
}
