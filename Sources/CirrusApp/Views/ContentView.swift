import SwiftUI
import CirrusCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            VStack(spacing: 0) {
                Banners()
                ZStack {
                    if case .failed(let msg) = model.engineState {
                        EngineMissingView(message: msg)
                    } else if let item = model.selected {
                        ItemDetailView(item: item).id(item.id)
                    } else {
                        DropZoneView(isTargeted: dropTargeted) { model.presentOpenPanel() }
                            .padding(36)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls: urls); return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.presentOpenPanel() } label: { Label("Add Videos", systemImage: "plus") }
                    .help("Add videos or folders (⌘O)")
                if model.items.count > 1 {
                    PresetMenu(targets: model.items.filter { !$0.isActive }, label: "Preset for All")
                    Button { model.compressAll() } label: {
                        Label(model.prefs.outputMode == .replaceOriginals ? "Compress All and Replace" : "Compress All",
                              systemImage: "square.stack.3d.down.forward")
                    }
                    .help("Compress every video in the list that isn’t done yet (⇧⌘↩)")
                    .disabled(model.compressibleItems.isEmpty)
                }
                if model.batch?.entries.isEmpty == false {
                    Button { model.showBatchReport = true } label: { Label("Batch Report", systemImage: "list.bullet.rectangle") }
                        .help("What happened to each video in the last batch")
                }
            }
        }
        .alert(item: $model.alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        .confirmationDialog(replaceTitle, isPresented: Binding(get: { model.replaceConfirmation != nil }, set: { if !$0 { model.replaceConfirmation = nil } }),
                            titleVisibility: .visible) {
            Button("Compress and Replace", role: .destructive) { model.confirmReplace() }
            Button("Cancel", role: .cancel) { model.replaceConfirmation = nil }
        } message: {
            Text("Each original goes to the Trash only after its compressed copy is finished, checked (it plays, has the same length and sound, and is smaller) and in place with the original’s name and dates. Videos that wouldn’t get smaller are left alone. Other files and folders aren’t touched.")
        }
        .sheet(isPresented: $model.showBatchReport) { if let b = model.batch { BatchReportView(batch: b).environment(model) } }
        .overlay {
            if dropTargeted && model.selected != nil {
                RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Brand.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .onAppear { Notifier.requestPermission() }
        .onChange(of: model.selection) { _, _ in if let s = model.selected { model.ensureEstimate(s) } }
    }

    var replaceTitle: String {
        let n = model.replaceConfirmation?.count ?? 0
        return "Replace \(n) original\(n == 1 ? "" : "s") with compressed versions?"
    }
}

/// Notices above the detail pane: skipped files, a batch to resume.
struct Banners: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 0) {
            if let offer = model.resumeOffer {
                Banner(symbol: "arrow.clockwise.circle.fill", tint: Brand.accent,
                       text: "\(offer.count) video\(offer.count == 1 ? " was" : "s were") still waiting to be compressed when Cirrus last closed.") {
                    Button("Resume") { model.resumeSavedQueue() }.buttonStyle(.borderedProminent).tint(Brand.accent)
                    Button("Dismiss") { model.dismissResume() }
                }
            }
            if let n = model.skipNotice {
                Banner(symbol: "line.3.horizontal.decrease.circle.fill", tint: .secondary, text: n.summary) {
                    Button("Add Anyway") { model.addSkippedAnyway() }
                    Button("OK") { model.skipNotice = nil }
                }
            }
        }
    }

    struct Banner<Buttons: View>: View {
        var symbol: String; var tint: Color; var text: String
        @ViewBuilder var buttons: Buttons
        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer()
                buttons.controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Brand.accent.opacity(0.06))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

struct EngineMissingView: View {
    var message: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
            Text("The encoding engine couldn’t start").font(.title2.weight(.semibold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Text("Reinstalling Cirrus Video Compressor usually fixes this.").font(.callout).foregroundStyle(.tertiary)
        }.padding(40)
    }
}
