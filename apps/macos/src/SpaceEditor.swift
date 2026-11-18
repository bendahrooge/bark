import AppKit
import SwiftUI
import BarkCore

extension SpaceTheme {
    var label: String { rawValue.capitalized }
    private var colors: (light: UInt32, dark: UInt32, accent: UInt32) {
        switch self {
        case .gray: return (0xE5E5E5, 0x303030, 0x777777)
        case .sage: return (0xC8EBC0, 0x285B32, 0x5CC445)
        case .clay: return (0xFFD0B9, 0x823D2B, 0xE46D3D)
        case .lavender: return (0xD5C4FF, 0x4E3192, 0x9758F6)
        case .ocean: return (0xB6DFFF, 0x164D88, 0x1687F5)
        case .rose: return (0xFFBDDA, 0x872F5D, 0xEC4C94)
        case .amber: return (0xFFE09A, 0x70501A, 0xE9A51C)
        case .mint: return (0xAEECD8, 0x155D50, 0x15BD99)
        case .slate: return (0xBCD0F1, 0x2C4770, 0x628DE0)
        }
    }
    var accent: Color { color(colors.accent) }
    var accentHex: String { String(format: "#%06X", colors.accent) }
    func sidebar(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? colors.dark : colors.light) }
    private func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

struct SpaceDraft: Identifiable {
    let id = UUID()
    let space: Space?
    let style: SpaceStyle
    init(_ space: Space? = nil, style: SpaceStyle = SpaceStyle()) { self.space = space; self.style = style }
}

struct SpaceProfileChoice: Identifiable {
    let id: String
    let name: String
}

struct SpaceIcon: View {
    let emoji: String
    /// The color of the dot shown when no icon is chosen, usually the space's own.
    var tint: Color? = nil
    var body: some View {
        if emoji == "👤" { Image(systemName: "person.fill") }
        // No chosen icon: a dot that scales with the surrounding font.
        else if emoji.isEmpty {
            if let tint { Image(systemName: "circle.fill").scaleEffect(0.5).foregroundStyle(tint) }
            else { Image(systemName: "circle.fill").scaleEffect(0.5) }
        }
        else { Text(emoji) }
    }
}

extension SpaceStyle {
    /// Existing named presets pick up palette refinements; custom colors and
    /// layouts retain their exact saved values.
    var themeCanvas: SpaceGradientCanvas? { SpaceThemePreset.matching(self)?.canvas ?? canvas }

