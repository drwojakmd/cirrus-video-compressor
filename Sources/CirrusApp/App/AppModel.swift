import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CirrusCore

/// Application state: the engine, the queue of videos and preferences.
@MainActor @Observable
final class AppModel {
    static weak var shared: AppModel?

    enum EngineState { case loading, ready(CompressionEngine), failed(String) }

    var engineState: EngineState = .loading
    var items: [QueueItem] = []
    var selection: QueueItem.ID?
    var prefs = Preferences.load()
    var alert: AlertInfo?
    /// Videos left out when a folder was added (shown as a banner with "Add Anyway").
    var skipNotice: SkipNotice?
    /// Videos waiting for the user to confirm "Replace originals".
    var replaceConfirmation: [QueueItem]?
    /// Unfinished videos from the previous session.
    var resumeOffer: [SavedQueue.Entry]?
    /// The batch in progress or just finished.
    var batch: BatchRecord?
    var showBatchReport = false

    private var runner: Task<Void, Never>?
    private var inspectQueue: [QueueItem] = []
    private var inspecting = 0
    private var activity: NSObjectProtocol?

    struct AlertInfo: Identifiable { let id = UUID(); var title: String; var message: String }
    struct SkipNotice: Identifiable {
        let id = UUID()
        var added: Int
        var skipped: [(url: URL, reason: VideoScanner.SkipReason)]
        var summary: String {
            let outputs = skipped.filter { $0.reason == .cirrusOutput }.count
            let copies = skipped.count - outputs
            var parts: [String] = []
            if outputs > 0 { parts.append("\(outputs) already compressed by Cirrus") }
            if copies > 0 { parts.append("\(copies) with a compressed copy next to \(copies == 1 ? "it" : "them")") }
            return "Added \(added) video\(added == 1 ? "" : "s"). Skipped \(skipped.count): " + parts.joined(separator: ", ") + "."
        }
    }

    init() { AppModel.shared = self }

    var engine: CompressionEngine? { if case .ready(let e) = engineState { return e }; return nil }
    var selected: QueueItem? { items.first { $0.id == selection } }
    var isBusy: Bool { items.contains { $0.isActive } }
    var canCompressSelected: Bool { selected.map { $0.source != nil && !$0.pendingVersions.isEmpty } ?? false }
    var compressibleItems: [QueueItem] { items.filter { $0.source != nil && !$0.pendingVersions.isEmpty } }

    func start() async {
        guard engine == nil else { return }
        do {
            engineState = .ready(try await CompressionEngine.make())
            for item in items where item.source == nil { scheduleInspect(item) }
        } catch {
            engineState = .failed(error.localizedDescription)
        }
        if let saved = SavedQueue.load() {
            let pending = saved.entries.filter { $0.pending && FileManager.default.fileExists(atPath: $0.url.path) }
            if !pending.isEmpty { resumeOffer = pending } else { SavedQueue.clear() }
        }
    }

    // MARK: adding

    func add(urls: [URL], skipExisting: Bool = true, settings: CompressionSettings? = nil) {
        let scan = VideoScanner.scan(urls, skipExisting: skipExisting)
        var firstNew: QueueItem?
        var added = 0
        for u in scan.videos where !items.contains(where: { $0.url.standardizedFileURL == u.standardizedFileURL }) {
            let item = QueueItem(url: u, settings: settings ?? prefs.settings)
            items.append(item)
            added += 1
            if firstNew == nil { firstNew = item }
            scheduleInspect(item)
        }
        if let f = firstNew { selection = f.id }
        if !scan.skipped.isEmpty { skipNotice = SkipNotice(added: added, skipped: scan.skipped) }
        if scan.videos.isEmpty && scan.skipped.isEmpty && !urls.isEmpty {
            alert = AlertInfo(title: scan.foldersScanned > 0 ? "No videos found" : "Not a video",
                              message: scan.foldersScanned > 0 ? "The folder doesn’t contain any video files Cirrus can open."
                                  : "Cirrus Video Compressor can open MP4, MOV, MKV, WebM, AVI and most other video files.")
        }
        saveQueue()
    }

