import AppKit
import Foundation

private final class CommandBarTestRecorder { var messages: [[String: Any]] = [] }

@MainActor func checkCommandBar() throws {
    let recorder = CommandBarTestRecorder()
    let model = ChromiumSidebarModel(context: Unmanaged.passUnretained(recorder).toOpaque(), callback: { pointer, text in
        guard let pointer, let text,
              let message = try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8)) as? [String: Any] else { return }
        Unmanaged<CommandBarTestRecorder>.fromOpaque(pointer).takeUnretainedValue().messages.append(message)
    })
    let snapshot = #"{"tabs":[{"id":41,"title":"Origin","url":"https://example.test/a","active":true,"pinned":false,"loading":false},{"id":42,"title":"Other","url":"https://other.test/","active":false,"pinned":false,"loading":false}],"spaces":[{"id":"work","name":"Work","active":true}],"activeSpaceId":"work","profile":"test","canGoBack":false,"canGoForward":false}"#
    model.update(snapshot)
    func action(_ id: String, title: String) throws -> AddressSuggestion {
        let data = try JSONSerialization.data(withJSONObject: ["kind": "command", "title": title, "url": "",
            "commandID": id, "symbol": "pin", "id": 41, "contextURL": "https://example.test/a", "contextSpace": "work",
            "invokerID": 41, "invokerURL": "https://example.test/a"])
        return try JSONDecoder().decode(AddressSuggestion.self, from: data)
    }
    let pin = try action("pin", title: "Pin Tab")
    let first = try action("move:one", title: "Move to One")
    let second = try action("move:two", title: "Move to Two")
    precondition(first.listID != second.listID, "Actions on one tab retain distinct row identities")
    precondition(CommandBarSelection.initialSelection(query: "pin tab", suggestions: [pin]) == 0,
                 "An exact command name can be run with Enter")
    precondition(CommandBarSelection.initialSelection(query: "pin", suggestions: [pin]) == nil &&
                 CommandBarSelection.initialSelection(query: "", suggestions: [pin]) == nil,
                 "Ordinary partial and empty queries do not accidentally execute commands")
    precondition(CommandBarSelection.initialSelection(query: "> pin", suggestions: [pin]) == 0 &&
                 CommandBarSelection.initialSelection(query: "> missing", suggestions: []) == nil,
                 "Action mode selects only available commands")
    model.composeAddress()
    precondition(model.canRunCommandBarAction(pin), "The current page stays available to actions in the composer")
    model.openSuggestion(pin)
    precondition(recorder.messages.last?["action"] as? String == "commandBarAction" &&
                 recorder.messages.last?["id"] as? Int == 41 &&
                 (recorder.messages.last?["metadata"] as? [String: String])?["invoker"] == "41",
                 "The command targets the same page that opened the composer")
    for changed in [snapshot.replacingOccurrences(of: "https://example.test/a", with: "https://example.test/b"),
                    snapshot.replacingOccurrences(of: #""active":true,"pinned""#, with: #""active":false,"pinned""#),
                    snapshot.replacingOccurrences(of: "work", with: "home")] {
        model.update(changed)
        let before = recorder.messages.count
        model.openSuggestion(pin)
        precondition(recorder.messages.count == before, "Navigation and space changes reject stale actions")
    }
    model.update(snapshot)
    model.openSuggestion(try action("newFolder", title: "New Folder"))
    precondition(model.renameNextFolder && recorder.messages.last?["action"] as? String == "newFolder",
                 "New Folder uses the sidebar's existing rename flow")
    model.openSuggestion(try action("archive", title: "Archived Tabs"))
    precondition(model.archivePresented, "Archive opens its native searchable view")
    model.editingAddress = true
    model.address = "> pin"
    model.requestSuggestions(for: model.address)
    let data = try JSONSerialization.data(withJSONObject: ["query": model.address, "action": "command", "items": [
        ["kind": "command", "title": "Pin Tab", "url": "", "commandID": "pin", "symbol": "pin"]]])
    model.updateSuggestions(String(decoding: data, as: UTF8.self))
    precondition(model.selectedSuggestion == 0 && model.addressBarIcon == .command("pin"),
                 "Action selection has its own icon and keyboard focus")
    model.clearSuggestions()
    model.cancelAddressEditing()
    var panelsShown = 0
    model.presentAddressBar = { panelsShown += 1 }
    let before = recorder.messages.count
    model.composeAddress()
    precondition(panelsShown == 1 && model.editingAddress && model.address.isEmpty &&
                 model.sidebarAddress == "https://example.test/a" && model.activeTab?.id == 41)
    model.submitAddress("   \n")
    model.address = "unsubmitted query"
    model.cancelAddressEditing()
    precondition(!model.editingAddress && model.address == "https://example.test/a" && recorder.messages.count == before,
                 "Opening, submitting whitespace, and canceling leave the current page intact")

    model.composeAddress()
    model.submitAddress("new search")
    precondition(recorder.messages.last?["action"] as? String == "navigateNew" && recorder.messages.last?["text"] as? String == "new search")
    let history = try JSONDecoder().decode(AddressSuggestion.self, from: Data(#"{"kind":"history","title":"Visited","url":"https://seen.test/"}"#.utf8))
    model.openSuggestion(history)
    precondition(recorder.messages.last?["action"] as? String == "navigateNew" && recorder.messages.last?["text"] as? String == history.url)
    let open = try JSONDecoder().decode(AddressSuggestion.self, from: Data(#"{"kind":"tab","id":42,"title":"Other","url":"https://other.test/"}"#.utf8))
    model.openSuggestion(open)
    precondition(recorder.messages.last?["action"] as? String == "switchToTab" && recorder.messages.last?["id"] as? Int == 42)
    model.focusAddress()
    precondition(model.address == "https://example.test/a")
    model.submitAddress("https://edit.test/")
    precondition(recorder.messages.last?["action"] as? String == "navigate", "Cmd+L preserves in-place navigation")
    model.shutdown()
}
