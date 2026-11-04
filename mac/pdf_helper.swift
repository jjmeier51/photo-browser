// The PDF composer for Safe Finder's "Optimize for iPhone" / "Optimize for Safe Finder" (mac/pdf_optimize.py).
// Python reads the pages and decides where every part goes (the plan); this draws it — each part of an original
// page clipped and scaled onto its new page with Core Graphics, so the drawing stays the original's: vectors, its
// fonts, its pictures at their own resolution, and text that can still be searched and selected. Built once with
// `swiftc` into ~/Library/Caches/PhotoBrowser/; without it Qt draws the plan from pictures of the pages.
//
//   pdf_helper compose <source.pdf> <plan.json> <out.pdf>     prints "page i n" as it goes; exit 0 when written,
//                                                             else "error <why>" and exit 1
//
// The plan: {"title", "creator", "pages": [{"size": [w, h], "pieces": [{"page": i, "src": [x, y, w, h],
// "dst": [x, y, w, h]}]}]} — points, from the top left; `src` on page i (from 0) as it's shown (turned by its
// /Rotate, within its crop box). A password, when the PDF has one, comes in PDF_PASSWORD.
import CoreGraphics
import Foundation

struct Plan: Decodable {
    struct Piece: Decodable {
        let page: Int
        let src: [Double]
        let dst: [Double]
    }
    struct Page: Decodable {
        let size: [Double]
        let pieces: [Piece]
    }
    let title: String?
    let creator: String?
    let pages: [Page]
}

func say(_ line: String) {
    print(line)
    fflush(stdout)
}

func fail(_ why: String) -> Int32 {
    say("error \(why)")
    return 1
}

/// The page's shown size (its crop box, turned by its rotation) and the transform that draws it there with its
/// bottom left at the origin — scale 1, as the rect is exactly that size.
func shownSpace(_ page: CGPDFPage) -> (CGSize, CGAffineTransform) {
    let crop = page.getBoxRect(.cropBox)
    let quarterTurns = ((Int(page.rotationAngle) % 360) + 360) % 360 / 90
    let size = quarterTurns % 2 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
    let t = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0,
                                     preserveAspectRatio: true)
    return (size, t)
}

func compose(source: URL, planURL: URL, out: URL) -> Int32 {
    guard let data = try? Data(contentsOf: planURL), let plan = try? JSONDecoder().decode(Plan.self, from: data) else {
        return fail("the plan couldn't be read")
    }
    guard let doc = CGPDFDocument(source as CFURL) else { return fail("the PDF couldn't be opened") }
    if doc.isEncrypted && !doc.isUnlocked {
        let password = ProcessInfo.processInfo.environment["PDF_PASSWORD"] ?? ""
        if !doc.unlockWithPassword(password) { return fail("the PDF is protected by a password") }
    }
    var info: [CFString: Any] = [kCGPDFContextCreator: plan.creator ?? "Safe Finder"]
    if let title = plan.title, !title.isEmpty { info[kCGPDFContextTitle] = title }
    var first = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let ctx = CGContext(out as CFURL, mediaBox: &first, info as CFDictionary) else {
        return fail("the new PDF couldn't be started")
    }
    var spaces: [Int: (CGSize, CGAffineTransform)] = [:]
    for (n, page) in plan.pages.enumerated() {
        guard page.size.count == 2 else { continue }
        let w = page.size[0], h = page.size[1]
        var box = CGRect(x: 0, y: 0, width: w, height: h)
        let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
        for piece in page.pieces {
            guard piece.src.count == 4, piece.dst.count == 4, piece.src[2] > 0, piece.src[3] > 0,
                  let src = doc.page(at: piece.page + 1) else { continue }
            let (shown, toShown) = spaces[piece.page] ?? shownSpace(src)
            spaces[piece.page] = (shown, toShown)
            let (sx, sy, sw, sh) = (piece.src[0], piece.src[1], piece.src[2], piece.src[3])
            let (dx, dy, dw, dh) = (piece.dst[0], piece.dst[1], piece.dst[2], piece.dst[3])
            // From the top-left coordinates of the plan to PDF space (bottom left, y up).
            let dest = CGRect(x: dx, y: h - dy - dh, width: dw, height: dh)
            let sxScale = dw / sw, syScale = dh / sh
            ctx.saveGState()
            ctx.clip(to: dest)
            ctx.translateBy(x: dest.minX, y: dest.minY)
            ctx.scaleBy(x: sxScale, y: syScale)
            ctx.translateBy(x: -sx, y: -(Double(shown.height) - sy - sh))
            ctx.concatenate(toShown)
            ctx.drawPDFPage(src)
            ctx.restoreGState()
        }
        ctx.endPDFPage()
        say("page \(n + 1) \(plan.pages.count)")
    }
    ctx.closePDF()
    return 0
}

@main
struct PDFHelper {
    static func main() {
        let a = CommandLine.arguments
        guard a.count >= 5, a[1] == "compose" else {
            say("error usage: pdf_helper compose <source.pdf> <plan.json> <out.pdf>")
            exit(2)
        }
        exit(compose(source: URL(fileURLWithPath: a[2]), planURL: URL(fileURLWithPath: a[3]),
                     out: URL(fileURLWithPath: a[4])))
    }
}
