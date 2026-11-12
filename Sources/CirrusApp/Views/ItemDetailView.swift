import SwiftUI
import CirrusCore

struct ItemDetailView: View {
    @Environment(AppModel.self) private var model
    @Bindable var item: QueueItem
    @State private var compare: CompareTarget?

    var body: some View {
        ScrollView {
            ItemDetailContent(item: item, compare: $compare)
        }
        .sheet(item: $compare) { target in
            if let engine = model.engine, let src = item.source {
                switch target {
                case .preview: PreviewStudio(engine: engine, item: item, source: src, close: { compare = nil })
                case .result: CompareView(engine: engine, source: src, settings: item.settings, target: target)
                }
            }
        }
    }
}

struct ItemDetailContent: View {
    @Environment(AppModel.self) private var model
    @Bindable var item: QueueItem
    @Binding var compare: CompareTarget?

    var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                SourceHeaderView(item: item)
                if item.source != nil {
                    if item.hasVersions { VersionsStrip(item: item, openStudio: { compare = .preview }) }
                    let v = item.current
                    switch v.job {
                    case .running(let p): ProgressCard(progress: p, cancel: { v.cancel() })
                    case .queued: QueuedCard(cancel: { v.cancel() })
                    case .done(let r):
                        ResultCard(result: r, compare: { compare = .result(r) }, again: { v.job = .idle },
                                   restore: r.trashedOriginal == nil ? nil : {
                                       do {
                                           try OriginalReplacer.restore(original: r.sourceURL, from: r.trashedOriginal!, compressed: r.outputURL)
                                           v.job = .idle; item.appliedNote = "The original is back and the compressed copy is in the Trash."
                                       } catch { item.appliedNote = error.localizedDescription }
                                   },
                                   trash: r.trashedOriginal != nil ? nil : { trash(r, of: v) },
                                   another: item.hasVersions ? nil : { model.addVersion(to: item) })
                        if let n = item.appliedNote { InfoRow(systemImage: "info.circle", text: n) }
                    default:
                        if case .failed(let msg) = v.job { FailureBanner(message: msg) }
                        if case .cancelled = v.job { InfoRow(systemImage: "xmark.circle", text: "Cancelled. Nothing was written and your original is untouched.") }
                        if case .skipped(let why) = v.job { SkippedBanner(message: why) }
                        SettingsPanel(item: item, openStudio: { compare = .preview })
                        ActionBar(item: item, preview: { compare = .preview })
                    }
                    if item.results.count >= 2 { VersionResultsTable(item: item) }
                } else if let e = item.inspectError {
                    FailureBanner(message: e)
                } else {
                    Card { HStack { ProgressView().controlSize(.small); Text("Analysing video…").foregroundStyle(.secondary) } }
                }
            }
            .padding(22)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
    }

    /// Move one finished version's file to the Trash (and the version with it, when there are others).
    func trash(_ r: CompressionResult, of v: OutputVersion) {
        do {
            try FileManager.default.trashItem(at: r.outputURL, resultingItemURL: nil)
            if item.hasVersions { item.removeVersion(v) } else { v.job = .idle }
            item.appliedNote = "“\(r.outputURL.lastPathComponent)” is in the Trash."
        } catch { item.appliedNote = error.localizedDescription }
    }
}

enum CompareTarget: Identifiable {
    case preview
    case result(CompressionResult)
    var id: String { if case .result(let r) = self { return r.outputURL.path }; return "preview" }
}

struct SourceHeaderView: View {
    var item: QueueItem

