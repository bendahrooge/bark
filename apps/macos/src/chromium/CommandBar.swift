import AppKit
import Foundation

enum CommandBarSelection {
    static func isActionQuery(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(">")
    }

    /// Normal input still searches/navigates on Enter. An exact action name or
    /// explicit action mode selects a command without needing a mouse.
    static func initialSelection(query: String, suggestions: [AddressSuggestion]) -> Int? {
        if isActionQuery(query) { return suggestions.firstIndex(where: \.isCommand) }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return suggestions.firstIndex { $0.isCommand && $0.title.caseInsensitiveCompare(text) == .orderedSame }
    }
}

@MainActor extension ChromiumSidebarModel {
    func canRunCommandBarAction(_ suggestion: AddressSuggestion) -> Bool {
        guard suggestion.isCommand, suggestion.contextSpace == (snapshot.activeSpaceId ?? ""),
              suggestion.invokerID == (activeTab?.id ?? -1), suggestion.invokerURL == (activeTab?.url ?? "") else { return false }
        let origin = (snapshot.tabs + (snapshot.favorites ?? [])).first { $0.id == suggestion.id }
        guard suggestion.id == (origin?.id ?? -1), suggestion.contextURL == (origin?.url ?? "") else { return false }
        return true
    }

    func performCommandBarAction(_ suggestion: AddressSuggestion) {
        guard canRunCommandBarAction(suggestion), let command = suggestion.commandID else { return }
        switch command {
        case "settings": showPreferences()
        case "archive": showArchive()
        case "newFolder": if !isIncognito { requestNewFolder() }
        default:
            send("commandBarAction", id: suggestion.id, text: command,
                 metadata: ["url": suggestion.contextURL ?? "", "space": suggestion.contextSpace ?? "",
                            "invoker": String(suggestion.invokerID ?? -1), "invokerURL": suggestion.invokerURL ?? ""])
        }
    }
}
