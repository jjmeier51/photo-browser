import SwiftUI

/// Settings ▸ Appearance: pick a ready-made theme (everyday, Halloween, Christmas) or build
/// your own — background (one colour or a gradient), accent colour, typeface, dark or light.
/// Every change applies at once, so the app behind the sheet shows it; the pickers always
/// show what's in force, and choosing a theme loads it into them.
struct AppearanceView: View {
    @Environment(Library.self) private var library

    @State private var useGradient = true
    @State private var threeStops = false
    @State private var stops: [Color] = [.black, .black, .black]
    @State private var solid: Color = .black
    @State private var direction: AppTheme.Direction = .down
    @State private var accent: Color = .blue
    @State private var font: AppTheme.FontChoice = .system
    @State private var light = false
    @State private var loading = true          // the pickers are being filled from the theme, not edited

    private var theme: AppTheme { library.theme }

    var body: some View {
        Form {
            Section { preview.listRowInsets(EdgeInsets()) }

            ForEach(AppTheme.groups) { group in
                Section(group.name) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                        ForEach(group.themes, id: \.name) { t in
                            Button { apply(t) } label: { swatch(t) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                Picker("Style", selection: $useGradient) {
                    Text("One colour").tag(false)
                    Text("Gradient").tag(true)
                }
                .pickerStyle(.segmented)
                if useGradient {
                    ColorPicker("Top", selection: $stops[0], supportsOpacity: false)
                    if threeStops { ColorPicker("Middle", selection: $stops[1], supportsOpacity: false) }
                    ColorPicker("Bottom", selection: $stops[2], supportsOpacity: false)
                    Toggle("Three colours", isOn: $threeStops)
                    Picker("Direction", selection: $direction) {
                        ForEach(AppTheme.Direction.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } else {
                    ColorPicker("Colour", selection: $solid, supportsOpacity: false)
                }
            } header: {
                Text("Background")
            }

            Section {
                ColorPicker("Accent", selection: $accent, supportsOpacity: false)
            } header: {
                Text("Accent")
            } footer: {
                Text("Chips, buttons, links and the selection colour.")
            }

            Section {
                Picker("Typeface", selection: $font) {
                    ForEach(AppTheme.FontChoice.allCases, id: \.self) { f in
                        Text(f.title).font(AppTheme(name: "", background: theme.background, accent: theme.accent, typeface: f, light: light).font(.body)).tag(f)
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Typeface")
            } footer: {
                Text("System, Rounded, Serif and Monospaced change every label in the app. The other families go on titles, the filter chips and plain text; the app's smaller labels keep the system font so they stay readable.")
            }

            Section {
                Toggle("Light", isOn: $light)
            } header: {
                Text("Chrome")
            } footer: {
                Text("Dark text and light panels — for pale backgrounds such as Paper and Snow Day. Dark suits everything else; the photo viewer is always black.")
            }

            Section {
                Button("Reset to Photo Browser") { apply(.standard) }
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load(theme) }
        .onChange(of: useGradient) { commit() }
        .onChange(of: threeStops) { commit() }
        .onChange(of: stops) { commit() }
        .onChange(of: solid) { commit() }
        .onChange(of: direction) { commit() }
        .onChange(of: accent) { commit() }
        .onChange(of: font) { commit() }
        .onChange(of: light) { commit() }
    }

    // MARK: - Preview and swatches

    private var preview: some View {
        ZStack {
            theme.backgroundView
            VStack(alignment: .leading, spacing: 12) {
                Text(theme.name).font(theme.font(.title3, weight: .semibold))
                HStack(spacing: 8) {
                    chip("Favorites", on: true)
                    chip("Type", on: false)
                    chip("Sort", on: false)
                }
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.accentColor.opacity(i == 1 ? 0.9 : 0.25))
                            .frame(height: 44)
                    }
                }
                Text("1,284 items · 12 folders").font(theme.font(.caption)).opacity(0.7)
            }
            .padding(16)
        }
        .foregroundStyle(theme.light ? Color.black : Color.white)
        .frame(height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.vertical, 4)
    }

    private func chip(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(theme.font(.subheadline, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(on ? theme.accentColor.opacity(0.35) : (theme.light ? Color.black.opacity(0.08) : Color.white.opacity(0.15)), in: Capsule())
            .foregroundStyle(on ? theme.accentColor : (theme.light ? Color.black : Color.white))
    }

    private func swatch(_ t: AppTheme) -> some View {
        let selected = theme.matchingPreset?.name == t.name
        return VStack(spacing: 6) {
            ZStack {
                t.backgroundView
                Circle().fill(t.accentColor).frame(width: 18, height: 18).offset(x: 24, y: -16)
                Text("Aa").font(t.font(.title3, weight: .semibold)).foregroundStyle(t.light ? Color.black : Color.white).offset(x: -14, y: 10)
            }
            .frame(height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2.5 : 1))
            Text(t.name).font(.caption).lineLimit(1).foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
    }

    // MARK: - Pickers ⇄ theme

    private func load(_ t: AppTheme) {
        loading = true
        switch t.background {
        case .solid(let c):
            useGradient = false; solid = c.color
            stops = [c.color, c.color, c.color]; threeStops = false
        case .gradient(let cs, let dir):
            useGradient = true; direction = dir
            threeStops = cs.count >= 3
            let first = cs.first?.color ?? .black, last = cs.last?.color ?? .black
            stops = [first, cs.count >= 3 ? cs[1].color : first, last]
            solid = first
        }
        accent = t.accent.color
        font = t.typeface
        light = t.light
        DispatchQueue.main.async { loading = false }
    }

    private func apply(_ t: AppTheme) {
        library.setTheme(t)
        load(t)
    }

    private func commit() {
        guard !loading else { return }
        let background: AppTheme.Background = useGradient
            ? .gradient((threeStops ? [stops[0], stops[1], stops[2]] : [stops[0], stops[2]]).map(AppTheme.RGB.init), direction)
            : .solid(AppTheme.RGB(solid))
        var t = AppTheme(name: "Custom", background: background, accent: AppTheme.RGB(accent), typeface: font, light: light)
        if let preset = t.matchingPreset { t.name = preset.name }
        library.setTheme(t)
    }
}