    func addSkippedAnyway() {
        guard let n = skipNotice else { return }
        skipNotice = nil
        add(urls: n.skipped.map(\.url), skipExisting: false)
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi] + ["mkv", "webm"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Add"
        panel.message = "Choose videos, or folders to add every video inside them (subfolders included)."
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    /// Analysis runs two videos at a time, so dropping a folder of hundreds stays responsive.
    func scheduleInspect(_ item: QueueItem) {
        guard engine != nil else { return }
        inspectQueue.append(item)
        pumpInspections()
    }

    private func pumpInspections() {
        while inspecting < 2, !inspectQueue.isEmpty {
            let item = inspectQueue.removeFirst()
            guard items.contains(where: { $0.id == item.id }) else { continue }
            inspecting += 1
            Task {
                await inspect(item)
                inspecting -= 1
                pumpInspections()
            }
        }
    }

    func inspect(_ item: QueueItem) async {
        guard let engine else { return }
        item.inspectError = nil
        do {
            let src = try await engine.inspect(item.url)
            item.source = src
            if item.settings.advanced.profile == nil { item.detectedKind = src.analysis.kind }
            item.thumbnail = try? await FrameGrabber(tools: engine.tools).frame(item.url, at: min(src.media.duration * 0.15, 30), maxDimension: 960)
            if item.id == selection { ensureEstimate(item) }
        } catch {
            item.inspectError = error.localizedDescription
        }
    }

    func remove(_ item: QueueItem) {
        if item.isActive { item.cancel() }
        item.estimateTask?.cancel()
        items.removeAll { $0.id == item.id }
        if selection == item.id { selection = items.first?.id }
        saveQueue()
    }

    func clearFinished() {
        items.removeAll { $0.isFinished }
        if selected == nil { selection = items.first?.id }
        saveQueue()
    }

    // MARK: settings

    /// Copy one video's settings to every video in the list (or only `targets`), except
    /// per-video content-type overrides. Videos already compressing keep theirs.
    func applySettings(_ s: CompressionSettings, to targets: [QueueItem]? = nil) -> Int {
        var n = 0
        for item in targets ?? items where item.current.isEditable {
            let profile = item.settings.advanced.profile
            item.settings = s
            item.settings.advanced.profile = profile
            n += 1
        }
        prefs.settings = s
        prefs.save()
        saveQueue()
        return n
    }

    func apply(_ preset: Preset, to targets: [QueueItem]?) {
        prefs.selectedPresetID = preset.id
        if let list = preset.versions, list.count > 1 {
            for item in targets ?? items where !item.isActive { item.setVersions(list) }
            prefs.settings = list[0]; prefs.save(); saveQueue()
        } else {
            _ = applySettings(preset.settings, to: targets)
        }
    }

    /// Give other videos the same set of versions as `item` (finished versions stay).
    @discardableResult
    func applyVersions(of item: QueueItem, to targets: [QueueItem]? = nil) -> Int {
        let list = item.versions.map(\.settings)
        var n = 0
        for t in targets ?? items where t.id != item.id && !t.isActive { t.setVersions(list); n += 1 }
        saveQueue()
        return n + 1
    }

    func savePreset(named name: String, from s: CompressionSettings, versions: [CompressionSettings]? = nil) {
        var p = Preset(name: name, settings: s)
        if let v = versions, v.count > 1 { p.versions = v.map { var c = $0; c.advanced.profile = nil; return c } }
        p.settings.advanced.profile = nil
        prefs.presets.append(p)
        prefs.selectedPresetID = p.id
        prefs.save()
    }

    func deletePreset(_ p: Preset) {
        prefs.presets.removeAll { $0.id == p.id }
        if prefs.selectedPresetID == p.id { prefs.selectedPresetID = nil }
        prefs.save()
    }

    // MARK: versions

    /// Another version of the same video, selected for editing.
    @discardableResult
    func addVersion(to item: QueueItem, settings: CompressionSettings? = nil, purpose: String? = nil) -> OutputVersion {
        let v = item.addVersion(settings ?? item.settings, purpose: purpose)
        item.appliedNote = nil
        saveQueue()
        return v
    }

    var macDecodesAV1: Bool { engine?.caps.systemDecodesAV1 ?? false }

    // MARK: estimates

    /// One light sample search per video (only while nothing is compressing), so the
    /// settings panel can show sizes; every other choice is scaled from it.
    func ensureEstimate(_ item: QueueItem) {
        guard let engine, let source = item.source, !isBusy else { return }
        if case .none = item.estimate {} else if case .failed = item.estimate {} else { return }
        var s = item.settings
        if case .targetSize = s.goal { s.goal = .quality(.balanced) }
        guard let plan = try? engine.plan(source, settings: s) else { return }
        item.estimate = .running
        item.estimateTask = Task {
            do {
                let ws = try TempWorkspace(label: "estimate")
                defer { ws.remove() }
                let e = try await engine.evaluate(source, settings: s, workspace: ws) { _, _ in }
                item.estimate = .ready(.init(settings: s, plan: plan, evaluation: e))
            } catch {
                item.estimate = Task.isCancelled ? .none : .failed
            }
        }
    }

    // MARK: queue

    func compressSelected() { if let s = selected { requestCompress([s]) } }
    func compressAll() { requestCompress(compressibleItems) }
    func cancelSelected() { selected?.cancel() }

    /// Start (or queue) every version still to make for these videos, asking first when
    /// originals will be replaced.
    func requestCompress(_ list: [QueueItem]) {
        let ready = list.filter { $0.source != nil && !$0.pendingVersions.isEmpty }
        guard !ready.isEmpty else { return }
        if prefs.outputMode == .replaceOriginals {
            if let multi = ready.first(where: \.hasVersions) {
                alert = AlertInfo(title: "Several versions can’t replace one original",
                                  message: "“\(multi.name)” has \(multi.versions.count) versions, but only one file can take the original’s place. Remove the extra versions, or choose “Save Next to the Original”.")
                return
            }
            replaceConfirmation = ready; return
        }
        for i in ready { enqueue(i) }
    }

    /// Compress just one version of a video.
    func requestCompress(_ v: OutputVersion, of item: QueueItem) {
        guard item.source != nil, v.isEditable else { return }
        if prefs.outputMode == .replaceOriginals { requestCompress([item]); return }
        enqueue(item, only: [v])
    }

    func confirmReplace() {
        let list = replaceConfirmation ?? []
        replaceConfirmation = nil
        for i in list { enqueue(i) }
    }

    func enqueue(_ item: QueueItem, only: [OutputVersion]? = nil) {
        let list = (only ?? item.pendingVersions).filter(\.isEditable)
        guard item.source != nil, !list.isEmpty else { return }
        prefs.settings = item.versions[0].settings
        prefs.save()
        // estimates would compete with the encoder for the CPU
        for i in items { if case .running = i.estimate { i.estimateTask?.cancel(); i.estimate = .none } }
        for v in list { v.job = .queued }
        saveQueue()
        startRunner()
    }

    func resumeSavedQueue() {
        guard let entries = resumeOffer else { return }
        resumeOffer = nil
        var seen: [URL: QueueItem] = [:]
        for e in entries {
            if let item = seen[e.url] { item.addVersion(e.settings, select: false); continue }
            add(urls: [e.url], skipExisting: false, settings: e.settings)
            seen[e.url] = items.first { $0.url == e.url }
        }
        // queue them once analysed
        Task {
            for _ in 0..<600 {
                let pending = items.filter { i in entries.contains { $0.url == i.url } }
                if pending.allSatisfy({ $0.source != nil || $0.inspectError != nil }) {
                    for i in pending where i.source != nil { enqueue(i) }
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func dismissResume() { resumeOffer = nil; SavedQueue.clear() }

    private func startRunner() {
        guard runner == nil else { return }
        if batch == nil || batch?.finished != nil { batch = BatchRecord(started: Date(), outputMode: prefs.outputMode) }
        // Keep the Mac awake (the display may sleep) until the queue is empty.
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                         reason: "Compressing videos")
        runner = Task { [weak self] in
            // One job at a time: every encoder here already uses all CPU cores.
            while let self, let next = self.nextQueued() {
                await self.run(next.0, next.1)
                self.saveQueue()
            }
            self?.runnerFinished()
        }
    }

    private var batchDone = 0

    private func nextQueued() -> (QueueItem, OutputVersion)? {
        for i in items { for v in i.versions { if case .queued = v.job { return (i, v) } } }
        return nil
    }
    private var queuedCount: Int { items.reduce(0) { $0 + $1.versions.filter { if case .queued = $0.job { return true }; return false }.count } }

    /// Batch progress on the Dock icon: finished jobs plus the current one, over all jobs in the batch.
    func updateDock(current: Double) {
        let queued = queuedCount
        let total = batchDone + 1 + queued
        DockProgress.shared.set((Double(batchDone) + current) / Double(max(1, total)))
    }

    private func runnerFinished() {
        DockProgress.shared.set(nil)
        runner = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        guard var b = batch else { return }
        b.finished = Date()
        batch = b
        if b.entries.count >= 2 {
            showBatchReport = true
            if prefs.notifyWhenDone { Notifier.post(title: "Batch finished", body: b.headline) }
        }
        if !items.contains(where: { $0.isActive }) { SavedQueue.clear() }
        if let s = selected { ensureEstimate(s) }
    }

    private func run(_ item: QueueItem, _ version: OutputVersion) async {
        guard let engine, let source = item.source else { version.job = .failed("Not ready"); return }
        let mode = prefs.outputMode
        let dest = destination(for: item)
        let label: String? = item.hasVersions ? version.settings.versionLabel(macDecodesAV1: macDecodesAV1) : nil
        batchDone = batch?.entries.count ?? 0
        version.job = .running(.idle)
        let settings = version.settings
        let throttle = Throttle()
        let task = Task.detached(priority: .userInitiated) { () -> Result<CompressionResult, Error> in
            do {
                var r = try await engine.compress(source, settings: settings, destinationDirectory: dest, versionLabel: label) { p in
                    guard throttle.allow(p) else { return }
                    Task { @MainActor in
                        if case .running = version.job { version.job = .running(p) }
                        AppModel.shared?.updateDock(current: p.fraction)
                    }
                }
                if mode == .replaceOriginals {
                    do {
                        let o = try await OriginalReplacer(tools: engine.tools).replace(
                            original: source.media, compressed: r.outputURL,
                            expectAudio: !source.media.audio.isEmpty && r.audioSummary != AudioPlan.none.summary)
                        r.outputURL = o.finalURL
                        r.trashedOriginal = o.trashedOriginal
                        r.notes.insert("Original moved to the Trash. The compressed file took its place\(o.finalURL.lastPathComponent == source.media.url.lastPathComponent ? "" : " as \(o.finalURL.lastPathComponent)").", at: 0)
                        if let n = o.note { r.notes.append(n) }
                    } catch {
                        r.warnings.insert("The original was kept: \(error.localizedDescription)", at: 0)
                    }
                }
                return .success(r)
            } catch { return .failure(error) }
        }
        version.runningTask = task
        let result = await task.value
        version.runningTask = nil
        switch result {
        case .success(let r):
            version.job = .done(r)
            prefs.totalSavedBytes += max(0, r.originalBytes - r.outputBytes)
            prefs.save()
            batch?.entries.append(.init(item: item, version: version, result: r))
            if prefs.notifyWhenDone && (batch?.entries.count ?? 0) < 2 && queuedCount == 0 {
                Notifier.notify(r)
            }
        case .failure(let e):
            if case CirrusError.notWorthIt(let why) = e {
                version.job = .skipped(why)
                batch?.entries.append(.init(item: item, version: version, status: .skipped, note: why))
            } else if (e as? CirrusError) == .cancelled || Task.isCancelled || version.cancelRequested {
                version.job = .cancelled
                batch?.entries.append(.init(item: item, version: version, status: .cancelled, note: "Cancelled"))
            } else {
                version.job = .failed(e.localizedDescription)
                batch?.entries.append(.init(item: item, version: version, status: .failed, note: e.localizedDescription))
            }
        }
        version.cancelRequested = false
    }

    /// Where results go: the source's folder by default (and in Replace mode), or the chosen
    /// folder. Falls back to ~/Movies if the source folder isn't writable.
    func destination(for source: URL) -> URL {
        if prefs.outputMode == .folder, let f = prefs.outputFolder, FileManager.default.isWritableFile(atPath: f.path) { return f }
        let dir = source.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: dir.path) { return dir }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Cirrus Video Compressor")
        try? FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        return movies
    }

    /// As above, inside "<name> versions" when the video has several versions and that option is on.
    func destination(for item: QueueItem, create: Bool = true) -> URL {
        let base = destination(for: item.url)
        guard item.hasVersions, prefs.versionsInOwnFolder, prefs.outputMode != .replaceOriginals else { return base }
        let sub = base.appendingPathComponent(item.url.deletingPathExtension().lastPathComponent + " versions", isDirectory: true)
        if create { try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true) }
        return sub
    }

    func saveQueue() {
        let entries = items.flatMap { i in i.versions.map { SavedQueue.Entry(url: i.url, settings: $0.settings, pending: $0.job.isActive) } }
        if entries.contains(where: \.pending) { SavedQueue(entries: entries, outputMode: prefs.outputMode).save() }
        else if resumeOffer == nil { SavedQueue.clear() }
    }

    /// Undo "Replace originals" for the last batch: originals back from the Trash, copies to the Trash.
    func restoreOriginals() -> (restored: Int, problems: [String]) {
        guard var b = batch else { return (0, []) }
        var n = 0, problems: [String] = []
        for i in b.entries.indices {
            let e = b.entries[i]
            guard let t = e.trashedOriginal, !e.restored, let out = e.outputPath else { continue }
            do {
                try OriginalReplacer.restore(original: URL(fileURLWithPath: e.originalPath), from: t, compressed: URL(fileURLWithPath: out))
                b.entries[i].restored = true; n += 1
            } catch { problems.append("\(e.name): \(error.localizedDescription)") }
        }
        batch = b
        return (n, problems)
    }

    func revealLog() {
        if let u = Log.logFileURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }
}

/// What happened to each video in a batch, for the summary report and CSV export.
struct BatchRecord {
    enum Status: String { case compressed = "Compressed", skipped = "Skipped", failed = "Failed", cancelled = "Cancelled" }
    struct Entry: Identifiable {
        let id = UUID()
        var name: String
        var folder: String
        var status: Status
        var originalBytes: Int64
        var outputBytes: Int64?
        var outputPath: String?
        var vmaf: Double?
        var textAccuracy: Double?
        var seconds: Double?
        var note: String

        var originalPath: String
        var trashedOriginal: URL?
        var restored = false

        @MainActor init(item: QueueItem, version: OutputVersion, result r: CompressionResult) {
            name = Self.name(item, version); folder = item.url.deletingLastPathComponent().path; status = .compressed
            originalPath = item.url.path; trashedOriginal = r.trashedOriginal
            originalBytes = r.originalBytes; outputBytes = r.outputBytes; outputPath = r.outputURL.path
            vmaf = r.quality?.vmaf; textAccuracy = r.textCheck?.accuracy; seconds = r.elapsed
            note = (r.warnings + r.notes.prefix(1)).first ?? ""
        }
        @MainActor init(item: QueueItem, version: OutputVersion, status: Status, note: String) {
            name = Self.name(item, version); folder = item.url.deletingLastPathComponent().path; self.status = status
            originalPath = item.url.path
            originalBytes = item.source?.media.fileSize ?? 0; self.note = note
        }
        var saved: Int64 { outputBytes.map { originalBytes - $0 } ?? 0 }

        @MainActor static func name(_ item: QueueItem, _ v: OutputVersion) -> String {
            guard item.hasVersions else { return item.name }
            return "\(item.name) · \(item.letter(v)): \(v.settings.versionLabel(macDecodesAV1: AppModel.shared?.macDecodesAV1 ?? false))"
        }
    }
    var started: Date
    var finished: Date?
    var outputMode: Preferences.OutputMode
    var entries: [Entry] = []

    var compressed: [Entry] { entries.filter { $0.status == .compressed } }
    var totalOriginal: Int64 { compressed.reduce(0) { $0 + $1.originalBytes } }
    var totalOutput: Int64 { compressed.reduce(0) { $0 + ($1.outputBytes ?? 0) } }
    var saved: Int64 { totalOriginal - totalOutput }
    var headline: String {
        "\(compressed.count) of \(entries.count) videos compressed, \(Fmt.bytes(max(0, saved))) saved"
    }

    var restorable: [Entry] { entries.filter { $0.trashedOriginal != nil && !$0.restored } }

    func csv() -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["File,Folder,Status,Original bytes,Compressed bytes,Saved %,VMAF,Text read identically %,Seconds,Output,Note"]
        for e in entries {
            let pct = e.outputBytes.map { String(format: "%.1f", (1 - Double($0) / Double(max(1, e.originalBytes))) * 100) } ?? ""
            lines.append([q(e.name), q(e.folder), e.status.rawValue, "\(e.originalBytes)", e.outputBytes.map { "\($0)" } ?? "", pct,
                          e.vmaf.map { String(format: "%.2f", $0) } ?? "", e.textAccuracy.map { String(format: "%.1f", $0 * 100) } ?? "",
                          e.seconds.map { String(format: "%.0f", $0) } ?? "", q(e.outputPath ?? ""), q(e.note)].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Limits UI updates to ~8 per second (stage changes always pass).
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private var lastStage: JobStage?
    func allow(_ p: JobProgress) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if p.stage != lastStage || now.timeIntervalSince(last) > 0.12 { last = now; lastStage = p.stage; return true }
        return false
    }
}