    /// The sidebar color: one theme, or a gradient into a second.
    func fill(_ theme: SpaceTheme, _ scheme: ColorScheme) -> LinearGradient {
        LinearGradient(colors: [theme.sidebar(scheme), (gradient ?? theme).sidebar(scheme)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension SpaceGradientCanvas {
    static func color(_ hex: String) -> Color { Color(nsColor: nsColor(hex)) }
    static func nsColor(_ hex: String) -> NSColor {
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0x777777
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    static func hex(_ color: Color) -> String {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
    static func closestTheme(to hex: String) -> SpaceTheme {
        let color = nsColor(hex)
        func distance(_ theme: SpaceTheme) -> CGFloat {
            let other = nsColor(theme.accentHex)
            return pow(color.redComponent - other.redComponent, 2) + pow(color.greenComponent - other.greenComponent, 2)
                + pow(color.blueComponent - other.blueComponent, 2)
        }
        return SpaceTheme.allCases.min { distance($0) < distance($1) } ?? .gray
    }
}

/// Shared by the editor, caption backdrop, sidebar and page frame.
struct SpaceThemeSurface: View {
    let theme: SpaceTheme
    let style: SpaceStyle
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let canvas = style.themeCanvas, canvas.isValid {
            Canvas { context, size in
                guard size.width > 0, size.height > 0 else { return }
                var context = context
                context.scaleBy(x: size.width, y: size.height)
                let rect = Path(CGRect(x: 0, y: 0, width: 1, height: 1))
                func tint(_ hex: String) -> Color {
                    // Adjust brightness for readable labels without mixing in
                    // a gray material color that drains the chosen hue.
                    let base = scheme == .dark ? NSColor.black : NSColor.white
                    return Color(nsColor: SpaceGradientCanvas.nsColor(hex)
                        .blended(withFraction: scheme == .dark ? 0.35 : 0.48, of: base) ?? base)
                }
                // Matching colors are a true solid fill, without radial halos.
                if canvas.startColor.lowercased() == canvas.endColor.lowercased() {
                    context.fill(rect, with: .color(tint(canvas.startColor)))
                } else {
                    // Carry both colors across the entire surface instead of
                    // fading them into a neutral undercoat at the edges.
                    context.fill(rect, with: .linearGradient(Gradient(colors: [tint(canvas.startColor), tint(canvas.endColor)]),
                        startPoint: CGPoint(x: canvas.start.x, y: canvas.start.y),
                        endPoint: CGPoint(x: canvas.end.x, y: canvas.end.y)))
                }
            }
        } else {
            Rectangle().fill(style.fill(theme, scheme))
        }
    }
}

/// Recognize presets from their saved appearance so custom edits never leave
/// an outdated preset name selected, and no extra persistence field is needed.
enum SpaceThemePreset: String, CaseIterable, Identifiable {
    case ocean = "Ocean", sunset = "Sunset", forest = "Forest", midnight = "Midnight"
    case aurora = "Aurora", ember = "Ember"
    case cobalt = "Cobalt", teal = "Teal", violet = "Violet", rose = "Rose", amber = "Amber", graphite = "Graphite"

    enum Kind: String, CaseIterable {
        case gradient = "Gradients", solid = "Solid colors"
    }
    var kind: Kind { canvas.startColor == canvas.endColor ? .solid : .gradient }
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .ocean: return "water.waves"
        case .sunset: return "sunset"
        case .forest: return "tree"
        case .midnight: return "moon"
        case .aurora: return "sparkles"
        case .ember: return "flame"
        case .cobalt, .teal, .violet, .rose, .amber, .graphite: return "circle.fill"
        }
    }
    var canvas: SpaceGradientCanvas {
        switch self {
        case .ocean: return SpaceGradientCanvas(startColor: "#1687F5", endColor: "#15BDCC")
        case .sunset: return SpaceGradientCanvas(startColor: "#F4478D", endColor: "#F6A62D")
        case .forest: return SpaceGradientCanvas(startColor: "#5CC445", endColor: "#0CA67C")
        case .midnight: return SpaceGradientCanvas(startColor: "#3C4BDD", endColor: "#A044F2")
        case .aurora: return SpaceGradientCanvas(startColor: "#13D6B0", endColor: "#7855F6")
        case .ember: return SpaceGradientCanvas(startColor: "#FF9A32", endColor: "#ED415B")
        case .cobalt: return SpaceGradientCanvas(startColor: "#2875F5", endColor: "#2875F5")
        case .teal: return SpaceGradientCanvas(startColor: "#13B8A6", endColor: "#13B8A6")
        case .violet: return SpaceGradientCanvas(startColor: "#9758F6", endColor: "#9758F6")
        case .rose: return SpaceGradientCanvas(startColor: "#EC4C94", endColor: "#EC4C94")
        case .amber: return SpaceGradientCanvas(startColor: "#E9A51C", endColor: "#E9A51C")
        case .graphite: return SpaceGradientCanvas(startColor: "#64748B", endColor: "#64748B")
        }
    }
    private var originalCanvas: SpaceGradientCanvas? {
        switch self {
        case .ocean: return SpaceGradientCanvas(startColor: "#477E9B", endColor: "#3D8270")
        case .sunset: return SpaceGradientCanvas(startColor: "#AB607D", endColor: "#BD8A48")
        case .forest: return SpaceGradientCanvas(startColor: "#58764E", endColor: "#3D8270")
        case .midnight: return SpaceGradientCanvas(startColor: "#454B79", endColor: "#7C68A6")
        default: return nil
        }
    }
    var theme: SpaceTheme { SpaceGradientCanvas.closestTheme(to: canvas.startColor) }
    var style: SpaceStyle {
        SpaceStyle(gradient: kind == .solid ? nil : SpaceGradientCanvas.closestTheme(to: canvas.endColor), canvas: canvas)
    }
    static func matching(_ style: SpaceStyle) -> Self? {
        guard let canvas = style.canvas else { return nil }
        return allCases.first { preset in
            [preset.canvas, preset.originalCanvas].compactMap { $0 }.contains { expected in
                canvas.startColor.uppercased() == expected.startColor && canvas.endColor.uppercased() == expected.endColor &&
                    canvas.start == expected.start && canvas.end == expected.end
            }
        }
    }
}

/// An in-sheet color chooser avoids sending focus to a separate system panel.
private struct SpaceColorControl: View {
    let label: String
    @Binding var hex: String
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            HStack(spacing: 10) {
                Circle().fill(SpaceGradientCanvas.color(hex)).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 13, weight: .medium))
                    Text(hex.uppercased()).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }.padding(10).frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityValue(hex)
            .popover(isPresented: $presented) { SpaceColorChooser(hex: $hex).padding(16).frame(width: 300) }
    }
}

