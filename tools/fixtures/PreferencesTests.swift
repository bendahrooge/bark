import AppKit
import Foundation

@MainActor func checkPreferences() throws {
    final class Recorder { var messages: [[String: Any]] = [] }
    let recorder = Recorder()
    let callback: ChromiumCommand = { pointer, text in
        guard let pointer, let text,
              let data = String(cString: text).data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        Unmanaged<Recorder>.fromOpaque(pointer).takeUnretainedValue().messages.append(message)
    }
    let model = ChromiumSidebarModel(context: Unmanaged.passUnretained(recorder).toOpaque(), callback: callback)
    let preferences: [String: Any] = ["profileId": "Default", "searchEngines": [["id": "1", "name": "Search One"], ["id": "2", "name": "Search Two"]],
        "searchEngine": "1", "searchEditable": true, "searchLoaded": true,
        "downloadPath": "/tmp", "downloadEditable": true, "askDownload": false,
        "askDownloadEditable": true, "pictureInPictureEditable": true]
    var snapshot: [String: Any] = ["tabs": [], "spaces": [], "profile": "/tmp/preferences-test", "profileId": "Default",
                                 "canGoBack": false, "canGoForward": false, "preferences": preferences]
    func update(_ value: [String: Any]) throws {
        model.update(String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!)
    }
    try update(snapshot)
    precondition(model.snapshot.preferences?.searchEngines.count == 2 && model.snapshot.preferences?.downloadPath == "/tmp")
    model.setPreference("searchEngine", value: "2")
    precondition(recorder.messages.last?["action"] as? String == "setPreference" &&
                 recorder.messages.last?["text"] as? String == "2" &&
                 (recorder.messages.last?["metadata"] as? [String: String]) == ["key": "searchEngine", "profile": "Default"],
                 "Native preference changes carry the profile that supplied them")
    model.setPreference("askDownload", value: "on")
    model.setPreference("downloadPath", value: "/tmp/downloads")
    let count = recorder.messages.count
    for (key, value) in [("searchEngine", "missing"), ("askDownload", "yes"), ("downloadPath", "relative"), ("unknown", "on")] {
        model.setPreference(key, value: value)
    }
    precondition(recorder.messages.count == count, "Unknown options and invalid values never reach Chromium")
    var managed = preferences
    managed["searchEditable"] = false
    managed["downloadEditable"] = false
    managed["askDownloadEditable"] = false
    snapshot["preferences"] = managed
    try update(snapshot)
    model.setPreference("searchEngine", value: "2")
    model.setPreference("downloadPath", value: "/tmp")
    model.setPreference("askDownload", value: "on")
    precondition(recorder.messages.count == count, "Policy and extension controlled settings stay read-only")
    snapshot["preferences"] = preferences
    snapshot["profileId"] = "Profile 2"
    try update(snapshot)
    model.setPreference("searchEngine", value: "2")
    precondition(recorder.messages.count == count, "A profile switch invalidates the old preferences")
    snapshot["profileId"] = "Default"
    snapshot["incognito"] = true
    try update(snapshot)
    model.setPreference("askDownload", value: "on")
    precondition(recorder.messages.count == count, "Private windows do not write persistent profile preferences")
    model.shutdown()
}
