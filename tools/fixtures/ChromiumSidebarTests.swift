import AppKit
import Foundation

private final class Commands {
    var messages: [[String: Any]] = []
}

@main struct ChromiumSidebarTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let commands = Commands()
        let context = Unmanaged.passUnretained(commands).toOpaque()
        let callback: ChromiumCommand = { pointer, text in
            guard let pointer, let text,
                  let data = String(cString: text).data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            Unmanaged<Commands>.fromOpaque(pointer).takeUnretainedValue().messages.append(message)
        }
        let model = ChromiumSidebarModel(context: context, callback: callback)
        let first = #"{"tabs":[{"id":41,"title":"Page A","url":"https://example.test/a","active":true,"pinned":true,"loading":false}],"spaces":[],"profile":"/temporary/bark-bridge-test","canGoBack":false,"canGoForward":false}"#
        model.update(first)
        precondition(model.snapshot.tabs.first?.id == 41 && model.address == "https://example.test/a")
        precondition(model.addressSummary == "example.test", "The resting address displays the origin")
        model.address = "https://www.example.test:8443/path?q=1"
        precondition(model.addressSummary == "example.test:8443", "Nondefault ports remain visible")
        model.editingAddress = true
        model.address = "my unfinished query"
        model.update(first.replacingOccurrences(of: "Page A", with: "Updated title"))
        precondition(model.address == "my unfinished query", "A page title event must not erase an in-progress address")
        model.update(first.replacingOccurrences(of: "41", with: "99"))
        precondition(model.address == "https://example.test/a", "Changing the active tab must update the address")
        model.update("{malformed}")
        precondition(model.snapshot.tabs.first?.id == 99, "Malformed snapshots must not clear real tabs")
        model.send("close", id: 99)
        precondition(commands.messages.last?["id"] as? Int == 99)
        precondition(commands.messages.last?["action"] as? String == "close")
        model.send("navigate", text: "https://example.test/\"a\"?q=🍃")
        precondition(commands.messages.last?["text"] as? String == "https://example.test/\"a\"?q=🍃", "C ABI JSON must preserve Unicode and quoting")
        model.update(first.replacingOccurrences(of: "https://example.test/a", with: "about:blank"))
        model.address = "an abandoned search"
        model.cancelAddressEditing()
        precondition(model.address.isEmpty && !model.editingAddress, "Escape on a blank tab must restore an empty address")
        model.update(first.replacingOccurrences(of: "https://example.test/a", with: "chrome://newtab/"))
        precondition(model.address.isEmpty && model.snapshot.tabs.first?.isBlank == true,
                     "Native new-tab URLs must also display as a blank Bark tab")
        let collapsed = first.dropLast() + #","sidebarCollapsed":true,"sidebarRevealed":false,"sidebarWidth":320}"#
        model.update(String(collapsed))
        precondition(model.snapshot.sidebarCollapsed == true && model.snapshot.sidebarWidth == 320)
        model.update(first)
        precondition(model.snapshot.sidebarCollapsed == nil, "Older snapshots remain compatible")
        precondition(!model.isIncognito, "Older snapshots default to ordinary browsing")
        let privateSnapshot = first.dropLast() + #","incognito":true}"#
        // Incognito and its parent can share a profile path. Switching mode
        // must still reset the projection without writing parent preferences.
        model.update(String(privateSnapshot))
        precondition(model.isIncognito && model.activeSpaceName == "Incognito" && model.emoji.isEmpty)
        let themeBefore = model.theme
        model.customize(theme: .ocean, emoji: "🚀")
        precondition(model.theme == themeBefore && model.emoji.isEmpty,
                     "Private-window customization must not mutate a persistent space")
        let privateCommandCount = commands.messages.count
        for action in ["space", "createSpace", "deleteSpace", "manageSpaces", "moveTabToSpace", "createProfile", "customizeSpace", "appearance"] { model.send(action, text: "private test") }
        precondition(commands.messages.count == privateCommandCount,
                     "Private windows cannot send commands that edit or open persistent spaces")
        model.send("new")
        precondition(commands.messages.last?["action"] as? String == "new",
                     "Private tab commands still reach the real Chromium tab strip")
        model.update(first)
        precondition(!model.isIncognito && model.activeSpaceName == "Personal",
                     "Returning to a regular snapshot restores ordinary space presentation")
        let spaces = #"{"tabs":[],"spaces":[{"id":"research","name":"Research","active":true,"profile":"Default","theme":"ocean","emoji":"🔬"},{"id":"reading","name":"Reading","active":false,"profile":"Default","theme":"lavender","emoji":"📚"}],"profiles":[{"id":"Default","name":"Personal"}],"profile":"/temporary/bark-bridge-test","profileId":"Default","activeSpaceId":"research","canGoBack":false,"canGoForward":false}"#
        model.update(spaces)
        precondition(model.activeSpaceName == "Research" && model.activeProfileName == "Personal",
                     "Spaces have their own names and IDs independent of their shared profile")
        precondition(model.theme == .ocean && model.emoji == "🔬" && model.emoji(for: model.snapshot.spaces[1]) == "📚",
                     "Space appearance comes from catalog metadata, including inactive dock items")
        model.update(spaces.replacingOccurrences(of: #""active":true"#, with: #""active":TEMP"#)
            .replacingOccurrences(of: #""active":false"#, with: #""active":true"#)
            .replacingOccurrences(of: #""active":TEMP"#, with: #""active":false"#)
            .replacingOccurrences(of: #""activeSpaceId":"research""#, with: #""activeSpaceId":"reading""#))
        precondition(model.theme == .lavender && model.emoji == "📚" && model.activeProfileName == "Personal",
                     "Switching spaces in one profile updates its theme and emoji")
        model.customize(theme: .gray, emoji: "🌿")
        precondition(commands.messages.last?["action"] as? String == "customizeSpace" &&
                     (commands.messages.last?["metadata"] as? [String: String])?["emoji"] == "🌿",
                     "Catalog customization goes through the native bridge instead of profile preferences")
        precondition(model.canDelete(model.snapshot.spaces[0]) && model.moveTargets.map(\.id) == ["research"],
                     "A profile with two spaces can delete one and move tabs to the other")
        model.update(#"{"tabs":[{"id":7,"title":"Song","url":"https://example.test/song","active":true,"pinned":false,"loading":true,"audible":true,"muted":false}],"spaces":[{"id":"research","name":"Research","active":true,"profile":"Default"}],"profiles":[{"id":"Default","name":"Personal"}],"profile":"/temporary/bark-bridge-test","profileId":"Default","activeSpaceId":"research","canGoBack":false,"canGoForward":false}"#)
        precondition(model.snapshot.tabs[0].audible == true && model.snapshot.tabs[0].muted == false && model.activeTabLoading,
                     "Audio and loading state reach the tab row and the Stop control")
        precondition(!model.canDelete(model.snapshot.spaces[0]) && model.moveTargets.isEmpty,
                     "A profile's last space cannot be deleted")
        model.shutdown()
        let count = commands.messages.count
        model.send("new")
        precondition(commands.messages.count == count, "A detached sidebar must never call its destroyed C++ controller")
        let handle = barkSwiftSidebarCreate(context, callback)
        first.withCString { barkSwiftSidebarUpdate(handle, $0) }
        precondition(Unmanaged<AnyObject>.fromOpaque(handle).takeUnretainedValue() is NSView)
        let header = barkSwiftSidebarHeaderCreate(handle)
        precondition(Unmanaged<AnyObject>.fromOpaque(header).takeUnretainedValue() is NSView)
        barkSwiftSidebarHeaderDestroy(header)
        barkSwiftSidebarDestroy(handle)
        print("29 Swift/Chromium bridge checks passed")
    }
}
