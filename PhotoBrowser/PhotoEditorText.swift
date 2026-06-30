import UIKit
import CoreImage

/// On-device text rendering for the editor's Text tool. A `TextRender.image(...)` call rasterizes a string
/// with a chosen font, color, bold/italic style and one of 15 styled effects (glow, fire, gold, …) into a
/// transparent UIImage. The image is then placed/scaled/rotated like a sticker and composited by the
/// pipeline, so text inherits the same metadata-preserving, HDR-aware save path.
enum TextEffect: String, CaseIterable, Identifiable {
    case plain, shadow, glow, outline, neon, fire, ice, gold, chrome, rainbow, threeD, sticker, retro, bubble, emboss
    var id: String { rawValue }
    var label: String {
        switch self {
        case .plain: return "Plain";   case .shadow: return "Shadow"; case .glow: return "Glow"
        case .outline: return "Outline"; case .neon: return "Neon";   case .fire: return "Fire"
        case .ice: return "Ice";       case .gold: return "Gold";     case .chrome: return "Chrome"
        case .rainbow: return "Rainbow"; case .threeD: return "3D";   case .sticker: return "Sticker"
        case .retro: return "Retro";   case .bubble: return "Bubble"; case .emboss: return "Emboss"
        }
    }
}

enum TextRender {
    /// 50 fonts offered in the picker. `font(...)` falls back to the system font if a name is unavailable.
    static let fonts: [String] = [
        "Helvetica Neue", "Avenir Next", "Avenir", "Futura", "Gill Sans", "Georgia", "Times New Roman",
        "Palatino", "Baskerville", "Didot", "Bodoni 72", "Cochin", "Hoefler Text", "Optima", "Marker Felt",
        "Chalkboard SE", "Chalkduster", "Noteworthy", "Bradley Hand", "Snell Roundhand", "Zapfino",
        "Savoye LET", "American Typewriter", "Courier New", "Menlo", "Copperplate", "Papyrus", "Trattatello",
        "Party LET", "Academy Engraved LET", "Arial", "Arial Rounded MT Bold", "Verdana", "Trebuchet MS",
        "Charter", "Iowan Old Style", "Seravek", "Superclarendon", "Rockwell", "Phosphate", "SignPainter",
        "Avenir Next Condensed", "Helvetica", "Courier", "Damascus", "Kefa", "Euphemia UCAS",
        "Khmer Sangam MN", "Tamil Sangam MN", "PingFang SC",
    ]

    static func font(name: String, size: CGFloat, bold: Bool, italic: Bool) -> UIFont {
        let base = UIFont(name: name, size: size) ?? UIFont.systemFont(ofSize: size)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if traits.isEmpty { return base }
        if let d = base.fontDescriptor.withSymbolicTraits(traits) { return UIFont(descriptor: d, size: size) }
        return base
    }

    /// Renders `string` to a transparent image. Drawn at a large fixed point size for crispness; the editor
    /// scales the result when placing it. Returns nil for an empty string.
    static func image(string: String, fontName: String, color: UIColor,
                      bold: Bool, italic: Bool, effect: TextEffect) -> UIImage? {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let pt: CGFloat = 240
        let font = font(name: fontName, size: pt, bold: bold, italic: italic)
        let ns = text as NSString
        let textSize = ns.size(withAttributes: [.font: font])
        let pad = pt * 0.55                                  // room for glow / shadow / outline / 3D
        let canvas = CGSize(width: ceil(textSize.width + pad * 2),
                            height: ceil(textSize.height + pad * 2))
        guard canvas.width > 1, canvas.height > 1, canvas.width < 8000, canvas.height < 8000 else { return nil }
        let origin = CGPoint(x: (canvas.width - textSize.width) / 2, y: (canvas.height - textSize.height) / 2)
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.opaque = false; fmt.scale = 1
        return UIGraphicsImageRenderer(size: canvas, format: fmt).image { rctx in
            draw(ns, font: font, color: color, effect: effect, origin: origin,
                 textSize: textSize, canvas: canvas, ctx: rctx.cgContext)
        }
    }

    // MARK: drawing

    private static func draw(_ ns: NSString, font: UIFont, color: UIColor, effect: TextEffect,
                             origin: CGPoint, textSize: CGSize, canvas: CGSize, ctx: CGContext) {
        func attrs(_ c: UIColor, stroke: (UIColor, CGFloat)? = nil) -> [NSAttributedString.Key: Any] {
            var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: c]
            if let (sc, w) = stroke { a[.strokeColor] = sc; a[.strokeWidth] = w }   // negative width = fill+stroke
            return a
        }
        func drawText(_ a: [NSAttributedString.Key: Any], at p: CGPoint) { ns.draw(at: p, withAttributes: a) }

