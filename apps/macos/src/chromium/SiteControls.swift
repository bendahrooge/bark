import AppKit
import SwiftUI

struct ChromiumSiteExtension: Decodable, Identifiable {
    let id: String
    let name: String
    let enabled: Bool
    var icon: String?
}

struct ChromiumSitePermission: Decodable, Identifiable {
    let id: String
    let setting: String
    var editable: Bool? = nil
    var options: [String]? = nil
    var isDefault: Bool? = nil
    var detail: String? = nil
    var selectedOption: String { isDefault == true ? "default" : setting }
    static func optionTitle(_ option: String) -> String {
        switch option {
        case "allow": return "Allow"
        case "block": return "Block"
        case "ask": return "Ask"
        default: return "Use default"
        }
    }
    var name: String {
        switch id {
        case "clipboard": return "Clipboard"
        case "camera": return "Camera"
        case "microphone": return "Microphone"
        case "autoPictureInPicture": return "Automatic Picture in Picture"
        default: return "Site permission"
        }
    }
    var symbol: String {
        switch id {
        case "clipboard": return "doc.on.clipboard"
        case "camera": return "video"
        case "microphone": return "mic"
        case "autoPictureInPicture": return "pip"
        default: return "gearshape"
        }
    }
    var status: String {
        switch setting {
        case "allow": return "Allowed"
        case "block": return "Blocked"
        case "ask": return "Ask first"
        default: return "Default"
        }
    }
}

struct ChromiumSiteControls: Decodable {
    let tabId: Int
    let url: String
    let canManagePermissions: Bool
    let canInspect: Bool
    let extensions: [ChromiumSiteExtension]
    let permissions: [ChromiumSitePermission]
}

@MainActor extension ChromiumSidebarModel {
    func setSiteControlsOpen(_ open: Bool) {
        guard siteControlsOpen != open else { return }
        siteControlsOpen = open
        send("siteControls", text: open ? "open" : "close")
    }

    // The popover describes one page. Never apply a delayed click to a tab or
    // document that replaced it while the popover was closing.
    func performSiteControl(_ action: String, text: String? = nil) {
        guard let tab = activeTab else { return }
        setSiteControlsOpen(false)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeTab?.id == tab.id, self.activeTab?.url == tab.url else { return }
            self.send(action, id: tab.id, text: text, metadata: ["url": tab.url])
        }
    }

    // Permission menus stay inside the popover. Use its original page context,
    // then recheck the latest snapshot before sending a change to Chromium.
    func setSitePermission(_ id: String, to setting: String, for controls: ChromiumSiteControls) {
        guard siteControlsOpen, controls.canManagePermissions,
              activeTab?.id == controls.tabId, activeTab?.url == controls.url,
              let current = snapshot.siteControls,
              current.tabId == controls.tabId, current.url == controls.url,
              let permission = current.permissions.first(where: { $0.id == id }),
              permission.editable == true, permission.options?.contains(setting) == true else { return }
        send("setSitePermission", id: controls.tabId, text: setting,
             metadata: ["url": controls.url, "permission": id])
    }
}

