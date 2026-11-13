import XCTest
@testable import BarkCore

final class ArcImportTests: XCTestCase {
    func fixture() throws -> Data {
        func node(_ id: String, _ title: String?, _ payload: [String: Any], _ children: [String] = []) -> [String: Any] {
            ["id": id, "title": title as Any? ?? NSNull(), "data": payload, "childrenIds": children]
        }
        let items: [Any] = [
            "favorites", node("favorites", nil, ["itemContainer": [:]], ["favorite"]),
            "favorite", node("favorite", nil, ["tab": ["savedURL": "https://favorite.example", "savedTitle": "Favorite"]]),
            "pins", node("pins", nil, ["itemContainer": [:]], ["folder"]),
            "folder", node("folder", "Research", ["list": [:]], ["tab", "nested"]),
            "tab", node("tab", "Renamed tab", ["tab": ["savedURL": "https://example.com", "savedTitle": "Original"]]),
            "nested", node("nested", "Nested", ["list": [:]], ["unsafe", "folder"]),
            "unsafe", node("unsafe", "Unsafe", ["tab": ["savedURL": "file:///private/data"]]),
            "today", node("today", nil, ["itemContainer": [:]], ["open"]),
            "open", node("open", "Open", ["tab": ["savedURL": "https://open.example"]])
        ]
        let space: [String: Any] = ["id": "source-space", "title": "Personal research", "profile": ["default": true], "customInfo": ["iconType": ["emoji_v2": "🔬"]], "newContainerIDs": [["pinned": [:]], "pins", ["unpinned": ["_0": ["shared": [:]]]], "today"]]
        let global: [String: Any] = ["items": items, "spaces": ["source-space", space], "topAppsContainerIDs": [["default": true], "favorites"]]
        return try JSONSerialization.data(withJSONObject: ["sidebar": ["containers": [["global": [:]], global, ["standalone": [:]], global]]])
    }
    func testNestedFoldersFavoritesAndUnsafeURLs() throws {
        let plan = try ArcImport.sidebar(fixture())
        XCTAssertEqual(plan.spaces.count, 1, "Standalone windows must not duplicate global spaces")
        let space = try XCTUnwrap(plan.spaces.first)
        XCTAssertEqual(space.space.emoji, "🔬")
        XCTAssertEqual(space.tabs.count, 3)
        XCTAssertEqual(space.tabs.filter(\.pinned).count, 2)
        XCTAssertEqual(space.tabs.first?.title, "Favorite", "Null titles fall back to savedTitle")
        XCTAssertEqual(space.folders.count, 2)
        XCTAssertEqual(space.folders[1].parentID, space.folders[0].id)
        XCTAssertEqual(space.tabs[1].folderID, space.folders[0].id)
        XCTAssertFalse(plan.warnings.isEmpty)
        XCTAssertEqual(try ArcImport.sidebar(fixture()).spaces[0].tabs.map(\.id), space.tabs.map(\.id))
    }
    func testImportIsAdditiveIdempotentAndKeepsFolders() throws {
        var plan = try ArcImport.sidebar(fixture())
        plan.history["Default"] = [.init(title: "Example", url: "https://example.com", visitedAt: 1_000)]
        plan.extensions["Default"] = [.init(id: String(repeating: "a", count: 32), name: "Example extension", version: "1", enabled: true)]
        var state = BrowserState()
        _ = state.newTab("keep.example")
        let options = ArcImportOptions(selectedSpaces: [plan.spaces[0].id])
        let result = try state.importArc(plan, options: options)
        XCTAssertEqual(result.spaces, 1); XCTAssertEqual(result.tabs, 2)
        XCTAssertEqual(result.folders, 2); XCTAssertEqual(result.extensions, 1)
        XCTAssertEqual(state.tabs.count, 3)
        XCTAssertTrue(state.tabs.contains { $0.url == "https://keep.example" })
        XCTAssertNil(state.activeTab, "Import must not eagerly open all imported sites")
        let second = try state.importArc(plan, options: options)
        XCTAssertEqual(second.spaces + second.tabs + second.folders + second.history + second.extensions, 0)
        XCTAssertEqual(state.sidebarItems.count, 4)
        state.toggleFolder(plan.spaces[0].folders[0].id)
        XCTAssertEqual(state.sidebarItems.count, 2)
        let restored = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
        var validated = restored
        validated.validateForRestore()
        XCTAssertNil(validated.activeTab, "Restart must not activate an imported tab that was never selected")
    }
    func testCategoriesAndRejectedImportDoNotPartiallyMutate() throws {
        let plan = try ArcImport.sidebar(fixture())
        var state = BrowserState()
        var options = ArcImportOptions(selectedSpaces: [plan.spaces[0].id])
        options.folders = false; options.openTabs = true
        try state.importArc(plan, options: options)
        XCTAssertTrue(state.folders.isEmpty)
        XCTAssertEqual(state.tabs.count, 3)
        XCTAssertTrue(state.tabs.allSatisfy { $0.folderID == nil })
        var full = BrowserState()
        full.spaces = (0..<100).map { Space(id: "s-\($0)", name: "Space") }
        let before = full
        XCTAssertThrowsError(try full.importArc(plan, options: options))
        XCTAssertEqual(full, before)
    }
    func testLegacyStateAndCorruptFolderGraph() throws {
        var state = BrowserState()
        state.spaces[0].color = "sage"
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        for key in ["folders", "importedExtensions", "sidebarWidth", "setupCompleted"] { object.removeValue(forKey: key) }
        var restored = try JSONDecoder().decode(BrowserState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.spaces[0].color, "gray")
        XCTAssertEqual(restored.sidebarWidth, 260)
        restored.folders = [.init(id: "a", spaceID: "personal", parentID: "b", title: "A"), .init(id: "b", spaceID: "personal", parentID: "a", title: "B")]
        restored.sidebarWidth = 10_000
        restored.validateForRestore()
        XCTAssertEqual(restored.sidebarWidth, 400)
        XCTAssertTrue(restored.folders.allSatisfy { $0.parentID == nil })
        XCTAssertEqual(restored.sidebarItems.count, 2)
        XCTAssertFalse(ArcImport.validProfileDirectory("../Chrome/Default"))
        XCTAssertFalse(ArcImport.validProfileDirectory("/tmp/Profile 1"))
    }
    func testUnsupportedSidebarIsNotAnEmptySuccessfulImport() {
        XCTAssertThrowsError(try ArcImport.sidebar(Data("{}".utf8)))
    }
    func testLockedSelectedCategoryBlocksPartialImport() throws {
        var plan = try ArcImport.sidebar(fixture())
        plan.unavailableHistoryProfiles = ["Default"]
        var state = BrowserState()
        let before = state
        var options = ArcImportOptions(selectedSpaces: Set(plan.spaces.map(\.id)))
        XCTAssertThrowsError(try state.importArc(plan, options: options))
        XCTAssertEqual(state, before)
        options.history = false
        XCTAssertNoThrow(try state.importArc(plan, options: options))
        XCTAssertEqual(state.tabs.count, 2)
    }
}
