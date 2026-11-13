import Foundation

public enum StateFile {
    public static func read(_ url: URL) throws -> BrowserState {
        let data = try Data(contentsOf: url)
        var state = try JSONDecoder().decode(BrowserState.self, from: data)
        state.validateForRestore()
        return state
    }
    public static func write(_ state: BrowserState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
