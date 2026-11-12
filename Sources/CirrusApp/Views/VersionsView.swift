import SwiftUI
import AppKit
import CirrusCore

/// The versions Cirrus will make of one video: a card per version (click to edit it below),
/// what sets each apart, warnings about pointless versions, and the totals.
struct VersionsStrip: View {
    @Environment(AppModel.self) private var model
    @Bindable var item: QueueItem
    var openStudio: () -> Void

    var body: some View {
        let mac = model.macDecodesAV1
        Card(padding: 14) {
            HStack(spacing: 10) {
                SectionLabel(title: "Versions Cirrus will make", systemImage: "square.stack.3d.down.right")
                Text("\(item.versions.count)").font(.caption.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Brand.accent.opacity(0.15), in: Capsule()).foregroundStyle(Brand.accent)
                Spacer()
                Button { openStudio() } label: { Label("Compare in Preview Studio…", systemImage: "square.grid.2x2") }
                    .help("See every version side by side on this video's own frames, with exact sizes")
                    .disabled(model.engine == nil)
                AddVersionMenu(item: item, label: "Add Version")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 10)], spacing: 10) {
                ForEach(item.versions) { v in
                    VersionCard(item: item, version: v, letter: item.letter(v), selected: item.selectedVersionID == v.id, mac: mac)
                        .onTapGesture { item.selectedVersionID = v.id; item.appliedNote = nil }
                }
            }
            ForEach(item.versionWarnings(engine: model.engine)) { w in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.warn)
                    Text(w.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Remove \(item.letter(w.version))") { item.removeVersion(w.version); model.saveQueue() }.controlSize(.small)
                }
                .padding(10).background(Brand.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            }
            HStack(spacing: 10) {
                Text(totals).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if !item.current.isEditable && !item.pendingVersions.isEmpty {
                    let n = item.pendingVersions.count
                    Button("Compress \(n) Remaining Version\(n == 1 ? "" : "s")") { model.requestCompress([item]) }
                        .buttonStyle(ProminentButtonStyle())
                }
            }
        }
    }

    var totals: String {
        let pending = item.pendingVersions.count
        let made = item.results
        var parts: [String] = []
        if pending > 0 {
            var p = "\(pending) to make"
            if let t = item.pendingTotals(engine: model.engine) { p += " · about \(Fmt.bytes(t.bytes)) · about \(Fmt.eta(t.seconds))" }
            else if case .running = item.estimate { p += " · measuring…" }
            parts.append(p)
        }
        if !made.isEmpty { parts.append("\(made.count) made · \(Fmt.bytes(made.reduce(0) { $0 + $1.outputBytes })) in total") }
        let dest = model.destination(for: item, create: false)
        if model.prefs.outputMode != .replaceOriginals { parts.append("saved in “\(dest.lastPathComponent)”") }
        return parts.joined(separator: " · ")
    }
}

struct VersionCard: View {
    @Environment(AppModel.self) private var model
    var item: QueueItem
    @Bindable var version: OutputVersion
    var letter: String
    var selected: Bool
    var mac: Bool