private struct SpaceColorChooser: View {
    @Binding var hex: String
    @State private var hue: Double
    @State private var saturation: Double
    @State private var brightness: Double
    @State private var text: String

    init(hex: Binding<String>) {
        _hex = hex
        let color = SpaceGradientCanvas.nsColor(hex.wrappedValue)
        _hue = State(initialValue: color.hueComponent)
        _saturation = State(initialValue: color.saturationComponent)
        _brightness = State(initialValue: color.brightnessComponent)
        _text = State(initialValue: hex.wrappedValue)
    }
    private func apply() {
        hex = SpaceGradientCanvas.hex(Color(hue: hue, saturation: saturation, brightness: brightness))
        text = hex
    }
    private func choose(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.hasPrefix("#") ? trimmed : "#" + trimmed
        guard SpaceGradientCanvas.isColor(candidate) else { return }
        let color = SpaceGradientCanvas.nsColor(candidate)
        hue = color.hueComponent; saturation = color.saturationComponent; brightness = color.brightnessComponent
        hex = candidate.uppercased(); text = hex
    }
    private func move(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: saturation = max(0, saturation - 0.03)
        case .right: saturation = min(1, saturation + 0.03)
        case .up: brightness = min(1, brightness + 0.03)
        case .down: brightness = max(0, brightness - 0.03)
        default: return
        }
        apply()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geometry in
                ZStack {
                    Color(hue: hue, saturation: 1, brightness: 1)
                    LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                    Circle().strokeBorder(.white, lineWidth: 2).background(Circle().stroke(.black.opacity(0.65), lineWidth: 4))
                        .frame(width: 14, height: 14)
                        .position(x: max(7, min(geometry.size.width - 7, saturation * geometry.size.width)),
                                  y: max(7, min(geometry.size.height - 7, (1 - brightness) * geometry.size.height)))
                        .allowsHitTesting(false)
                }.clipShape(RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        saturation = min(1, max(0, value.location.x / geometry.size.width))
                        brightness = min(1, max(0, 1 - value.location.y / geometry.size.height))
                        apply()
                    })
                    .focusable().onMoveCommand(perform: move)
                    .accessibilityElement(children: .ignore).accessibilityLabel("Saturation and brightness")
                    .accessibilityValue("\(Int(saturation * 100)) percent saturated, \(Int(brightness * 100)) percent bright")
                    .accessibilityAction(named: "More saturated") { move(.right) }
                    .accessibilityAction(named: "Less saturated") { move(.left) }
                    .accessibilityAction(named: "Brighter") { move(.up) }
                    .accessibilityAction(named: "Darker") { move(.down) }
            }.frame(height: 150)
            HStack(spacing: 10) {
                Text("Hue").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { hue }, set: { hue = $0; apply() }), in: 0...1)
                    .accessibilityLabel("Hue")
            }
            HStack {
                Text("Hex").font(.caption).foregroundStyle(.secondary)
                TextField("#RRGGBB", text: Binding(get: { text }, set: { value in
                    text = value
                    choose(value)
                }))
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                .accessibilityLabel("Hex color")
                .onSubmit { choose(text) }
            }
            Divider()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(SpaceTheme.allCases, id: \.self) { theme in
                    Button { choose(theme.accentHex) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(theme.accent).frame(width: 14, height: 14)
                            Text(theme.label).font(.system(size: 11))
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 5).frame(height: 32)
                            .background(hex.uppercased() == theme.accentHex ? Color.primary.opacity(0.08) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(theme.label)
                }
            }
        }
    }
}

