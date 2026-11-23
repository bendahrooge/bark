import AppKit
import Combine
import SwiftUI
import BarkCore

// Snapshot types for folders, media, feature switches and Space styles.
// Chromium owns the tabs and windows.

struct ChromiumFolder: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    var collapsed: Bool? = nil
    var parent: String? = nil
}

/// The tab playing (or paused in) media while another tab is on screen.
struct ChromiumMedia: Decodable, Equatable {
    let id: Int
    let title: String
    let url: String
    var favicon: String? = nil
    var muted: Bool? = nil
    var customTitle: String? = nil
    let playing: Bool
    var mediaTitle: String? = nil
    var artist: String? = nil
    var space: String? = nil
    var heading: String {
        if let mediaTitle, !mediaTitle.isEmpty { return mediaTitle }
        if let customTitle, !customTitle.isEmpty { return customTitle }
        return title.isEmpty ? (URL(string: url)?.host ?? url) : title
    }
    var detail: String {
        if let artist, !artist.isEmpty { return artist }
        let host = URL(string: url)?.host ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Switches in the Library menu, as Chromium last reported them.
struct ChromiumFeatures: Decodable, Equatable {
    var archiveAfterHours: Int = 12
    var peek: Bool = true
    var littleWindow: Bool = true
    var globalLittleShortcut: Bool?
    var globalLittleShortcutUnavailable: Bool?
    var autoPictureInPicture: Bool = true
}

struct GlobalLittleShortcutSetting: View {
    let features: ChromiumFeatures
    let setEnabled: (Bool) -> Void

    var body: some View {
        Toggle("Open a Little window with ⌥⌘N from any app", isOn: Binding(
            get: { features.globalLittleShortcut == true }, set: setEnabled))
        if features.globalLittleShortcutUnavailable == true {
            Button("⌥⌘N is unavailable. Try again") { setEnabled(true) }
        }
    }
}

/// Normalized positions keep the theme consistent at every sidebar size.
struct SpaceColorPoint: Codable, Equatable {
    var x: Double
    var y: Double

    var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}

struct SpaceGradientCanvas: Codable, Equatable {
    var startColor: String
    var endColor: String
    var start = SpaceColorPoint(x: 0.25, y: 0.30)
    var end = SpaceColorPoint(x: 0.77, y: 0.78)

    static func isColor(_ value: String) -> Bool {
        value.utf8.count == 7 && value.first == "#" && value.dropFirst().allSatisfy { $0.isASCII && $0.isHexDigit }
    }
    var isValid: Bool { Self.isColor(startColor) && Self.isColor(endColor) && start.isValid && end.isValid }
    var json: String? {
        guard isValid, let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// A space's colors and gradient positions.
struct SpaceStyle: Equatable {
    var gradient: SpaceTheme? = nil
    var canvas: SpaceGradientCanvas? = nil
    var metadata: [String: String] {
        // Clear any saved texture when this space is next edited.
        ["gradient": gradient?.rawValue ?? "", "grain": "0", "gradientCanvas": canvas?.json ?? ""]
    }
}

typealias SidebarControlStyle = BarkControlStyle
