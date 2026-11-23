import AppKit
import Combine
import SwiftUI
import BarkCore

/// Media playing in another tab: play or pause it, mute it, or go to it.
struct SidebarMediaPlayer: View {
    @ObservedObject var model: ChromiumSidebarModel
    let media: ChromiumMedia
    var body: some View {
        HStack(spacing: 9) {
            Button { model.send("select", id: media.id) } label: {
                HStack(spacing: 9) {
                    Group {
                        if let icon = FaviconCache.image(media.favicon) { Image(nsImage: icon).resizable().scaledToFit() }
                        else { Image(systemName: "music.note").foregroundStyle(.secondary) }
                    }.frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(media.heading).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if !media.detail.isEmpty {
                            Text(media.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("Go to this tab").accessibilityLabel("Go to " + media.heading)
            control(media.playing ? "pause.fill" : "play.fill", media.playing ? "Pause" : "Play") {
                model.send("mediaToggle", id: media.id)
            }
            control(media.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill", media.muted == true ? "Unmute" : "Mute") {
                model.send("mute", id: media.id)
            }
        }.padding(.leading, 10).padding(.trailing, 4).frame(height: 44)
            .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .contain).accessibilityLabel("Now playing")
    }
    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11)).frame(width: 26, height: 30) }
            .buttonStyle(SidebarControlStyle()).foregroundStyle(.secondary).help(label).accessibilityLabel(label)
    }
}