struct SiteControlsView: View {
    @ObservedObject var model: ChromiumSidebarModel
    private var controls: ChromiumSiteControls? {
        guard let controls = model.snapshot.siteControls,
              controls.tabId == model.activeTab?.id, controls.url == model.activeTab?.url else { return nil }
        return controls
    }
    private var securityLabel: String {
        switch model.snapshot.securityLevel {
        case "secure": return "Secure connection"
        case "dangerous": return "Dangerous site"
        case "warning": return "Not secure"
        default: return "Connection details"
        }
    }
    private var securitySymbol: String {
        switch model.snapshot.securityLevel {
        case "secure": return "lock.fill"
        case "dangerous", "warning": return "exclamationmark.triangle.fill"
        default: return "info.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                quickAction("Copy link", symbol: "link", enabled: model.activeTab?.isBlank == false) {
                    if let tab = model.activeTab { model.copyLink(tab) }
                }
                quickAction("Reload page", symbol: "arrow.clockwise") { model.performSiteControl("reload") }
                quickAction("Find in page", symbol: "doc.text.magnifyingglass") { model.performSiteControl("findInPage") }
                quickAction("Developer tools", symbol: "hammer", enabled: controls?.canInspect == true) {
                    model.performSiteControl("inspectPage")
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                sectionTitle("Extensions")
                if let controls {
                    if controls.extensions.isEmpty {
                        HStack(spacing: 10) {
                            manageExtensions.frame(width: 52)
                            Text("No extensions in this profile")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    } else {
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                                ForEach(controls.extensions) { item in
                                    Button { model.performSiteControl("activateExtension", text: item.id) } label: {
                                        Group {
                                            if let icon = FaviconCache.image(item.icon) {
                                                Image(nsImage: icon).resizable().scaledToFit()
                                            } else {
                                                Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
                                            }
                                        }.frame(width: 22, height: 22)
                                            .frame(maxWidth: .infinity).frame(height: 44)
                                    }.buttonStyle(BarkControlStyle(cornerRadius: 10, restingOpacity: 0.035)).disabled(!item.enabled)
                                        .help(item.name).accessibilityLabel(item.name)
                                }
                                manageExtensions
                            }
                        }.frame(height: min(148, CGFloat((controls.extensions.count + 4) / 4) * 52 - 8))
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).frame(height: 44)
                        .accessibilityLabel("Loading site controls")
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                sectionTitle("Settings")
                if let controls, controls.canManagePermissions {
                    ForEach(controls.permissions) { permission in
                        // AppKit's Menu bridge flattens a composite label into
                        // one line. Keep the styled row outside that bridge and
                        // give the selector its own full-height hit target.
                        HStack(spacing: 10) {
                            Image(systemName: permission.symbol).font(.system(size: 14, weight: .medium))
                                .frame(width: 32, height: 32)
                                .background(model.theme.accent.opacity(0.14), in: Circle())
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(permission.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                Text(permission.detail ?? (permission.status + (permission.isDefault == true ? " · Default" : "")))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Menu {
                                ForEach(permission.options ?? [], id: \.self) { option in
                                    Button {
                                        model.setSitePermission(permission.id, to: option, for: controls)
                                    } label: {
                                        if permission.selectedOption == option {
                                            Label(ChromiumSitePermission.optionTitle(option), systemImage: "checkmark")
                                        } else {
                                            Text(ChromiumSitePermission.optionTitle(option))
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: permission.editable == true ? "chevron.up.chevron.down" : "lock.fill")
                                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                            }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                                .frame(width: 28, height: 36)
                                .disabled(permission.editable != true)
                                .help(permission.detail ?? "Change \(permission.name.lowercased()) access for this site")
                                .accessibilityLabel(permission.name)
                                .accessibilityValue(permission.detail ?? permission.status)
                        }.padding(6).accessibilityElement(children: .contain)
                    }
                } else if controls != nil {
                    Text("Site permissions are available on web pages.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
            HStack {
                Button { model.performSiteControl("siteInfo") } label: {
                    Label(securityLabel, systemImage: securitySymbol)
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).frame(height: 32)
                }.buttonStyle(BarkControlStyle(cornerRadius: 10, restingOpacity: 0.035))
                    .help(model.snapshot.securityDescription ?? "Connection details")
                Spacer(minLength: 8)
                Menu {
                    Button("Site settings…") { model.performSiteControl("siteSettings") }
                        .disabled(controls?.canManagePermissions != true)
                    Button("Manage extensions…") { model.performSiteControl("extensions") }
                    Divider()
                    Button("Browser settings…") { model.performSiteControl("settings") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15)).frame(width: 28, height: 28)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("More site controls")
            }
        }.padding(16).frame(width: 304)
            .background(model.theme.accent.opacity(0.055))
            .accessibilityElement(children: .contain).accessibilityLabel("Site controls")
    }

    private var manageExtensions: some View {
        Button { model.performSiteControl("extensions") } label: {
            Image(systemName: "plus").font(.system(size: 19, weight: .regular))
                .frame(maxWidth: .infinity).frame(height: 44)
        }.buttonStyle(BarkControlStyle(cornerRadius: 10, restingOpacity: 0.035)).foregroundStyle(.secondary)
            .help("Manage extensions").accessibilityLabel("Manage extensions")
    }
    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
    }
    private func quickAction(_ title: String, symbol: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .regular))
                .frame(maxWidth: .infinity).frame(height: 42)
        }.buttonStyle(BarkControlStyle(cornerRadius: 10, restingOpacity: 0.035)).disabled(!enabled)
            .help(title).accessibilityLabel(title)
    }
}
