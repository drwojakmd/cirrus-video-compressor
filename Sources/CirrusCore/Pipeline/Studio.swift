import Foundation
import CoreGraphics

/// One evaluated option in the Preview Studio: what these settings would
/// produce for this video, measured on sample scenes.
public struct StudioEvaluation: Sendable {
    public var decision: EncodeDecision
    public var outputSize: PixelSize
    public var codec: VideoCodec
    public var summary: String
    /// Estimated size of the whole compressed video.
    public var predictedBytes: Int64
    /// Estimated wall-clock time to compress the whole video.
    public var estimatedSeconds: Double
    public var sampleVMAF: Double?
    public var textCheck: TextLegibilityReport?
    public var previewableOnThisMac: Bool
    public var notes: [String]
    public var warnings: [String]
}

extension CompressionEngine {
    /// Decide settings for `settings` with a light sample search (cached), and estimate size and time.
    public func evaluate(_ item: SourceItem, settings: CompressionSettings, workspace: TempWorkspace,
                         progress: @escaping @Sendable (Double, String) -> Void) async throws -> StudioEvaluation {
        let plan = try self.plan(item, settings: settings)
        let key = "light-" + DecisionCache.key(item, settings)
        let d: EncodeDecision
        if let full = await decisionCache.get(DecisionCache.key(item, settings)) { d = full }
        else if let cached = await decisionCache.get(key) { d = cached }
        else {
            let tracker = ProgressTracker { p in progress(p.fraction, p.detail ?? p.stage.rawValue) }
            tracker.configure([(.sampling, 3), (.optimising, 30)])
            d = try await decide(item, plan: plan, settings: settings, workspace: workspace, tracker: tracker, light: true)
            await decisionCache.set(key, d)
        }
        let D = item.media.duration
        let audioBytes = Double(d.audio.bitrateKbps) * 1000 / 8 * D
        var predicted: Double
        if case .targetSize(let b) = settings.goal, case .twoPass = d.rate { predicted = Double(b) * 0.97 }
        else if let t = d.sampleTrial { predicted = t.kbps * 1000 / 8 * D + audioBytes }
        else { predicted = Double(item.media.fileSize) * 0.5 }
        predicted += SizeMath.containerOverhead(duration: D, fps: d.params.frameRate, hasAudio: d.audio.codec != .none)
        let fps = d.sampleTrial?.encodeFPS ?? 30
        let frames = D * d.params.frameRate
        var secs = frames / max(1, fps)
        if case .twoPass = d.rate, EncoderRegistry.encoder(d.encoder).supportsTwoPass { secs *= 1.3 }
        if settings.measureQuality && caps.hasVMAF { secs += D * 0.25 }
        if settings.depth != .quick { secs += min(D * 3, 20 * 4) * 30 / max(1, fps) * 0.4 + 10 }
        return StudioEvaluation(decision: d, outputSize: d.outputSize, codec: d.encoder.codec, summary: Self.describe(d),
                                predictedBytes: Int64(predicted), estimatedSeconds: secs, sampleVMAF: d.sampleTrial?.quality.vmaf,
                                textCheck: d.textCheck, previewableOnThisMac: EncodePlanner.playsInQuickLook(d.encoder.codec, caps: caps),
                                notes: d.notes, warnings: d.warnings)
    }

    /// Settings predicted from the content analysis alone (no test encodes): what Preview Studio
    /// shows within seconds, before the measured decision replaces it.
    public func predictedDecision(_ item: SourceItem, settings: CompressionSettings) throws -> EncodeDecision {
        var s = settings
        s.depth = .quick
        let plan = try self.plan(item, settings: s)
        let rate: EncodeDecision.FinalRate
        switch plan.rate {
        case .fixedQuality(let v): rate = .constantQuality(v)
        case .searchQuality(_, let g): rate = .constantQuality(g)
        case .targetSize(_, let k): rate = .twoPass(kbps: k)
        }
        return EncodeDecision(encoder: plan.encoder, params: plan.params, outputSize: plan.outputSize, filters: plan.filterChain,
                              rate: rate, audio: plan.audio, sampleTrial: nil, notes: plan.notes, warnings: plan.warnings)
    }