        switch effect {
        case .plain:
            drawText(attrs(color), at: origin)

        case .shadow:
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: font.pointSize * 0.05, height: font.pointSize * 0.05),
                          blur: font.pointSize * 0.10, color: UIColor.black.withAlphaComponent(0.6).cgColor)
            drawText(attrs(color), at: origin)
            ctx.restoreGState()

        case .glow:
            ctx.saveGState()
            for _ in 0..<2 {
                ctx.setShadow(offset: .zero, blur: font.pointSize * 0.22, color: color.cgColor)
                drawText(attrs(color), at: origin)
            }
            ctx.restoreGState()

        case .outline:
            drawText(attrs(color, stroke: (color.contrastingOutline, -6)), at: origin)

        case .neon:
            ctx.saveGState()
            for _ in 0..<3 {
                ctx.setShadow(offset: .zero, blur: font.pointSize * 0.28, color: color.cgColor)
                drawText(attrs(.white), at: origin)
            }
            ctx.restoreGState()
            drawText(attrs(.white), at: origin)

        case .fire:
            gradientText(ns, font: font, origin: origin, textSize: textSize, canvas: canvas, ctx: ctx,
                         colors: [UIColor(red: 1, green: 0.95, blue: 0.4, alpha: 1),
                                  UIColor(red: 1, green: 0.55, blue: 0.05, alpha: 1),
                                  UIColor(red: 0.8, green: 0.05, blue: 0.0, alpha: 1)],
                         vertical: true, glow: UIColor(red: 1, green: 0.4, blue: 0, alpha: 1))

        case .ice:
            gradientText(ns, font: font, origin: origin, textSize: textSize, canvas: canvas, ctx: ctx,
                         colors: [.white, UIColor(red: 0.7, green: 0.92, blue: 1, alpha: 1),
                                  UIColor(red: 0.2, green: 0.55, blue: 0.95, alpha: 1)],
                         vertical: true, glow: UIColor(red: 0.5, green: 0.8, blue: 1, alpha: 1))

        case .gold:
            gradientText(ns, font: font, origin: origin, textSize: textSize, canvas: canvas, ctx: ctx,
                         colors: [UIColor(red: 1, green: 0.92, blue: 0.55, alpha: 1),
                                  UIColor(red: 0.95, green: 0.74, blue: 0.25, alpha: 1),
                                  UIColor(red: 0.55, green: 0.40, blue: 0.05, alpha: 1)], vertical: true)

        case .chrome:
            gradientText(ns, font: font, origin: origin, textSize: textSize, canvas: canvas, ctx: ctx,
                         colors: [UIColor(white: 0.95, alpha: 1), UIColor(white: 0.55, alpha: 1),
                                  UIColor(white: 0.85, alpha: 1), UIColor(white: 0.35, alpha: 1)], vertical: true)

        case .rainbow:
            gradientText(ns, font: font, origin: origin, textSize: textSize, canvas: canvas, ctx: ctx,
                         colors: [.red, .orange, .yellow, .green, .blue, .purple], vertical: false)

        case .threeD:
            let depth = Int(font.pointSize * 0.06)
            let dark = color.darkened
            for i in stride(from: depth, through: 1, by: -1) {
                drawText(attrs(dark), at: CGPoint(x: origin.x + CGFloat(i), y: origin.y + CGFloat(i)))
            }
            drawText(attrs(color), at: origin)

        case .sticker:
            drawText(attrs(.white, stroke: (.white, 14)), at: origin)   // thick white halo
            drawText(attrs(color), at: origin)

        case .retro:
            drawText(attrs(UIColor.black), at: CGPoint(x: origin.x + font.pointSize * 0.06,
                                                       y: origin.y + font.pointSize * 0.06))
            drawText(attrs(color), at: origin)

        case .bubble:
            drawText(attrs(.white, stroke: (.black, 18)), at: origin)   // thick black outline (hollow)
            drawText(attrs(color, stroke: (.white, -7)), at: origin)    // colored fill + light edge

        case .emboss:
            drawText(attrs(UIColor.white.withAlphaComponent(0.7)),
                     at: CGPoint(x: origin.x - 1.5, y: origin.y - 1.5))
            drawText(attrs(UIColor.black.withAlphaComponent(0.5)),
                     at: CGPoint(x: origin.x + 1.5, y: origin.y + 1.5))
            drawText(attrs(color), at: origin)
        }
    }

    /// Fills the text glyphs with a gradient. Draws the glyphs into a sub-image, then paints the gradient
    /// over them with `.sourceIn` so it only shows inside the letters — no manual masking/flipping. An
    /// optional soft glow is drawn behind first.
    private static func gradientText(_ ns: NSString, font: UIFont, origin: CGPoint, textSize: CGSize,
                                     canvas: CGSize, ctx: CGContext, colors: [UIColor],
                                     vertical: Bool, glow: UIColor? = nil) {
        if let glow {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: font.pointSize * 0.22, color: glow.cgColor)
            ns.draw(at: origin, withAttributes: [.font: font, .foregroundColor: glow])
            ctx.restoreGState()
        }
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: colors.map { $0.cgColor } as CFArray, locations: nil) else {
            ns.draw(at: origin, withAttributes: [.font: font, .foregroundColor: colors.first ?? .white]); return
        }
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.opaque = false; fmt.scale = 1
        let gimg = UIGraphicsImageRenderer(size: canvas, format: fmt).image { gc in
            let c = gc.cgContext
            ns.draw(at: origin, withAttributes: [.font: font, .foregroundColor: UIColor.white])
            c.setBlendMode(.sourceIn)
            let r = CGRect(x: origin.x, y: origin.y, width: textSize.width, height: textSize.height)
            if vertical {
                c.drawLinearGradient(grad, start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY),
                                     options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            } else {
                c.drawLinearGradient(grad, start: CGPoint(x: r.minX, y: r.midY), end: CGPoint(x: r.maxX, y: r.midY),
                                     options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }
        gimg.draw(at: .zero)
    }
}

private extension UIColor {
    var darkened: UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * 0.45, green: g * 0.45, blue: b * 0.45, alpha: a)
    }
    /// Black or white, whichever contrasts with this color (for outlines).
    var contrastingOutline: UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.6 ? .black : .white
    }
}
