import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CirrusCore

/// Summary of a batch: totals, then one row per video, exportable as CSV.
struct BatchReportView: View {
    var batch: BatchRecord
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var restoreNote: String?
    @State private var confirmRestore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(batch.finished == nil ? "Batch in progress" : "Batch finished").font(.title2.weight(.light))
                    Text(subtitle).foregroundStyle(.secondary)
                }
                Spacer()
                if !batch.restorable.isEmpty {
                    Button("Restore Originals…") { confirmRestore = true }
                        .confirmationDialog("Restore \(batch.restorable.count) originals?", isPresented: $confirmRestore, titleVisibility: .visible) {
                            Button("Restore Originals") {
                                let r = model.restoreOriginals()
                                restoreNote = "\(r.restored) original\(r.restored == 1 ? "" : "s") restored; the compressed copies are in the Trash." + (r.problems.isEmpty ? "" : " " + r.problems.joined(separator: " "))
                            }
                        } message: { Text("Each original comes back from the Trash to where it was, and its compressed copy goes to the Trash.") }
                }
                Button("Export CSV…") { export() }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 18) {
                StatTile(title: "Compressed", value: "\(batch.compressed.count) of \(batch.entries.count)")
                StatTile(title: "Before", value: Fmt.bytes(batch.totalOriginal))
                StatTile(title: "After", value: Fmt.bytes(batch.totalOutput))
                StatTile(title: "Saved", value: Fmt.bytes(max(0, batch.saved)),
                         caption: batch.totalOriginal > 0 ? String(format: "%.0f%% less space", Double(batch.saved) / Double(batch.totalOriginal) * 100) : nil,
                         tint: Brand.dawn)
            }
            .padding(14)
            .background(Brand.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

            Table(batch.entries) {
                TableColumn("Video") { e in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.name).lineLimit(1).truncationMode(.middle)
                        Text(e.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }.width(min: 200, ideal: 260)
                TableColumn("Result") { e in
                    Label(e.status.rawValue, systemImage: symbol(e.status)).foregroundStyle(tint(e.status))
                }.width(100)
                TableColumn("Before") { e in Text(Fmt.bytes(e.originalBytes)).monospacedDigit() }.width(80)
                TableColumn("After") { e in Text(e.outputBytes.map(Fmt.bytes) ?? "—").monospacedDigit() }.width(80)
                TableColumn("Saved") { e in
                    Text(e.outputBytes.map { String(format: "%.0f%%", (1 - Double($0) / Double(max(1, e.originalBytes))) * 100) } ?? "—").monospacedDigit()
                }.width(56)
                TableColumn("Quality") { e in Text(e.vmaf.map { String(format: "VMAF %.1f", $0) } ?? "—").monospacedDigit() }.width(84)
                TableColumn("Text") { e in Text(e.textAccuracy.map { String(format: "%.0f%%", $0 * 100) } ?? "—").monospacedDigit() }.width(48)
                TableColumn("Notes") { e in Text(e.note).foregroundStyle(.secondary).lineLimit(2).help(e.note) }
            }
            .frame(minHeight: 280)
            if let n = restoreNote { InfoRow(systemImage: "arrow.uturn.backward.circle.fill", text: n, tint: Brand.good) }
            if batch.outputMode == .replaceOriginals {
                InfoRow(systemImage: "trash", text: "Originals of compressed videos are in the Trash. Skipped and failed videos kept their originals.")
            }
        }
        .padding(22)
        .frame(minWidth: 940, minHeight: 560)
    }

    var subtitle: String {
        let end = batch.finished ?? Date()
        return "\(batch.entries.count) videos · \(Fmt.eta(end.timeIntervalSince(batch.started)))"
    }

    func symbol(_ s: BatchRecord.Status) -> String {
        switch s { case .compressed: return "checkmark.circle.fill"; case .skipped: return "arrow.uturn.backward.circle"
        case .failed: return "exclamationmark.triangle.fill"; case .cancelled: return "xmark.circle" }
    }
    func tint(_ s: BatchRecord.Status) -> Color {
        switch s { case .compressed: return Brand.good; case .skipped: return Brand.accent; case .failed: return .red; case .cancelled: return .secondary }
    }

    func export() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.commaSeparatedText]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        p.nameFieldStringValue = "Cirrus batch \(f.string(from: batch.started)).csv"
        if p.runModal() == .OK, let u = p.url { try? batch.csv().write(to: u, atomically: true, encoding: .utf8) }
    }
}