    var body: some View {
        Card(padding: 14) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.85))
                    if let t = item.thumbnail {
                        Image(cgImage: t).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 240, height: 135).clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 8) {
                    Text(item.name).font(.system(size: 17, weight: .semibold)).lineLimit(2).truncationMode(.middle)
                    if let s = item.source {
                        let m = s.media
                        HStack(spacing: 18) {
                            Meta(label: "Size", value: Fmt.bytes(m.fileSize))
                            Meta(label: "Resolution", value: "\(m.displaySize.width) × \(m.displaySize.height)")
                            Meta(label: "Duration", value: Fmt.duration(m.duration))
                            Meta(label: "Frame rate", value: String(format: m.video.frameRate.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f fps" : "%.2f fps", m.video.frameRate) + (m.video.isVariableFrameRate ? " (variable)" : ""))
                        }
                        FlowChips(chips: chips(s))
                        HStack(spacing: 6) {
                            Image(systemName: s.analysis.kind.symbolName).foregroundStyle(Brand.accent)
                            Text("Detected: ").foregroundStyle(.secondary) + Text(s.analysis.kind.rawValue).fontWeight(.medium)
                            Text("· \(s.analysis.summary)").foregroundStyle(.secondary).lineLimit(1)
                        }.font(.callout)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    func chips(_ s: SourceItem) -> [(String, String)] {
        let m = s.media
        var c: [(String, String)] = [(m.video.codecDisplayName + (m.video.bitDepth > 8 ? " \(m.video.bitDepth)-bit" : ""), "film")]
        if let b = m.video.bitrate { c.append((String(format: "%.1f Mbps", Double(b) / 1e6), "speedometer")) }
        if m.video.dynamicRange.isHDR { c.append((m.video.dynamicRange.rawValue, "sun.max")) }
        if let a = m.audio.first {
            let ch = a.channels == 1 ? "Mono" : a.channels == 2 ? "Stereo" : "\(a.channels) ch"
            c.append(("\(a.codecDisplayName) \(ch)" + (a.bitrate.map { " \($0 / 1000) kbps" } ?? ""), "waveform"))
        } else { c.append(("No audio", "speaker.slash")) }
        if m.video.isInterlaced { c.append(("Interlaced", "line.3.horizontal")) }
        return c
    }

    struct Meta: View {
        var label: String; var value: String
        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
        }
    }
}

struct FlowChips: View {
    var chips: [(String, String)]
    var body: some View {
        HStack(spacing: 6) { ForEach(chips.indices, id: \.self) { Chip(text: chips[$0].0, systemImage: chips[$0].1) } }
    }
}

struct FailureBanner: View {
    var message: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Something went wrong").font(.headline)
                Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Your original file was not changed.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ActionBar: View {
    @Environment(AppModel.self) private var model
    var item: QueueItem
    var preview: () -> Void

    var body: some View {
        let n = item.pendingVersions.count
        HStack(spacing: 12) {
            DestinationMenu(item: item)
            Spacer()
            if !item.hasVersions { AddVersionMenu(item: item, label: "Add Version").controlSize(.large) }
            Button { preview() } label: { Label("Preview Studio…", systemImage: "square.grid.2x2") }
                .controlSize(.large)
                .help("Compare how different settings would look on this video's own frames, with exact sizes, before compressing")
                .disabled(model.engine == nil || plan == nil)
            Button { model.requestCompress([item]) } label: {
                Label(title(n), systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(ProminentButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(plan == nil || n == 0)
        }
        .padding(.top, 2)
    }

    func title(_ n: Int) -> String {
        if model.prefs.outputMode == .replaceOriginals { return "Compress and Replace" }
        let what = item.hasVersions ? "\(n) Version\(n == 1 ? "" : "s")" : ""
        if model.isBusy { return item.hasVersions ? "Queue \(what)" : "Add to Queue" }
        return item.hasVersions ? "Compress \(what)" : "Compress"
    }

    var plan: EncodePlan? { if case .success(let p) = item.plan(with: model.engine) { return p }; return nil }
}

struct DestinationMenu: View {
    @Environment(AppModel.self) private var model
    var item: QueueItem
    var body: some View {
        let dest = model.destination(for: item, create: false)
        let mode = model.prefs.outputMode
        Menu {
            Picker("", selection: Binding(get: { model.prefs.outputMode }, set: { model.prefs.outputMode = $0; model.prefs.save() })) {
                Text("Save Next to the Original").tag(Preferences.OutputMode.sameAsSource)
                Text(model.prefs.outputFolder.map { "Save in “\($0.lastPathComponent)”" } ?? "Save in a Chosen Folder").tag(Preferences.OutputMode.folder)
                Text("Replace the Original (Original to Trash)").tag(Preferences.OutputMode.replaceOriginals)
            }.pickerStyle(.inline).labelsHidden()
            Toggle("Put Versions in Their Own Folder", isOn: Binding(get: { model.prefs.versionsInOwnFolder },
                                                                     set: { model.prefs.versionsInOwnFolder = $0; model.prefs.save() }))
                .disabled(mode == .replaceOriginals)
            Button("Choose Folder…") {
                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.prompt = "Use Folder"
                if p.runModal() == .OK, let u = p.url { model.prefs.outputMode = .folder; model.prefs.outputFolder = u; model.prefs.save() }
            }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.open(FileManager.default.fileExists(atPath: dest.path) ? dest : model.destination(for: item.url)) }
        } label: {
            switch mode {
            case .replaceOriginals: Label("Replace original", systemImage: "arrow.triangle.2.circlepath")
            default: Label("Save to \(dest.lastPathComponent)", systemImage: "folder")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help(dest.path)
    }
}

struct QueuedCard: View {
    var cancel: () -> Void
    var body: some View {
        Card {
            HStack {
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text("Waiting for the current compression to finish…").foregroundStyle(.secondary)
                Spacer()
                Button("Remove from Queue") { cancel() }
            }
        }
    }
}

struct SkippedBanner: View {
    var message: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(Brand.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Left as it is").font(.headline)
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Lower “Skip if saving under” or choose a smaller quality level to compress it anyway.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