    /// The frame at `time` as these settings would encode it: a clip leading up to `time`
    /// is encoded with the exact final encoder settings, and the frame at `time` (an
    /// ordinary predicted frame, 3 s after the keyframe) is returned at the output size.
    public func encodedFrame(_ item: SourceItem, decision d: EncodeDecision, at time: Double, workspace: TempWorkspace) async throws -> CGImage {
        // the shown frame sits 3 s into the clip, away from its keyframe, like most frames of the real file
        let start = max(0, min(time - 3, item.media.duration - 3.5))
        let out = workspace.file("studio-\(UUID().uuidString.prefix(6)).mkv")
        defer { try? FileManager.default.removeItem(at: out) }
        let enc = EncoderRegistry.encoder(d.encoder)
        let len = time - start + 0.5
        var a = ["-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", len), "-i", item.media.url.path, "-map", "0:v:0"]
        if let f = d.filters { a += ["-vf", f] }
        let rate: RateControl
        switch d.rate {
        case .constantQuality(let v): rate = .quality(v)
        case .twoPass(let k): rate = .bitrate(kbps: k)
        }
        try await FFmpegRun(tools: tools).run(a + enc.arguments(d.params, rate: rate, pass: .single, threads: nil) + ["-an", out.path], duration: len)
        return try await FrameGrabber(tools: tools).frame(out, at: time - start, exactSize: d.outputSize)
    }

    /// The original frame at `time`, deinterlaced like the encode, scaled to `size`.
    public func originalFrame(_ item: SourceItem, at time: Double, size: PixelSize) async throws -> CGImage {
        try await FrameGrabber(tools: tools).frame(item.media.url, at: time, exactSize: size,
                                                    filters: item.media.video.isInterlaced ? "bwdif=mode=send_frame" : nil)
    }
}

/// Fast size estimates for the settings panel: one measured anchor (a light sample
/// search at the current settings) scaled by ratios measured in the benchmark study
/// (Docs/ENCODING.md §4b). Every number shown from here is labelled as an estimate.
public enum SizeEstimator {
    /// Bitrate relative to Balanced (VMAF 93) for each quality level, median over the
    /// benchmark clips. [maximum, high, balanced, aggressive, maximumCompression]
    public static func levelFactor(_ l: QualityLevel, synthetic: Bool) -> Double {
        let camera = [1.50, 1.22, 1.0, 0.75, 0.56]
        let synth = [1.40, 1.13, 1.0, 0.85, 0.70]
        return (synthetic ? synth : camera)[l.rawValue]
    }

    /// Size relative to SVT-AV1 at equal VMAF (median of VMAF 85–95 points).
    public static func codecFactor(_ e: EncoderID, synthetic: Bool) -> Double {
        switch e {
        case .svtav1: return 1
        case .vp9: return synthetic ? 1.8 : 1.25
        case .x265: return synthetic ? 2.23 : 1.07
        case .x264: return synthetic ? 4.6 : 1.28
        case .vtHEVC: return synthetic ? 4.3 : 1.79
        case .vtH264: return synthetic ? 6.6 : 2.1
        }
    }

    /// Bitrate scales roughly with pixel count to the power 0.75 at equal perceived quality.
    public static func resolutionFactor(from a: PixelSize, to b: PixelSize) -> Double {
        pow(Double(b.pixels) / Double(max(1, a.pixels)), 0.75)
    }

    /// Relative encode speed (frames/s) on this M1 Max, from Benchmarks/results/speed.json.
    public static func speed(_ e: EncoderID, _ s: EncoderSpeed, synthetic: Bool) -> Double {
        switch e {
        case .svtav1:
            let p = SVTAV1Encoder.preset(s)
            let cam: [Int: Double] = [4: 21.3, 5: 28, 6: 34.9, 8: 52.8, 10: 74.6]
            let syn: [Int: Double] = [4: 78.8, 5: 95, 6: 112.7, 8: 183.1, 10: 274.5]
            return (synthetic ? syn : cam)[p] ?? 30
        case .x265: return X265Encoder.preset(s) == "slow" ? (synthetic ? 35.5 : 7.9) : (synthetic ? 89.7 : 18.9)
        case .x264: return synthetic ? 176.2 : 28.5
        case .vtHEVC: return synthetic ? 297.5 : 141.3
        case .vtH264: return synthetic ? 326.8 : 145.6
        case .vp9: return synthetic ? 54.8 : 9.2
        }
    }

    /// Scale a measured anchor (bytes of video for `anchorPlan`) to another plan.
    public static func scale(videoBytes: Double, from a: EncodePlan, aLevel: QualityLevel, to b: EncodePlan, bLevel: QualityLevel,
                             synthetic: Bool) -> Double {
        videoBytes
            * levelFactor(bLevel, synthetic: synthetic) / levelFactor(aLevel, synthetic: synthetic)
            * codecFactor(b.encoder, synthetic: synthetic) / codecFactor(a.encoder, synthetic: synthetic)
            * resolutionFactor(from: a.outputSize, to: b.outputSize)
    }
}
