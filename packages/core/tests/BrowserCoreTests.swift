import XCTest
@testable import BarkCore

final class BrowserCoreTests: XCTestCase {
    func testAppearanceDefaultsAndSavedChoices() throws {
        XCTAssertEqual(BrowserState().settings.theme, "system")
        XCTAssertEqual(try JSONDecoder().decode(BrowserState.self, from: Data("{}".utf8)).settings.theme, "system")
        for choice in ["light", "dark", "system"] {
            var original = BrowserState(); original.settings.theme = choice
            var restored = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(original))
            restored.validateForRestore()
            XCTAssertEqual(restored.settings.theme, choice)
        }
        var invalid = BrowserState(); invalid.settings.theme = "invalid"
        invalid.validateForRestore()
        XCTAssertEqual(invalid.settings.theme, "system")
    }
    func testURLPolicy() {
        XCTAssertEqual(Navigation.resolve(""), Navigation.blank)
        XCTAssertEqual(Navigation.resolve("example.com/path"), "https://example.com/path")
        XCTAssertEqual(Navigation.resolve("localhost:8080/page"), "http://localhost:8080/page")
        XCTAssertEqual(Navigation.resolve("[::1]:8080"), "http://[::1]:8080")
        for unsafe in ["javascript:alert(1)", "file:///etc/passwd", "https://user:secret@example.com", "data:text/html,test"] {
            XCTAssertFalse(Navigation.isWebURL(unsafe))
            XCTAssertTrue(Navigation.resolve(unsafe).hasPrefix("https://duckduckgo.com/?q="))
        }
        XCTAssertEqual(URLComponents(string: Navigation.resolve("a & b + c"))?.queryItems?.first?.value, "a & b + c")
    }
    func testSpacesPinsCloseAndReopen() {
        var state = BrowserState()
        let first = state.newTab("example.com")!
        state.togglePin(first)
        let second = state.newTab("apple.com")!
        state.closeTab(second)
        XCTAssertEqual(state.activeTab?.id, first)
        state.reopenTab()
        XCTAssertEqual(state.activeTab?.url, "https://apple.com")
        XCTAssertNotEqual(state.activeTab?.id, second)
        state.addSpace(name: "Research")
        XCTAssertNil(state.activeTab)
        XCTAssertEqual(state.activeSpace.emoji, "", "A new space has no icon until one is chosen")
        XCTAssertEqual(Space.normalizedIcon(" "), "")
        XCTAssertEqual(Space.normalizedIcon("🔬"), "🔬")
        XCTAssertNil(Space.normalizedIcon("ab"))
        _ = state.newTab("swift.org")
        state.deleteSpace(state.activeSpaceId)
        XCTAssertEqual(state.activeSpaceId, "personal")
        XCTAssertEqual(state.tabs.count, 2)
    }
    func testRestorationRejectsUnsafeDataAndInvalidIDs() throws {
        var state = BrowserState()
        state.spaces.append(Space(id: "../outside", name: "Invalid"))
        state.tabs = [Tab(spaceId: "personal", url: "javascript:alert(1)"), Tab(spaceId: "missing", url: "https://example.com"), Tab(spaceId: "personal", url: "https://safe.example", pinned: true)]
        state.activeSpaceId = "missing"
        state.activeTabs = ["personal": "missing"]
        state.validateForRestore()
        XCTAssertEqual(state.spaces.count, 2)
        XCTAssertEqual(state.tabs.count, 1)
        XCTAssertEqual(state.activeTab?.url, "https://safe.example")
    }
    func testPersistenceAndLegacyShape() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("bark-state.json")
        var state = BrowserState()
        let tab = state.newTab("example.com")!
        state.togglePin(tab); state.visit(tab)
        try StateFile.write(state, to: file)
        XCTAssertEqual(try StateFile.read(file), state)
        // Electron's version-1 state includes extra download/transient fields.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        json["downloads"] = []; json["extraLegacyField"] = true
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        XCTAssertEqual(try StateFile.read(file), state)
    }
    func testRestoreSettingRetainsPinsAndHistoryDeduplicates() {
        var state = BrowserState()
        let pinned = state.newTab("example.com")!
        state.togglePin(pinned); state.visit(pinned); state.visit(pinned)
        _ = state.newTab("swift.org")
        state.settings.restoreSession = false
        state.validateForRestore()
        XCTAssertEqual(state.tabs.map(\.id), [pinned])
        XCTAssertEqual(state.history.count, 1)
    }
    func testReorderingCannotCrossSpaceOrPinBoundary() {
        var state = BrowserState()
        let first = state.newTab("one.example")!
        let second = state.newTab("two.example")!
        state.reorder(second, before: first)
        XCTAssertEqual(state.tabs.first?.id, second)
        state.togglePin(first)
        state.reorder(first, before: second)
        XCTAssertEqual(state.tabs.first?.id, second)
    }
}
