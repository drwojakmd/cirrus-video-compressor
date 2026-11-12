import SwiftUI
import AppKit
import CirrusCore

/// The About window: a band of sky with the converging streaks, the wordmark, and the credits.
enum AboutWindow {
    @MainActor private static var window: NSWindow?

    @MainActor static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 470), styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: AboutView())
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

struct AboutView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build" }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Brand.skyGradient
                StreaksView(progress: 1, drift: !reduceMotion, color: .white, pointColor: Brand.dawnFixed)
                    .padding(.vertical, 40).padding(.trailing, 30)
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
            }
            .frame(height: 210)
            VStack(spacing: 6) {
                Text("Cirrus").font(.system(size: 38, weight: .ultraLight)).kerning(1.5)
                Text("Video Compressor").font(.system(size: 15, weight: .regular)).foregroundStyle(.secondary)
                Text("Less weight. Same picture.").font(.system(size: 13, weight: .light)).italic().foregroundStyle(Brand.accent).padding(.top, 6)
                Text("Version \(version)").font(.caption).foregroundStyle(.secondary).padding(.top, 10)
                Text("Encoding by FFmpeg with SVT-AV1, x265, x264, Opus and VMAF.").font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 30)
                HStack(spacing: 12) {
                    Button("Third-Party Notices") {
                        if let u = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt", subdirectory: "Licenses") { NSWorkspace.shared.open(u) }
                    }
                    Button("Engine Log") { if let u = Log.logFileURL { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                }
                .controlSize(.small).padding(.top, 10)
                Text("© 2026 Cirrus").font(.caption2).foregroundStyle(.tertiary).padding(.top, 8)
            }
            .padding(.vertical, 20)
            Spacer(minLength: 0)
        }
        .frame(width: 420, height: 470)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }
}
