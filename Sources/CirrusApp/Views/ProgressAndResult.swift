import SwiftUI
import AVFoundation
import CirrusCore

struct ProgressCard: View {
    var progress: JobProgress
    var cancel: () -> Void

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(progress.stage.rawValue).font(.title3.weight(.semibold))
                Spacer()
                Text("\(Int((progress.fraction * 100).rounded(.down)))%").font(.system(size: 28, weight: .light)).monospacedDigit()
            }
            ConvergenceProgress(fraction: progress.fraction)
            HStack(spacing: 14) {
                if let d = progress.detail { Text(d).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                if let s = progress.speed, s > 0 { Label(String(format: "%.1f× real time", s), systemImage: "speedometer").foregroundStyle(.secondary) }
                if let eta = progress.eta { Label("About \(Fmt.eta(eta)) left", systemImage: "clock").foregroundStyle(.secondary) }
                else { Label("Estimating time…", systemImage: "clock").foregroundStyle(.tertiary) }
            }
            .font(.callout).monospacedDigit()
            HStack {
                Text("You can keep working — compression runs in the background.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button(role: .cancel) { cancel() } label: { Text("Cancel") }.keyboardShortcut(".", modifiers: .command)
            }
        }
    }
}

struct ResultCard: View {
    var result: CompressionResult
    var compare: () -> Void
    var again: () -> Void
    var restore: (() -> Void)? = nil
    /// Move this compressed file to the Trash.
    var trash: (() -> Void)? = nil
    /// Make another version of the same video.
    var another: (() -> Void)? = nil
    @State private var playable: Bool?
    @State private var confirmTrash = false

    var body: some View {
        Card {
            HStack(spacing: 10) {
                ZStack {
                    StreaksView(progress: 1, settled: true, color: Brand.accent, pointColor: Brand.dawn, count: 3).frame(width: 46, height: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compressed").font(.title3.weight(.semibold))
                    Text(result.outputURL.lastPathComponent).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text("in \(Fmt.eta(result.elapsed))").font(.callout).foregroundStyle(.secondary)
            }

            Grid(horizontalSpacing: 18, verticalSpacing: 16) {
                GridRow {
                    StatTile(title: "Original", value: Fmt.bytes(result.originalBytes))
                    StatTile(title: "Compressed", value: Fmt.bytes(result.outputBytes), caption: targetCaption,
                             tint: result.metTarget == false ? .orange : .primary)
                    StatTile(title: "Saved", value: String(format: "%.1f%%", result.reduction * 100),
                             caption: Fmt.bytes(max(0, result.originalBytes - result.outputBytes)), tint: Brand.dawn)
                }
                GridRow {
                    StatTile(title: "Resolution", value: "\(result.outputSize.width) × \(result.outputSize.height)")
                    StatTile(title: "Codec", value: result.codec.rawValue, caption: "\(result.tenBit ? "10-bit" : "8-bit") · \(result.audioSummary)")
                    if let q = result.quality {
                        StatTile(title: "Quality", value: q.rating.rawValue,
                                 caption: String(format: "VMAF %.1f · worst moments %.1f", q.vmaf, q.vmafP5), tint: q.rating.color)
                    } else {
                        StatTile(title: "Quality", value: "Not measured", caption: "Turn on “Measure VMAF” in Advanced", tint: .secondary)
                    }
                }
            }
            .padding(.vertical, 4)

            if let q = result.quality { Text(q.rating.explanation).font(.callout).foregroundStyle(.secondary) }
            HStack(spacing: 8) {
                if result.previewableOnThisMac {
                    Chip(text: "Plays in Quick Look on this Mac", systemImage: "eye", tint: Brand.good)
                } else {
                    Chip(text: "No Quick Look on this Mac", systemImage: "eye.slash", tint: Brand.warn)
                        .help("This Mac can’t decode AV1 in Apple’s players (that needs an M3 or later). VLC, IINA, browsers and YouTube play it.")
                }
                if let t = result.textCheck {
                    Chip(text: String(format: "Text: %.0f%% reads the same", t.accuracy * 100), systemImage: "text.viewfinder",
                         tint: t.accuracy >= TextLegibility.requiredAccuracy ? Brand.good : Brand.warn)
                        .help(t.summary)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(result.warnings, id: \.self) { InfoRow(systemImage: "exclamationmark.triangle.fill", text: $0, tint: Brand.warn) }
                ForEach(result.notes, id: \.self) { InfoRow(systemImage: "info.circle", text: $0) }
                InfoRow(systemImage: "cpu", text: result.settingsSummary)
                if !result.previewableOnThisMac {
                    InfoRow(systemImage: "eye.slash", text: "Finder’s spacebar preview and QuickTime won’t play this AV1 file on this Mac (that needs an M3 or later). VLC, IINA, browsers and YouTube play it. Choose “HEVC · Previews in Finder” under Format to get a file that does.", tint: Brand.warn)
                }
            }

            HStack(spacing: 10) {
                Button { play() } label: { Label("Play", systemImage: "play.fill") }
                Button { NSWorkspace.shared.activateFileViewerSelecting([result.outputURL]) } label: { Label("Show in Finder", systemImage: "folder") }
                Button { compare() } label: { Label("Compare with Original", systemImage: "rectangle.split.2x1") }
                Spacer()
                if let restore { Button("Restore Original") { restore() }.help("Bring the original back from the Trash and move this compressed copy to the Trash") }
                if let trash {
                    Button("Move to Trash") { confirmTrash = true }
                        .help("Don’t keep this compressed file")
                        .confirmationDialog("Move “\(result.outputURL.lastPathComponent)” to the Trash?", isPresented: $confirmTrash) {
                            Button("Move to Trash", role: .destructive) { trash() }
                        } message: { Text("Your original isn’t affected. You can take the file back out of the Trash.") }
                }
                if let another { Button("Make Another Version") { another() }.help("Make this video again with different settings, e.g. a smaller size for email") }
                Button("Compress Again…") { again() }.buttonStyle(.link)
            }
            .controlSize(.large)
        }
        .task { playable = try? await AVURLAsset(url: result.outputURL).load(.isPlayable) }
    }

    var targetCaption: String? {
        guard let t = result.targetBytes else { return nil }
        return result.outputBytes <= t ? "Target \(Fmt.bytes(t)) ✓" : "Target \(Fmt.bytes(t)) — over"
    }

    func play() {
        if playable == false, let vlc = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc")
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.colliderli.iina") {
            NSWorkspace.shared.open([result.outputURL], withApplicationAt: vlc, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(result.outputURL)
        }
    }
}
