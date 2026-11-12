import SwiftUI
import CirrusCore

/// An estimated outcome for one combination of settings on one video.
struct SizeEstimate {
    var bytes: Int64
    var seconds: Double
    /// Measured directly on this video's samples (vs. scaled from a measurement).
    var measured: Bool
    /// Would be skipped by "Skip if saving under…".
    var wouldSkip: Bool
    var outputSize: PixelSize
    var previewable: Bool
}

@MainActor
extension QueueItem {
    /// Estimate for `s`: the measured anchor scaled by benchmark ratios between settings.
    func estimate(for s: CompressionSettings, engine: CompressionEngine?) -> SizeEstimate? {
        guard let engine, let source, case .ready(let anchor) = estimate,
              let plan = try? engine.plan(source, settings: s) else { return nil }
        let media = source.media
        let D = media.duration
        let synthetic = source.analysis.isSynthetic || source.analysis.kind == .screenRecording
        let ev = anchor.evaluation
        let anchorAudio = Double(anchor.plan.audio.bitrateKbps) * 125 * D
        let anchorVideo = max(1, Double(ev.predictedBytes) - anchorAudio)
        let audio = Double(plan.audio.bitrateKbps) * 125 * D
        var bytes: Double
        var measured = false
        let level: QualityLevel? = { if case .quality(let l) = s.goal { return l }; return nil }()
        let anchorLevel: QualityLevel = { if case .quality(let l) = anchor.settings.goal { return l }; return .balanced }()
        if case .targetSize(let b) = s.goal {
            // the encoder fills a target unless the video needs less (then Maximum Quality is the cap)
            let maxQuality = SizeEstimator.scale(videoBytes: anchorVideo, from: anchor.plan, aLevel: anchorLevel, to: plan, bLevel: .maximum,
                                                 synthetic: synthetic) + audio
            bytes = min(Double(b) * 0.97, maxQuality)
        } else {
            let l = level ?? .balanced
            if s == anchor.settings { bytes = Double(ev.predictedBytes); measured = true }
            else {
                bytes = SizeEstimator.scale(videoBytes: anchorVideo, from: anchor.plan, aLevel: anchorLevel, to: plan, bLevel: l,
                                            synthetic: synthetic) + audio
            }
            // the engine never lets a re-encode grow past ~85 % of an already-compressed source
            if let vb = media.video.bitrate, !["prores", "dnxhd", "ffv1", "rawvideo"].contains(media.video.codec) {
                let ratio = (Double(plan.outputSize.pixels) / Double(max(1, media.video.codedSize.pixels))).squareRoot()
                bytes = min(bytes, Double(vb) / 8 * D * 0.85 * min(1, max(0.5, ratio)) + audio)
            }
        }
        let speedA = SizeEstimator.speed(anchor.plan.encoder, anchor.plan.params.speed, synthetic: synthetic)
        let speedB = SizeEstimator.speed(plan.encoder, plan.params.speed, synthetic: synthetic)
        var secs = ev.estimatedSeconds * speedA / max(1, speedB) * Double(plan.outputSize.pixels) / Double(max(1, anchor.plan.outputSize.pixels))
        if case .targetSize = s.goal, EncoderRegistry.encoder(plan.encoder).supportsTwoPass { secs *= 1.3 }
        let saving = 1 - bytes / Double(max(1, media.fileSize))
        let mustShrink: Bool = { if case .targetSize(let b) = s.goal { return media.fileSize > b }; return false }()
        return SizeEstimate(bytes: Int64(bytes), seconds: secs, measured: measured,
                            wouldSkip: !mustShrink && (saving <= 0 || saving < s.minimumSavings), outputSize: plan.outputSize,
                            previewable: plan.previewableOnThisMac)
    }
}

/// "~214 MB · −91 %", or a quiet placeholder while the measurement runs.
struct EstimateLabel: View {
    var estimate: SizeEstimate?
    var original: Int64
    var compact = false
    var body: some View {
        if let e = estimate {
            let pct = (1 - Double(e.bytes) / Double(max(1, original))) * 100
            HStack(spacing: 4) {
                Text("≈ \(Fmt.bytes(e.bytes))").monospacedDigit()
                if !compact { Text(pct >= 0 ? String(format: "−%.0f%%", pct) : String(format: "+%.0f%%", -pct)).foregroundStyle(pct >= 0 ? Brand.good : Brand.warn) }
            }
        } else {
            Text("…").foregroundStyle(.tertiary)
        }
    }
}
