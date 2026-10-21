import SwiftUI
import UIKit

/// The app's look, as chosen in Settings ▸ Appearance: the background behind the browsing
/// surfaces (a solid colour or a gradient), the accent colour (chips, buttons, selection),
/// the typeface, and whether the chrome is dark or light. Ready-made themes — everyday,
/// Halloween and Christmas sets — are just values of this; "Custom" is whatever the pickers
/// say. Stored by `Library` (`photoBrowser.theme`, JSON) so it's one app-wide value.
///
/// How it reaches the screen: `AppGradient` (the background every browsing screen sits on)
/// draws `background`; the root applies `.tint`, `.preferredColorScheme`, `.fontDesign` and
/// the default `Font`; the chip bar and headers ask `font(_:)` for theirs; navigation-bar
/// titles take the family through `applyNavigationBarFont()` (UIKit appearance — new bars
/// pick it up, the one already on screen after a relaunch).
struct AppTheme: Codable, Equatable, Sendable {
    /// A colour that survives JSON — `Color` itself doesn't.
    struct RGB: Codable, Equatable, Sendable {
        var r: Double, g: Double, b: Double
        init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
        init(hex: UInt32) {
            r = Double((hex >> 16) & 0xFF) / 255; g = Double((hex >> 8) & 0xFF) / 255; b = Double(hex & 0xFF) / 255
        }
        init(_ color: Color) {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            r = Double(red); g = Double(green); b = Double(blue)
        }
        var color: Color { Color(red: r, green: g, blue: b) }
        /// Perceived brightness 0…1, to keep text readable on a custom background.
        var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    }

    enum Direction: String, Codable, CaseIterable, Sendable {
        case down, diagonal, across
        var title: String {
            switch self { case .down: return "Top to bottom"; case .diagonal: return "Diagonal"; case .across: return "Left to right" }
        }
        var points: (UnitPoint, UnitPoint) {
            switch self {
            case .down: return (.top, .bottom)
            case .diagonal: return (.topLeading, .bottomTrailing)
            case .across: return (.leading, .trailing)
            }
        }
    }

    enum Background: Codable, Equatable, Sendable {
        case solid(RGB)
        case gradient([RGB], Direction)

        var colors: [RGB] {
            switch self { case .solid(let c): return [c]; case .gradient(let cs, _): return cs }
        }
        var isGradient: Bool { if case .gradient = self { return true }; return false }
        /// Brightness of the whole background (its colours averaged).
        var luminance: Double { colors.map(\.luminance).reduce(0, +) / Double(max(colors.count, 1)) }
    }

    /// The typeface. The first four are the system font's designs, which every system-font
    /// text in the app follows; the rest are families built into iOS, applied where the
    /// theme is asked for a font and to navigation titles.
    enum FontChoice: String, Codable, CaseIterable, Sendable {
        case system, rounded, serif, mono
        case avenir, georgia, futura, chalkboard, markerFelt, noteworthy, copperplate, bradleyHand, snellRoundhand

        var title: String {
            switch self {
            case .system: return "System"
            case .rounded: return "Rounded"
            case .serif: return "Serif"
            case .mono: return "Monospaced"
            case .avenir: return "Avenir Next"
            case .georgia: return "Georgia"
            case .futura: return "Futura"
            case .chalkboard: return "Chalkboard"
            case .markerFelt: return "Marker Felt"
            case .noteworthy: return "Noteworthy"
            case .copperplate: return "Copperplate"
            case .bradleyHand: return "Bradley Hand"
            case .snellRoundhand: return "Snell Roundhand"
            }
        }
        /// The system design, for the four design choices.
        var design: Font.Design? {
            switch self {
            case .system: return .default
            case .rounded: return .rounded
            case .serif: return .serif
            case .mono: return .monospaced
            default: return nil
            }
        }
        /// The PostScript name of the family's regular face, for the custom families.
        var postScriptName: String? {
            switch self {
            case .avenir: return "AvenirNext-Regular"
            case .georgia: return "Georgia"
            case .futura: return "Futura-Medium"
            case .chalkboard: return "ChalkboardSE-Regular"
            case .markerFelt: return "MarkerFelt-Thin"
            case .noteworthy: return "Noteworthy-Light"
            case .copperplate: return "Copperplate"
            case .bradleyHand: return "BradleyHandITCTT-Bold"
            case .snellRoundhand: return "SnellRoundhand-Bold"
            default: return nil
            }
        }
        /// The family's heavier face, for titles.
        var boldPostScriptName: String? {
            switch self {
            case .avenir: return "AvenirNext-Bold"
            case .georgia: return "Georgia-Bold"
            case .futura: return "Futura-Bold"
            case .chalkboard: return "ChalkboardSE-Bold"
            case .markerFelt: return "MarkerFelt-Wide"
            case .noteworthy: return "Noteworthy-Bold"
            case .copperplate: return "Copperplate-Bold"
            case .bradleyHand: return "BradleyHandITCTT-Bold"
            case .snellRoundhand: return "SnellRoundhand-Black"
            default: return nil
            }
        }
    }

