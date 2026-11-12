import Foundation

/// Decisions are cached per (video, settings) for the session, so previewing
/// and then compressing doesn't repeat the optimisation work.
actor DecisionCache {
    private var store: [String: EncodeDecision] = [:]
    private var samples: [String: SampleSet] = [:]
    private var ceilings: [String: TextLegibilityReport] = [:]
    func get(_ k: String) -> EncodeDecision? { store[k] }
    func set(_ k: String, _ d: EncodeDecision) { store[k] = d; if store.count > 64 { store.removeAll() } }
    /// Sample scenes are shared by every option with the same filters and size (Preview Studio).
    func sample(_ k: String) -> SampleSet? {
        guard let s = samples[k], FileManager.default.fileExists(atPath: s.url.path) else { samples[k] = nil; return nil }
        return s
    }
    func setSample(_ k: String, _ s: SampleSet) { samples[k] = s; if samples.count > 32 { samples.removeAll() } }
    /// Near-lossless text reference per video, encoder and filters.
    func ceiling(_ k: String) -> TextLegibilityReport? { ceilings[k] }
    func setCeiling(_ k: String, _ r: TextLegibilityReport) { ceilings[k] = r }
    static func key(_ item: SourceItem, _ s: CompressionSettings) -> String { "\(item.id.uuidString)-\(s.hashValue)" }
}

public struct PreviewResult: Sendable {
    public var encodedURL: URL
    public var referenceURL: URL
    public var start: Double
    public var duration: Double
    public var kbps: Double
    public var quality: QualityReport?
    /// Estimated whole-file size (from sample trials or the size target).
    public var predictedBytes: Int64?
    public var outputSize: PixelSize
    public var summary: String
    public var notes: [String]
    public var warnings: [String]
}

extension CompressionEngine {
    /// Encode a few seconds around `time` with exactly the settings the full
    /// job would use, and measure them, so the user can inspect before committing.
    public func preview(_ item: SourceItem, settings: CompressionSettings, at time: Double, length: Double = 4,
                        workspace: TempWorkspace, progress: @escaping @Sendable (Double, String) -> Void) async throws -> PreviewResult {
        let media = item.media
        let plan = try self.plan(item, settings: settings)
        let tracker = ProgressTracker { p in progress(p.fraction * 0.75, p.detail ?? p.stage.rawValue) }
        tracker.configure([(.sampling, 5), (.optimising, 60)])
        let decision = try await cachedDecision(item, plan: plan, settings: settings, workspace: workspace, tracker: tracker)

        let dur = min(length, media.duration)
        let start = min(max(0, time - dur / 2), max(0, media.duration - dur))
        let ref = workspace.file("preview-ref-\(Int(start * 1000)).mkv")
        let enc = workspace.file("preview-\(Int(start * 1000))-\(UUID().uuidString.prefix(4)).mkv")
        let run = FFmpegRun(tools: tools)
        progress(0.76, "Encoding preview")
        try await run.run(["-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", dur), "-i", media.url.path, "-map", "0:v:0",
                           "-vf", [decision.filters, "format=yuv420p10le"].compactMap { $0 }.joined(separator: ","),
                           "-c:v", "ffv1", "-level", "3", "-g", "1", ref.path], duration: dur)
        let e = EncoderRegistry.encoder(decision.encoder)
        switch decision.rate {
        case .constantQuality(let v):
            try await run.run(["-i", ref.path] + e.arguments(decision.params, rate: .quality(v), pass: .single, threads: nil) + [enc.path], duration: dur)
        case .twoPass(let kbps):
            let log = workspace.file("preview-pass").path
            if e.supportsTwoPass {
                try await run.run(["-i", ref.path] + e.arguments(decision.params, rate: .bitrate(kbps: kbps), pass: .first(logPrefix: log), threads: nil) + ["-f", "null", "-"], duration: dur)
            }
            try await run.run(["-i", ref.path] + e.arguments(decision.params, rate: .bitrate(kbps: kbps), pass: e.supportsTwoPass ? .second(logPrefix: log) : .single, threads: nil) + [enc.path], duration: dur)
        }
        progress(0.9, "Measuring")
        var q: QualityReport? = nil
        if caps.hasVMAF {
            q = try? await QualityMeter(tools: tools).measure(reference: ref, referenceFilters: nil, distorted: enc, size: decision.outputSize,
                                                              fps: decision.params.frameRate, duration: dur, scope: .samples, workspace: workspace)
        }
        let bytes = Double(Self.fileSize(enc))
        var predicted: Int64? = nil
        if case .targetSize(let b) = settings.goal, case .twoPass = decision.rate { predicted = b }
        else if let t = decision.sampleTrial {
            predicted = Int64((t.kbps + Double(decision.audio.bitrateKbps)) * 1000 / 8 * media.duration * 1.01)
        }
        progress(1, "Ready")
        return PreviewResult(encodedURL: enc, referenceURL: ref, start: start, duration: dur, kbps: bytes * 8 / dur / 1000, quality: q,
                             predictedBytes: predicted, outputSize: decision.outputSize, summary: Self.describe(decision),
                             notes: decision.notes, warnings: decision.warnings)
    }

    func cachedDecision(_ item: SourceItem, plan: EncodePlan, settings: CompressionSettings, workspace: TempWorkspace,
                        tracker: ProgressTracker) async throws -> EncodeDecision {
        let key = DecisionCache.key(item, settings)
        if let d = await decisionCache.get(key) { return d }
        let d = try await decide(item, plan: plan, settings: settings, workspace: workspace, tracker: tracker)
        await decisionCache.set(key, d)
        return d
    }
}
