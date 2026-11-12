import SwiftUI
import CirrusCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            if !model.items.isEmpty {
                Section("Videos") {
                    ForEach(model.items) { item in
                        SidebarRow(item: item).tag(item.id)
                            .contextMenu {
                                if item.isActive { Button("Cancel") { item.cancel() } }
                                if !item.results.isEmpty {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.results.map(\.outputURL)) }
                                }
                                Button("Add Version") { model.selection = item.id; model.addVersion(to: item) }
                                if let sel = model.selected, sel.id != item.id, !item.isActive {
                                    if sel.hasVersions {
                                        Button("Make the Same \(sel.versions.count) Versions as “\(sel.name)”") { model.applyVersions(of: sel, to: [item]) }
                                    }
                                    Button("Use Settings of “\(sel.name)”") { _ = model.applySettings(sel.settings, to: [item]) }
                                }
                                Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                Divider()
                                Button("Remove from List", role: .destructive) { model.remove(item) }
                            }
                    }
                    .onDeleteCommand { if let s = model.selected { model.remove(s) } }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
                    Text("No videos yet").foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                QueueSummary()
                if model.items.contains(where: { $0.isFinished }) {
                    Button("Clear Finished") { model.clearFinished() }
                        .buttonStyle(.borderless).font(.callout)
                }
            }
            .padding(10)
        }
    }
}

struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    var item: QueueItem

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                if let t = item.thumbnail {
                    Image(cgImage: t).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 54, height: 34).clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1).truncationMode(.middle).font(.system(size: 12.5, weight: .medium))
                if item.hasVersions {
                    Label("\(item.versions.count) versions", systemImage: "square.stack.3d.down.right")
                        .font(.caption2.weight(.medium)).foregroundStyle(Brand.accent).lineLimit(1)
                }
                status
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder var status: some View {
        let vs = item.versions
        let running = vs.compactMap { v -> JobProgress? in if case .running(let p) = v.job { return p }; return nil }.first
        let done = item.results
        let multi = item.hasVersions
        if let p = running {
            HStack(spacing: 5) {
                ProgressView(value: p.fraction).progressViewStyle(.linear).controlSize(.mini).tint(Brand.accent)
                if multi { Text("\(done.count + 1)/\(vs.count)").font(.caption2).foregroundStyle(.secondary).monospacedDigit() }
            }
        } else if vs.contains(where: { if case .queued = $0.job { return true }; return false }) {
            Label(multi && !done.isEmpty ? "\(done.count) of \(vs.count) done · queued" : "Queued", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        } else if !done.isEmpty {
            let total = done.reduce(Int64(0)) { $0 + $1.outputBytes }
            let pct = Int(((1 - Double(done.map(\.outputBytes).max() ?? 0) / Double(max(1, done[0].originalBytes))) * 100).rounded())
            Label(multi ? "\(done.count) of \(vs.count) made · \(Fmt.bytes(total))" : "\(Fmt.bytes(total)) · −\(pct)%", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(Brand.good)
        } else if vs.contains(where: { if case .failed = $0.job { return true }; return false }) {
            Label("Failed", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
        } else if vs.allSatisfy({ if case .skipped = $0.job { return true }; return false }) {
            Label("Left as it is", systemImage: "arrow.uturn.backward.circle").font(.caption).foregroundStyle(.secondary)
        } else if let e = item.inspectError {
            Text(e).foregroundStyle(.red).font(.caption).lineLimit(1)
        } else if let s = item.source {
            Text("\(Fmt.bytes(s.media.fileSize)) · \(Fmt.duration(s.media.duration))").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Analysing…").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// "12 videos · 3 done · 4.1 GB → 610 MB" at the foot of the list.
struct QueueSummary: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let done = model.items.flatMap(\.results)
        let queued = model.items.reduce(0) { $0 + $1.versions.filter { $0.job.isActive }.count }
        let before = model.items.compactMap { $0.results.first?.originalBytes }.reduce(0, +), after = done.reduce(Int64(0)) { $0 + $1.outputBytes }
        VStack(spacing: 2) {
            if model.items.count > 1 {
                Text("\(model.items.count) videos · \(done.count) file\(done.count == 1 ? "" : "s") made" + (queued > 0 ? " · \(queued) to go" : ""))
                if !done.isEmpty { Text("\(Fmt.bytes(before)) → \(Fmt.bytes(after))").foregroundStyle(Brand.dawn) }
            }
            if model.prefs.totalSavedBytes > 0 {
                Text("Cirrus has saved you \(Fmt.bytes(model.prefs.totalSavedBytes))").foregroundStyle(.secondary).padding(.top, 2)
            }
        }
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
}