struct SpaceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var emoji: String
    @State private var theme: SpaceTheme
    @State private var gradient: SpaceTheme?
    @State private var canvas: SpaceGradientCanvas
    @State private var usesCanvas: Bool
    @State private var section: Section
    @State private var presetKind: SpaceThemePreset.Kind
    @State private var customizeExpanded = false
    @Binding private var profileID: String
    private let profiles: [SpaceProfileChoice]
    @FocusState private var focused: Field?
    private enum Field { case name, emoji }
    private enum Section: String, CaseIterable { case theme = "Theme", details = "Space details" }
    private let isNew: Bool
    private let originalProfileID: String?
    private let onSave: (String, SpaceTheme, String, SpaceStyle) -> Void
    private let choices = ["", "👤", "🍃", "💼", "🏡", "💻", "🎨", "📚", "🚀", "🌎", "🎧", "🎮", "💡", "🔬", "✨", "🧠", "☕", "🏖️"]

    init(draft: SpaceDraft, profiles: [SpaceProfileChoice] = [], profileID: Binding<String> = .constant(""),
         originalProfileID: String? = nil, onSave: @escaping (String, SpaceTheme, String, SpaceStyle) -> Void) {
        self.originalProfileID = originalProfileID
        let preset = SpaceThemePreset.matching(draft.style)
        let initialStyle = preset?.style ?? draft.style
        _name = State(initialValue: draft.space?.name ?? "")
        _emoji = State(initialValue: draft.space?.emoji ?? "")
        _theme = State(initialValue: preset?.theme ?? draft.space?.theme ?? .gray)
        _gradient = State(initialValue: initialStyle.gradient)
        _canvas = State(initialValue: initialStyle.canvas ?? SpaceGradientCanvas(
            startColor: (draft.space?.theme ?? .gray).accentHex,
            endColor: (draft.style.gradient ?? draft.space?.theme ?? .gray).accentHex))
        _usesCanvas = State(initialValue: initialStyle.canvas != nil)
        let solid = initialStyle.canvas.map { $0.startColor.uppercased() == $0.endColor.uppercased() } ?? (initialStyle.gradient == nil)
        _presetKind = State(initialValue: preset?.kind ?? (solid ? .solid : .gradient))
        _section = State(initialValue: draft.space == nil ? .details : .theme)
        isNew = draft.space == nil
        self.onSave = onSave
        self.profiles = profiles
        _profileID = profileID
    }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Space.normalizedIcon(emoji) != nil
    }
    private func save() {
        guard canSave, let emoji = Space.normalizedIcon(emoji) else { return }
        onSave(name, theme, emoji, currentStyle)
    }
    private var currentStyle: SpaceStyle {
        SpaceStyle(gradient: gradient == theme ? nil : gradient, canvas: usesCanvas ? canvas : nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                SpaceIcon(emoji: Space.normalizedIcon(emoji) ?? "", tint: theme.accent)
                    .font(.system(size: 21)).frame(width: 38, height: 38)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? "Your space" : name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(isNew ? "New space" : "Space settings").font(.headline)
                }
                Spacer()
            }
            Picker("Space settings section", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            if section == .theme { themeControls } else { spaceDetails }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Create" : "Save", action: save).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }.padding(24).frame(width: 420)
            .onAppear { if isNew { DispatchQueue.main.async { focused = .name } } }
            .onChange(of: section) { if $0 == .details { focused = .name } else { focused = nil } }
    }

    private var themeControls: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .topLeading) {
                SpaceThemeSurface(theme: theme, style: currentStyle)
                previewContents.padding(14).accessibilityHidden(true)
            }
            .frame(height: 156)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sidebar theme preview")
            .accessibilityValue(SpaceThemePreset.matching(currentStyle)?.rawValue ?? "Custom theme")
            Picker("Preset style", selection: $presetKind) {
                ForEach(SpaceThemePreset.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(SpaceThemePreset.allCases.filter { $0.kind == presetKind }) { preset in presetButton(preset) }
            }
            if presetKind == .solid {
                SpaceColorControl(label: "Custom color", hex: Binding(get: { canvas.startColor }, set: { hex in
                    canvas = SpaceGradientCanvas(startColor: hex, endColor: hex)
                    theme = SpaceGradientCanvas.closestTheme(to: hex)
                    gradient = nil
                    usesCanvas = true
                }))
            } else {
                DisclosureGroup("Customize…", isExpanded: $customizeExpanded) {
                    HStack(spacing: 12) {
                        colorControl("Start color", keyPath: \.startColor)
                        colorControl("End color", keyPath: \.endColor)
                    }.padding(.top, 8)
                }.font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func presetButton(_ preset: SpaceThemePreset) -> some View {
        let selected = SpaceThemePreset.matching(currentStyle) == preset
        return Button {
            canvas = preset.canvas
            theme = preset.theme
            gradient = preset.style.gradient
            usesCanvas = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: preset.symbol).font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9)).opacity(preset.kind == .solid ? 0 : 1)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(LinearGradient(colors: [SpaceGradientCanvas.color(preset.canvas.startColor),
                                                       SpaceGradientCanvas.color(preset.canvas.endColor)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Text(preset.rawValue).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).opacity(selected ? 1 : 0)
                }.padding(.horizontal, 4).padding(.bottom, 3)
            }.padding(5)
                .background(Color.primary.opacity(selected ? 0.055 : 0.02), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(selected ? 0.65 : 0.12), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityLabel(preset.rawValue + " theme")
            .accessibilityValue(selected ? "Selected" : "")
    }

    private var previewContents: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                ForEach(0..<3) { _ in Circle().fill(Color.primary.opacity(0.3)).frame(width: 7, height: 7) }
                Image(systemName: "sidebar.left").padding(.leading, 5)
                Spacer()
                Image(systemName: "arrow.left").padding(.trailing, 6)
                Image(systemName: "arrow.clockwise")
            }.font(.system(size: 12)).foregroundStyle(.secondary)
            HStack { Text("bark.design"); Spacer(); Image(systemName: "slider.horizontal.3") }
                .font(.system(size: 12)).padding(8)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            Label("Design notes", systemImage: "doc.text").font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            Label("Reading list", systemImage: "folder").font(.system(size: 12)).padding(.horizontal, 8)
        }
    }

    private func colorControl(_ label: String, keyPath: WritableKeyPath<SpaceGradientCanvas, String>) -> some View {
        SpaceColorControl(label: label, hex: Binding(get: { canvas[keyPath: keyPath] }, set: {
            canvas[keyPath: keyPath] = $0
            usesCanvas = true
            theme = SpaceGradientCanvas.closestTheme(to: canvas.startColor)
            gradient = SpaceGradientCanvas.closestTheme(to: canvas.endColor)
        }))
    }

    private var spaceDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Name").font(.subheadline).foregroundStyle(.secondary)
                TextField("Space name", text: $name).textFieldStyle(.roundedBorder).focused($focused, equals: .name)
                    .onChange(of: name) { name = String($0.prefix(32)) }.onSubmit(save)
            }
            VStack(alignment: .leading, spacing: 9) {
                if !profiles.isEmpty {
                    Picker("Profile", selection: $profileID) {
                        ForEach(profiles) { Text($0.name).tag($0.id) }
                    }
                    Text("Spaces using the same profile share sign-ins and extensions.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let originalProfileID, profileID != originalProfileID {
                        Label("This space's tabs will reopen in the new profile. Sign-ins and site data stay with \(profiles.first { $0.id == originalProfileID }?.name ?? "the current profile").",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Icon").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    TextField("Emoji", text: $emoji).textFieldStyle(.roundedBorder).frame(width: 62)
                        .multilineTextAlignment(.center).focused($focused, equals: .emoji).onSubmit(save)
                    Button("More…") {
                        focused = .emoji
                        DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
                    }.help("Choose any emoji")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 6) {
                    ForEach(choices, id: \.self) { choice in
                        Button { emoji = choice } label: {
                            SpaceIcon(emoji: choice).font(.system(size: 21)).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 36)
                                .background(emoji == choice ? theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(choice.isEmpty ? "Dot" : choice + " emoji").accessibilityValue(emoji == choice ? "Selected" : "")
                    }
                }
                if Space.normalizedIcon(emoji) == nil { Text("Choose one emoji, or leave it empty for a dot.").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