    var name: String
    var background: Background
    var accent: RGB
    var typeface: FontChoice
    var light: Bool

    // MARK: - What the views ask for

    var accentColor: Color { accent.color }
    var colorScheme: ColorScheme { light ? .light : .dark }
    var fontDesign: Font.Design? { typeface.design }

    /// The theme's font at a text style — a custom family sized like the style, or the system
    /// font in the theme's design.
    func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        if let name = typeface.postScriptName {
            let size = UIFont.preferredFont(forTextStyle: style.uiTextStyle).pointSize
            let face = (weight == .semibold || weight == .bold || weight == .heavy) ? (typeface.boldPostScriptName ?? name) : name
            return .custom(face, size: size, relativeTo: style)
        }
        return .system(style, design: typeface.design ?? .default).weight(weight)
    }

    /// The default font for text that sets none — only a custom family changes it (the
    /// designs reach everything through `.fontDesign`).
    var defaultFont: Font? { typeface.postScriptName == nil ? nil : font(.body) }

    @ViewBuilder var backgroundView: some View {
        switch background {
        case .solid(let c):
            c.color
        case .gradient(let cs, let dir):
            LinearGradient(colors: cs.map(\.color), startPoint: dir.points.0, endPoint: dir.points.1)
        }
    }

    /// Navigation-bar titles in the theme's family (the system designs are left to SwiftUI).
    /// Appearance proxies apply to bars created afterwards.
    func applyNavigationBarFont() {
        let bar = UINavigationBar.appearance()
        guard let regular = typeface.postScriptName, let bold = typeface.boldPostScriptName,
              let title = UIFont(name: bold, size: 17), let large = UIFont(name: bold, size: 34) ?? UIFont(name: regular, size: 34) else {
            bar.titleTextAttributes = nil
            bar.largeTitleTextAttributes = nil
            return
        }
        bar.titleTextAttributes = [.font: title]
        bar.largeTitleTextAttributes = [.font: large]
    }

    // MARK: - Presets

    static let standard = AppTheme(name: "Photo Browser",
                                   background: .gradient([RGB(0.05, 0.09, 0.20), RGB(0, 0, 0)], .down),
                                   accent: RGB(hex: 0x0A84FF), typeface: .system, light: false)

    struct ThemeGroup: Identifiable { let name: String; let themes: [AppTheme]; var id: String { name } }

    static let groups: [ThemeGroup] = [
        ThemeGroup(name: "Everyday", themes: [
            standard,
            AppTheme(name: "Graphite", background: .solid(RGB(hex: 0x1C1C1E)), accent: RGB(hex: 0xC7C7CC), typeface: .system, light: false),
            AppTheme(name: "Midnight", background: .gradient([RGB(hex: 0x0B1026), RGB(hex: 0x1A0B2E)], .diagonal),
                     accent: RGB(hex: 0x8E7CFF), typeface: .rounded, light: false),
            AppTheme(name: "Ocean", background: .gradient([RGB(hex: 0x04263B), RGB(hex: 0x000814)], .down),
                     accent: RGB(hex: 0x2EC4B6), typeface: .rounded, light: false),
            AppTheme(name: "Rose", background: .gradient([RGB(hex: 0x2B0A1E), RGB(hex: 0x0D0208)], .down),
                     accent: RGB(hex: 0xFF6B9A), typeface: .serif, light: false),
            AppTheme(name: "Forest", background: .gradient([RGB(hex: 0x0B2A1A), RGB(hex: 0x02110A)], .down),
                     accent: RGB(hex: 0x7ED957), typeface: .rounded, light: false),
            AppTheme(name: "Sunset", background: .gradient([RGB(hex: 0x2D0A4E), RGB(hex: 0x7A1F3D), RGB(hex: 0xC2410C)], .diagonal),
                     accent: RGB(hex: 0xFFB703), typeface: .system, light: false),
            AppTheme(name: "Paper", background: .gradient([RGB(hex: 0xFFFFFF), RGB(hex: 0xEDEDF2)], .down),
                     accent: RGB(hex: 0x0A84FF), typeface: .serif, light: true),
        ]),
        ThemeGroup(name: "Halloween", themes: [
            AppTheme(name: "Pumpkin Patch", background: .gradient([RGB(hex: 0x1A0A00), RGB(hex: 0x3D1A00), RGB(hex: 0x000000)], .down),
                     accent: RGB(hex: 0xFF7A00), typeface: .chalkboard, light: false),
            AppTheme(name: "Witching Hour", background: .gradient([RGB(hex: 0x120024), RGB(hex: 0x2A0A4A)], .diagonal),
                     accent: RGB(hex: 0x39D353), typeface: .chalkboard, light: false),
            AppTheme(name: "Haunted House", background: .solid(RGB(hex: 0x0E0E10)),
                     accent: RGB(hex: 0xC41E3A), typeface: .markerFelt, light: false),
            AppTheme(name: "Candy Corn", background: .gradient([RGB(hex: 0x3D1F00), RGB(hex: 0x7A3E00), RGB(hex: 0xB37400)], .down),
                     accent: RGB(hex: 0xFFF3B0), typeface: .noteworthy, light: false),
            AppTheme(name: "Ghost Story", background: .gradient([RGB(hex: 0x1B1F2A), RGB(hex: 0x0B0D12)], .down),
                     accent: RGB(hex: 0xB8C7E0), typeface: .bradleyHand, light: false),
        ]),
        ThemeGroup(name: "Christmas", themes: [
            AppTheme(name: "Candy Cane", background: .gradient([RGB(hex: 0x7A0000), RGB(hex: 0xB3001B)], .diagonal),
                     accent: RGB(hex: 0xFFFFFF), typeface: .rounded, light: false),
            AppTheme(name: "Evergreen", background: .gradient([RGB(hex: 0x0B3D20), RGB(hex: 0x06281A), RGB(hex: 0x021A10)], .down),
                     accent: RGB(hex: 0xFFD700), typeface: .serif, light: false),
            AppTheme(name: "Winter Night", background: .gradient([RGB(hex: 0x0A1931), RGB(hex: 0x185ADB)], .down),
                     accent: RGB(hex: 0xBFE9FF), typeface: .rounded, light: false),
            AppTheme(name: "Cozy Fireplace", background: .gradient([RGB(hex: 0x2B1105), RGB(hex: 0x4A1C0C), RGB(hex: 0x1A0A05)], .down),
                     accent: RGB(hex: 0xFF9F1C), typeface: .georgia, light: false),
            AppTheme(name: "Snow Day", background: .gradient([RGB(hex: 0xFFFFFF), RGB(hex: 0xDCEBFF)], .down),
                     accent: RGB(hex: 0xD7263D), typeface: .rounded, light: true),
            AppTheme(name: "Silver Bells", background: .gradient([RGB(hex: 0x2C2F36), RGB(hex: 0x0F1115)], .down),
                     accent: RGB(hex: 0xE6E6EB), typeface: .snellRoundhand, light: false),
        ]),
    ]

    static var presets: [AppTheme] { groups.flatMap(\.themes) }

    /// A preset this equals (by its looks, not its name), if any.
    var matchingPreset: AppTheme? {
        Self.presets.first { $0.background == background && $0.accent == accent && $0.typeface == typeface && $0.light == light }
    }

    // MARK: - Storage

    static let key = "photoBrowser.theme"

    static func load() -> AppTheme {
        guard let data = UserDefaults.standard.data(forKey: key),
              let t = try? JSONDecoder().decode(AppTheme.self, from: data) else { return standard }
        return t
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

extension Font.TextStyle {
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}
