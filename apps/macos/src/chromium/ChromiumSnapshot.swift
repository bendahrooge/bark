import AppKit
import Combine
import SwiftUI
import BarkCore

// This model is a projection of Chromium's TabStripModel, never a second tab
// database. Commands use session IDs, not indices that can change under us.
struct ChromiumTab: Decodable, Identifiable {
    let id: Int
    // The tab strip slot survives closing a pinned session. Its new contents
    // receive a new command ID, but the hovered row stays under the pointer.
    var tabHandle: Int? = nil
    var rowID: Int { tabHandle ?? id }
    let title: String
    let url: String
    let pinned: Bool
    let active: Bool
    let loading: Bool
    let favicon: String?
    var faviconValid: Bool? = nil
    // Playing sound now or moments ago, and silenced by the user.
    var audible: Bool? = nil
    var muted: Bool? = nil
    // Chromium's split view: the split this tab belongs to, and whether that
    // split is the one on screen.
    var split: String? = nil
    var splitActive: Bool? = nil
    // A title the person gave the tab, shown instead of the page's.
    var customTitle: String? = nil
    // A pinned tab's own page, and whether the tab has navigated away from it.
    var pinnedURL: String? = nil
    var drifted: Bool? = nil
    var sessionClosed: Bool? = nil
    var keepVisibleAfterClose: Bool? = nil
    var visibleWhenCollapsed: Bool { active || keepVisibleAfterClose == true }
    var closeLabel: String {
        guard pinned else { return "Close tab" }
        return sessionClosed == true ? "Remove pinned tab" : "Close pinned tab session"
    }
    // The sidebar folder of a pinned tab.
    var folder: String? = nil
    // A pin or Favorite of this space that is open in another window (that
    // window's session ID). One live tab can be in only one window, so the
    // row is shown dimmed, and choosing it moves the tab into this window.
    var elsewhere: Int? = nil
    var isElsewhere: Bool { elsewhere != nil }
    // A JPEG of the page, in the Control-Tab switcher only.
    var thumbnail: String? = nil
    // Set by Chromium from the committed entry, even while another URL is loading.
    var blankPlaceholder: Bool? = nil
    var isBlank: Bool {
        if url.isEmpty { return true }
        if url.hasPrefix("about:blank") {
            let page = url.prefix { $0 != "?" && $0 != "#" }
            return page == "about:blank" || page == "about:blank/"
        }
        return url.hasPrefix("chrome://") && URL(string: url)?.host == "newtab"
    }
    var isSidebarPlaceholder: Bool { !pinned && split == nil && (blankPlaceholder ?? isBlank) }
    var pageTitle: String {
        if isBlank { return "New tab" }
        return title.isEmpty ? (URL(string: url)?.host ?? url) : title
    }
    // Chromium may supply its default globe even when the page has no favicon.
    var faviconImage: NSImage? { faviconValid == false ? nil : FaviconCache.image(favicon) }
    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        return pageTitle
    }
    var thumbnailImage: NSImage? { thumbnail.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:)) }
}

/// Decoded favicons by their encoded form. Rows are rebuilt on every snapshot,
/// and decoding each tab's PNG again every time was the costly part.
enum FaviconCache {
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        return cache
    }()
    static func image(_ encoded: String?) -> NSImage? {
        guard let encoded else { return nil }
        let key = encoded as NSString
        if let image = images.object(forKey: key) { return image }
        guard let data = Data(base64Encoded: encoded), data.count <= 262144, let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }
}

struct ChromiumArchivedTab: Decodable {
    let title: String
    let url: String
    var displayTitle: String {
        if !title.isEmpty { return title.count > 60 ? String(title.prefix(59)) + "…" : title }
        return URL(string: url)?.host ?? url
    }
}

struct ChromiumDownloads: Decodable {
    let active: Int
    /// 0–1, or negative when the size of a download is unknown.
    let progress: Double
    /// A download finished in the last 30 seconds.
    let recent: Bool
}

struct ChromiumSpace: Decodable, Identifiable {
    let id: String
    let name: String
    let active: Bool
    var profile: String? = nil
    var theme: String? = nil
    var emoji: String? = nil
    var gradient: String? = nil
    var gradientCanvas: SpaceGradientCanvas? = nil
    var folders: [ChromiumFolder]? = nil
    var pinsCollapsed: Bool? = nil
    var displayName: String { name == "Your Chromium" ? "Personal" : name }
    var style: SpaceStyle {
        SpaceStyle(gradient: gradient.flatMap(SpaceTheme.init(rawValue:)),
                   canvas: gradientCanvas?.isValid == true ? gradientCanvas : nil)
    }
    var themeValue: SpaceTheme { SpaceTheme(rawValue: theme ?? "gray") ?? .gray }
}

struct ChromiumProfile: Decodable, Identifiable {
    let id: String
    let name: String
}

struct ChromiumSnapshot: Decodable {
    let tabs: [ChromiumTab]
    var sidebarTabs: [ChromiumTab] { tabs.filter { !$0.isSidebarPlaceholder } }
    let spaces: [ChromiumSpace]
    let profile: String
    let canGoBack: Bool
    let canGoForward: Bool
    var sidebarCollapsed: Bool? = nil
    var sidebarRevealed: Bool? = nil
    var sidebarWidth: Double? = nil
    var securityLevel: String? = nil
    var securityDescription: String? = nil
    var incognito: Bool? = nil
    var profiles: [ChromiumProfile]? = nil
    var profileId: String? = nil
    var activeSpaceId: String? = nil
    var switchingSpace: Bool? = nil
    // Chromium's color mode: "system", "light", or "dark".
    var appearance: String? = nil
    // Tabs shown in every space of this profile's window, as icons.
    var favorites: [ChromiumTab]? = nil
    // Tabs archived from the active space, most recent first.
    var archivedTabs: [ChromiumArchivedTab]? = nil
    var archiveGeneration: Int? = nil
    var organizationUndoLabel: String? = nil
    var downloads: ChromiumDownloads? = nil
    // False once this profile's window is hidden behind another space's window.
    var windowVisible: Bool? = nil
    // Read-only tabs of the spaces adjacent to the active one, keyed by space ID.
    var spacePreviews: [String: [ChromiumTab]]? = nil
    var browserImportResult: ChromiumBarkImportResult? = nil
    // Media playing in a tab that is not on screen.
    var media: ChromiumMedia? = nil
    var features: ChromiumFeatures? = nil
    var siteControls: ChromiumSiteControls? = nil
    var notices: [ChromiumNotice]? = nil
    var preferences: ChromiumPreferences? = nil
}
