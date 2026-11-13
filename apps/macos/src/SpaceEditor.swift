import AppKit
import SwiftUI
import BarkCore

extension SpaceTheme {
    var label: String { rawValue.capitalized }
    private var colors: (light: UInt32, dark: UInt32, accent: UInt32) {
        switch self {
        case .gray: return (0xE5E5E5, 0x303030, 0x777777)
        case .sage: return (0xDEE7D8, 0x29382D, 0x58764E)
        case .clay: return (0xEBDDD6, 0x3C2D28, 0xA5694F)
        case .lavender: return (0xE2DEF0, 0x332D43, 0x7C68A6)
        case .ocean: return (0xD7E6EE, 0x253844, 0x477E9B)
        case .rose: return (0xF0DBE3, 0x422C36, 0xAB607D)
        case .amber: return (0xF0E5C9, 0x403823, 0x947324)
        case .mint: return (0xD7EAE4, 0x253D36, 0x3D8270)
        case .slate: return (0xE0E4E9, 0x2D333D, 0x64748A)
        }
    }
    var accent: Color { color(colors.accent) }
    func sidebar(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? colors.dark : colors.light) }
    private func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

struct SpaceDraft: Identifiable {
    let id = UUID()
    let space: Space?
    init(_ space: Space? = nil) { self.space = space }
}

struct SpaceProfileChoice: Identifiable {
    let id: String
    let name: String
}

struct SpaceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var name: String
    @State private var emoji: String
    @State private var theme: SpaceTheme
    @Binding private var profileID: String
    private let profiles: [SpaceProfileChoice]
    @FocusState private var focused: Field?
    private enum Field { case name, emoji }
    private let isNew: Bool
    private let originalProfileID: String?
    private let onSave: (String, SpaceTheme, String) -> Void
    private let choices = ["🍃", "💼", "🏡", "💻", "🎨", "📚", "🚀", "🌎", "🎧", "🎮", "💡", "🔬", "✨", "🧠", "☕", "🏖️"]

    init(draft: SpaceDraft, profiles: [SpaceProfileChoice] = [], profileID: Binding<String> = .constant(""),
         originalProfileID: String? = nil, onSave: @escaping (String, SpaceTheme, String) -> Void) {
        self.originalProfileID = originalProfileID
        _name = State(initialValue: draft.space?.name ?? "")
        _emoji = State(initialValue: draft.space?.emoji ?? "🍃")
        _theme = State(initialValue: draft.space?.theme ?? .gray)
        isNew = draft.space == nil
        self.onSave = onSave
        self.profiles = profiles
        _profileID = profileID
    }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Space.normalizedEmoji(emoji) != nil
    }
    private func save() {
        guard canSave, let emoji = Space.normalizedEmoji(emoji) else { return }
        onSave(name, theme, emoji)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "New space" : "Space settings").font(.headline)
            HStack(spacing: 12) {
                Text(Space.normalizedEmoji(emoji) ?? "🍃").font(.system(size: 28))
                Text(name.isEmpty ? "Space" : name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
            }.padding(16).background(theme.sidebar(scheme), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
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
                Text("Color").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(SpaceTheme.allCases, id: \.self) { choice in
                        Button { theme = choice } label: {
                            Circle().fill(choice.accent).frame(width: 34, height: 34)
                                .overlay { if theme == choice { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) } }
                        }.buttonStyle(.plain).help(choice.label)
                            .accessibilityLabel(choice.label + " theme").accessibilityValue(theme == choice ? "Selected" : "")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Emoji").font(.subheadline).foregroundStyle(.secondary)
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
                            Text(choice).font(.system(size: 21)).frame(maxWidth: .infinity).frame(height: 36)
                                .background(emoji == choice ? theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(choice + " emoji").accessibilityValue(emoji == choice ? "Selected" : "")
                    }
                }
                if Space.normalizedEmoji(emoji) == nil { Text("Choose one emoji.").font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Create" : "Save", action: save).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }.padding(24).frame(width: 420).onAppear { DispatchQueue.main.async { focused = .name } }
    }
}