    var body: some View {
        let d = item.differences(version, mac: mac)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(letter).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(Circle().fill(Brand.accent))
                Text(d.distinct.joined(separator: " · ")).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 0)
            }
            if !d.shared.isEmpty {
                Text(d.shared.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            if let p = version.purpose { Chip(text: p, systemImage: "paperplane", tint: Brand.dawn) }
            Spacer(minLength: 0)
            status
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Brand.accent.opacity(0.08) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Brand.accent : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 0.5))
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy This Version") { model.addVersion(to: item, settings: version.settings) }
            if version.isEditable && model.prefs.outputMode != .replaceOriginals {
                Button("Compress Only This Version") { model.requestCompress(version, of: item) }
            }
            if version.job.isActive { Button("Cancel") { version.cancel() } }
            if case .done(let r) = version.job { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.outputURL]) } }
            Divider()
            Button("Remove Version", role: .destructive) { item.removeVersion(version); model.saveQueue() }
                .disabled(item.versions.count < 2 || version.job.isActive)
        }
        .help("Click to see and change this version’s settings")
    }

    @ViewBuilder var status: some View {
        switch version.job {
        case .idle, .cancelled, .failed:
            HStack(spacing: 4) {
                if case .failed = version.job { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                if case .cancelled = version.job { Text("Cancelled ·").foregroundStyle(.secondary) }
                if let e = item.estimate(for: version.settings, engine: model.engine) {
                    Text("≈ \(Fmt.bytes(e.bytes))").fontWeight(.medium)
                    Text(verbatim: "· \(e.outputSize.shortSide)p · \(Fmt.eta(e.seconds))").foregroundStyle(.secondary)
                    if e.wouldSkip { Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(Brand.warn).help("Would save too little and be skipped") }
                } else if case .targetSize(let b) = version.settings.goal {
                    Text("≤ \(Fmt.bytes(b))").fontWeight(.medium)
                } else {
                    Text("Estimating…").foregroundStyle(.tertiary)
                }
            }
            .font(.caption).monospacedDigit()
        case .queued:
            Label("Queued", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        case .running(let p):
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: p.fraction).tint(Brand.accent).controlSize(.small)
                Text("\(Int(p.fraction * 100))% · \(p.stage.rawValue)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .done(let r):
            Label("\(Fmt.bytes(r.outputBytes)) · −\(Int((r.reduction * 100).rounded()))%", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium)).foregroundStyle(Brand.good).monospacedDigit()
        case .skipped:
            Label("Left as it is", systemImage: "arrow.uturn.backward.circle").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// "Add Version": a copy of the current version, or a ready-made one.
struct AddVersionMenu: View {
    @Environment(AppModel.self) private var model
    var item: QueueItem
    var label: String

    var body: some View {
        Menu {
            Button("Copy of Version \(item.letter(item.current))") { model.addVersion(to: item) }
            Divider()
            Section("Ready-made") {
                ForEach(QuickAdd.allCases) { q in
                    let r = item.quickAdd(q, engine: model.engine)
                    Button {
                        for (i, s) in r.settings.enumerated() { model.addVersion(to: item, settings: s, purpose: i == 0 ? q.purpose : nil) }
                        // the quick add is the variation: keep the first card as it was
                        if let first = item.versions.first(where: { v in r.settings.first == v.settings }) { item.selectedVersionID = first.id }
                    } label: {
                        Label(r.problem.map { "\(q.title) — \($0)" } ?? q.title, systemImage: q.symbol)
                    }
                    .disabled(r.settings.isEmpty)
                }
            }
            let sets = model.prefs.allPresets.filter { ($0.versions?.count ?? 0) > 1 }
            if !sets.isEmpty {
                Section("Saved sets") {
                    ForEach(sets) { p in Button("\(p.name) (\(p.versions!.count) versions)") { model.apply(p, to: [item]) } }
                }
            }
        } label: {
            Label(label, systemImage: "plus.square.on.square")
        } primaryAction: {
            model.addVersion(to: item)
        }
        .fixedSize()
        .help("Make this video more than one way: click for a copy of the current version to change, or pick a ready-made one")
    }
}

/// Side-by-side results once two or more versions are made.
struct VersionResultsTable: View {
    @Environment(AppModel.self) private var model
    var item: QueueItem

    var body: some View {
        let original = item.source?.media.fileSize ?? 0
        Card(padding: 14) {
            SectionLabel(title: "Compare the versions you made", systemImage: "tablecells")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    ForEach(["", "Version", "Size", "Saved", "Quality", "Text", "Quick Look", ""], id: \.self) {
                        Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(item.versions) { v in
                    if case .done(let r) = v.job {
                        GridRow {
                            Text(item.letter(v)).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Brand.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(v.settings.versionLabel(macDecodesAV1: model.macDecodesAV1)).fontWeight(.medium)
                                Text(verbatim: "\(r.outputSize.width) × \(r.outputSize.height) · \(r.codec.rawValue)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(Fmt.bytes(r.outputBytes)).monospacedDigit().fontWeight(.medium)
                            Text(String(format: "%.0f%%", (1 - Double(r.outputBytes) / Double(max(1, original))) * 100)).monospacedDigit().foregroundStyle(Brand.good)
                            Text(r.quality.map { "\($0.rating.rawValue) (\(String(format: "%.0f", $0.vmaf)))" } ?? "—").foregroundStyle(r.quality?.rating.color ?? .secondary)
                            Text(r.textCheck.map { String(format: "%.0f%%", $0.accuracy * 100) } ?? "—").monospacedDigit()
                            Image(systemName: r.previewableOnThisMac ? "checkmark" : "xmark").foregroundStyle(r.previewableOnThisMac ? Brand.good : .secondary)
                            HStack(spacing: 6) {
                                Button { NSWorkspace.shared.open(r.outputURL) } label: { Image(systemName: "play.fill") }.help("Play")
                                Button { NSWorkspace.shared.activateFileViewerSelecting([r.outputURL]) } label: { Image(systemName: "folder") }.help("Show in Finder")
                                Button { item.selectedVersionID = v.id } label: { Image(systemName: "info.circle") }.help("Details")
                            }.buttonStyle(.borderless)
                        }
                        .font(.callout)
                    }
                }
            }
            Text("Quality is Netflix’s VMAF score (95+ looks the same as the original). Text is how much on-screen text reads identically to the original.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}
