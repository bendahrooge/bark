import Foundation

public enum SpaceTheme: String, CaseIterable, Sendable {
    case gray, sage, clay, lavender, ocean, rose, amber, mint, slate
}

extension Space {
    public var theme: SpaceTheme { SpaceTheme(rawValue: color) ?? .gray }

    // Keep the existing persisted `icon` field compatible with older profiles.
    public var emoji: String {
        if let emoji = Self.normalizedEmoji(icon) { return emoji }
        return ["leaf": "🍃", "briefcase": "💼", "code": "💻", "terminal": "💻",
                "palette": "🎨", "book": "📚", "heart": "💖", "globe": "🌎",
                "coffee": "☕", "music": "🎧", "sparkles": "✨", "compass": "🧭"][icon] ?? "🍃"
    }

    public static func normalizedEmoji(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Swift Characters preserve joined emoji, flags, and skin-tone sequences.
        guard value.count == 1, value.unicodeScalars.count <= 32,
              value.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x7F })
                || (value.count == 1 && value.unicodeScalars.contains(where: { $0.value == 0x20E3 }))
        else { return nil }
        return value
    }
}
