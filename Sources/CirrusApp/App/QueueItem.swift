import SwiftUI
import CirrusCore

enum JobState {
    case idle, queued
    case running(JobProgress)
    case done(CompressionResult)
    /// Deliberately not compressed (would save too little); the original is untouched.
    case skipped(String)
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self { case .queued, .running: return true; default: return false }
    }
    var isFinished: Bool {
        switch self { case .done, .skipped: return true; default: return false }
    }
}

/// One file Cirrus will make from a video: its settings and its own job.
@MainActor @Observable
final class OutputVersion: Identifiable {
    let id = UUID()
    var settings: CompressionSettings
    var job: JobState = .idle
    /// Why this version exists, when it came from a quick add ("Fit for email").
    var purpose: String?
    @ObservationIgnored var runningTask: Task<Result<CompressionResult, Error>, Never>?
    @ObservationIgnored var cancelRequested = false

    init(settings: CompressionSettings, purpose: String? = nil) { self.settings = settings; self.purpose = purpose }

    /// Can still be changed or queued.
    var isEditable: Bool { !job.isActive && !job.isFinished }

    func cancel() {
        switch job {
        case .queued: job = .idle
        case .running:
            cancelRequested = true
            runningTask?.cancel()
        default: break
        }
    }
}

/// A video in the list, and the versions Cirrus will make of it (always at least one).
@MainActor @Observable
final class QueueItem: Identifiable {
    let id = UUID()
    let url: URL
    var source: SourceItem?
    var inspectError: String?
    var thumbnail: CGImage?
    var detectedKind: ContentKind?
    var versions: [OutputVersion]
    var selectedVersionID: OutputVersion.ID
    /// Shown above the settings after something changed them ("Now using B: …").
    var appliedNote: String?
    /// Preview Studio frames, by settings and moment, so reopening it is instant.
    @ObservationIgnored var studioFrames: [String: CGImage] = [:]
    /// Measured anchor for the size estimates in the settings panel.
    var estimate: EstimateState = .none
    @ObservationIgnored var estimateTask: Task<Void, Never>?

    enum EstimateState {
        case none, running
        case ready(Estimate)
        case failed
    }

    /// A light sample search at `settings`, used to scale estimates for every other choice.
    struct Estimate {
        var settings: CompressionSettings
        var plan: EncodePlan
        var evaluation: StudioEvaluation
    }

    init(url: URL, settings: CompressionSettings) {
        self.url = url
        var s = settings
        // content profile is per-video; never inherit a manual override from the last video
        s.advanced.profile = nil
        let v = OutputVersion(settings: s)
        versions = [v]
        selectedVersionID = v.id
    }

    var name: String { url.lastPathComponent }

    /// The version shown in the detail pane.
    var current: OutputVersion { versions.first { $0.id == selectedVersionID } ?? versions[0] }

    /// Settings of the version being edited.
    var settings: CompressionSettings {
        get { current.settings }
        set { current.settings = newValue }
    }

    var hasVersions: Bool { versions.count > 1 }
    var isActive: Bool { versions.contains { $0.job.isActive } }
    var isFinished: Bool { versions.allSatisfy { $0.job.isFinished } }
    /// Versions that still need making.
    var pendingVersions: [OutputVersion] { versions.filter(\.isEditable) }
    var results: [CompressionResult] { versions.compactMap { if case .done(let r) = $0.job { return r }; return nil } }

    func letter(_ v: OutputVersion) -> String {
        let i = versions.firstIndex { $0.id == v.id } ?? 0
        return i < 26 ? String(UnicodeScalar(65 + i)!) : "\(i + 1)"
    }

    @discardableResult
    func addVersion(_ s: CompressionSettings, purpose: String? = nil, select: Bool = true) -> OutputVersion {
        var s = s
        s.advanced.profile = settings.advanced.profile
        let v = OutputVersion(settings: s, purpose: purpose)
        versions.append(v)
        if select { selectedVersionID = v.id }
        return v
    }

    func removeVersion(_ v: OutputVersion) {
        guard versions.count > 1 else { return }
        v.cancel()
        let i = versions.firstIndex { $0.id == v.id } ?? 0
        versions.removeAll { $0.id == v.id }
        if selectedVersionID == v.id { selectedVersionID = versions[max(0, i - 1)].id }
    }

    /// Replace the version list with these settings (finished versions are kept).
    func setVersions(_ list: [CompressionSettings]) {
        let profile = settings.advanced.profile
        let kept = versions.filter { !$0.isEditable }
        versions = kept + list.map { var s = $0; s.advanced.profile = profile; return OutputVersion(settings: s) }
        if versions.isEmpty { versions = [OutputVersion(settings: CompressionSettings())] }
        selectedVersionID = (versions.first(where: \.isEditable) ?? versions[0]).id
    }

    func cancel() { for v in versions { v.cancel() } }

    /// Live plan preview for the settings panel (pure computation, instant).
    func plan(with engine: CompressionEngine?) -> Result<EncodePlan, Error>? { plan(for: settings, engine: engine) }

    func plan(for s: CompressionSettings, engine: CompressionEngine?) -> Result<EncodePlan, Error>? {
        guard let engine, let source else { return nil }
        do { return .success(try engine.plan(source, settings: s)) } catch { return .failure(error) }
    }
}
