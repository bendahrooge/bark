import Foundation

public enum Navigation {
    public static let blank = "bark://newtab"
    public static func isWebURL(_ value: String) -> Bool {
        guard value.count <= 16_384, !value.contains(where: { $0.isWhitespace || $0.asciiValue.map { $0 < 32 } == true }),
              let url = URLComponents(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }

    public static func resolve(_ input: String, engine: SearchEngine = .duckduckgo) -> String {
        let value = String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16_384))
        if value.isEmpty || value == blank { return blank }
        if isWebURL(value) { return value }
        let local = value.range(of: #"^(localhost|127(?:\.\d{1,3}){3}|\[::1\])(?::\d+)?(?:[/?#]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
        let host = value.range(of: #"^(?:[\p{L}\d-]+\.)+[\p{L}\d-]+(?::\d+)?(?:[/?#]|$)"#, options: .regularExpression) != nil
        if !value.contains(where: { $0.isWhitespace }), local || host {
            let candidate = (local ? "http://" : "https://") + value
            if isWebURL(candidate) { return candidate }
        }
        var url = URLComponents(string: engine.searchURL)!
        url.queryItems = [URLQueryItem(name: "q", value: value)]
        return url.string!
    }

    public static func display(_ value: String) -> String {
        if value == blank { return "New tab" }
        guard let url = URLComponents(string: value) else { return value }
        return (url.host ?? value) + (url.path == "/" ? "" : url.path)
    }
}

public enum SearchEngine: String, Codable, CaseIterable, Sendable {
    case duckduckgo, google, bing
    public var searchURL: String {
        switch self {
        case .duckduckgo: return "https://duckduckgo.com/"
        case .google: return "https://www.google.com/search"
        case .bing: return "https://www.bing.com/search"
        }
    }
}
