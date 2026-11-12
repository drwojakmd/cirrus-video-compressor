import Foundation

/// One trial encode of a sample set, with its measured quality.
public struct TrialResult: Sendable {
    public var encoder: EncoderID
    public var params: VideoEncodeParameters
    public var rate: RateControl
    public var encodedSize: PixelSize
    public var kbps: Double
    public var quality: QualityReport
    public var seconds: Double
    /// Frames per second the encoder managed on this trial (for time estimates).
    public var encodeFPS: Double = 0
}

public struct QualitySearchOutcome: Sendable {
    public var value: Double
    public var trial: TrialResult
    public var probes: [TrialResult]
    public var reachedTarget: Bool
    public var cappedBySourceBitrate: Bool
}

/// The optimisation engine: trial-encodes samples and measures VMAF to pick
/// settings. Designed to grow — new strategies only need `trial(...)`.
///
/// Objective: maximise perceptual quality subject to size ≤ target
/// (target-size mode), or minimise size subject to quality ≥ level
/// (quality mode). Both are answered from the same trial primitives.
public struct Optimizer: Sendable {
    let tools: ToolPaths
    let workspace: TempWorkspace
    /// (fraction of the optimisation stage 0…1, human-readable detail)
    let onProgress: @Sendable (Double, String) -> Void

    public init(tools: ToolPaths, workspace: TempWorkspace, onProgress: @escaping @Sendable (Double, String) -> Void) {
        self.tools = tools; self.workspace = workspace; self.onProgress = onProgress
    }

    // MARK: primitives

    /// Encode `sample` (which is already at the size the encoder should see),
    /// then measure VMAF against `reference` at `reference.size`.
    public func trial(encoder id: EncoderID, params: VideoEncodeParameters, rate: RateControl,
                      sample: SampleSet, reference: SampleSet) async throws -> TrialResult {
        let enc = EncoderRegistry.encoder(id)
        let out = workspace.file("trial-\(UUID().uuidString.prefix(6)).mkv")
        defer { try? FileManager.default.removeItem(at: out) }
        let run = FFmpegRun(tools: tools)
        let t0 = Date()
        if case .bitrate = rate, enc.supportsTwoPass {
            let log = workspace.file("trialpass-\(UUID().uuidString.prefix(6))").path
            try await run.run(["-i", sample.url.path, "-map", "0:v:0"] + enc.arguments(params, rate: rate, pass: .first(logPrefix: log), threads: nil) + ["-f", "null", "-"],
                              duration: sample.duration)
            try await run.run(["-i", sample.url.path, "-map", "0:v:0"] + enc.arguments(params, rate: rate, pass: .second(logPrefix: log), threads: nil) + [out.path],
                              duration: sample.duration)
        } else {
            try await run.run(["-i", sample.url.path, "-map", "0:v:0"] + enc.arguments(params, rate: rate, pass: .single, threads: nil) + [out.path],
                              duration: sample.duration)
        }
        let secs = Date().timeIntervalSince(t0)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.doubleValue ?? 0
        // Score ≤ ~240 frames per trial: pooled VMAF is stable under sub-sampling and
        // this keeps each probe's measurement well under its encode time.
        let frames = reference.duration * reference.fps
        let q = try await QualityMeter(tools: tools).measure(
            reference: reference.url, referenceFilters: nil, distorted: out, size: reference.size, fps: reference.fps,
            subsample: max(1, Int((frames / 240).rounded(.up))), duration: reference.duration, scope: .samples, workspace: workspace)
        let r = TrialResult(encoder: id, params: params, rate: rate, encodedSize: sample.size,
                            kbps: bytes * 8 / max(sample.duration, 0.01) / 1000, quality: q, seconds: secs,
                            encodeFPS: sample.duration * sample.fps / max(secs, 0.01))
        Log.info(String(format: "trial %@ %@ %@ @%@ → %.0f kb/s, VMAF %.2f (p5 %.2f) in %.1fs", id.rawValue, "\(sample.size)",
                        "\(rate)", "preset \(params.speed.label)", r.kbps, q.vmaf, q.vmafP5, secs))
        return r
    }

    // MARK: quality search

    /// Find the most compressed constant-quality value whose sample VMAF ≥ target
    /// (and, optionally, whose bitrate stays under `maxKbps`).
    ///
    /// Works on a normalised "compression axis" c (higher c = smaller file) so
    /// CRF-style and VideoToolbox-style scales are handled identically. The
    /// first steps use a calibrated VMAF-per-unit slope; once a passing and a
    /// failing probe bracket the target, it interpolates. ≤ `maxProbes` encodes.
    public func searchQuality(encoder id: EncoderID, params: VideoEncodeParameters, sample: SampleSet,
                              targetVMAF: Double, initial: Double, maxKbps: Double?, maxProbes: Int = 5,
                              progressBase: Double = 0, progressSpan: Double = 1) async throws -> QualitySearchOutcome {
        let scale = EncoderRegistry.encoder(id).qualityScale
        let sign: Double = scale.lowerIsBetter ? 1 : -1
        let limitC = sign * EngineTuning.practicalQualityLimit(id)          // best-quality bound on the c axis
        let slope = EngineTuning.vmafPerUnit(id)
        let maxStep = 5 / slope
        let floorTarget = targetVMAF - 0.25
        func c(_ t: TrialResult) -> Double { sign * value(t) }
        func qualityOK(_ t: TrialResult) -> Bool { t.quality.vmaf >= floorTarget }
        func sizeOK(_ t: TrialResult) -> Bool { maxKbps.map { t.kbps <= $0 } ?? true }
        func quant(_ cc: Double) -> Double { sign * scale.clamp(sign * cc) }

        var probes: [TrialResult] = []
        var nextC = quant(max(limitC, sign * initial))
        for i in 0..<maxProbes {
            try Task.checkCancellation()
            onProgress(progressBase + progressSpan * Double(i) / Double(maxProbes),
                       "Testing quality setting \(Int((sign * nextC).rounded())) on sample scenes (\(i + 1)/\(maxProbes))")
            let t = try await trial(encoder: id, params: params, rate: .quality(sign * nextC), sample: sample, reference: sample)
            probes.append(t)
            if qualityOK(t) && sizeOK(t) && t.quality.vmaf - targetVMAF <= 0.5 { break }   // close enough, just above target

            let best = probes.filter { qualityOK($0) && sizeOK($0) }.map(c).max()
            let hiFail = probes.filter { !qualityOK($0) }.map(c).min()                // quality fails at/above this
            let loFail = probes.filter { qualityOK($0) && !sizeOK($0) }.map(c).max()  // too big at/below this
            func vmafAt(_ cc: Double) -> Double { probes.first { c($0) == cc }!.quality.vmaf }
            var candidate: Double
            if let b = best {
                if let h = hiFail {
                    let vb = vmafAt(b), vh = vmafAt(h)
                    let frac = vb > vh ? (vb - targetVMAF) / (vb - vh) : 0.5
                    candidate = quant(b + (h - b) * min(0.85, max(0.15, frac)))
                } else {
                    candidate = quant(b + min(maxStep, max(scale.step, (vmafAt(b) - targetVMAF) / slope)))
                }
            } else if let h = hiFail, let l = loFail {
                candidate = quant((h + l) / 2)                                         // squeezed between both limits
            } else if let h = hiFail {
                candidate = quant(max(limitC, h - min(maxStep, max(scale.step, (targetVMAF - vmafAt(h)) / slope))))
            } else if let l = loFail {
                candidate = quant(l + max(2 * scale.step, min(maxStep, (vmafAt(l) - targetVMAF) / slope)))
            } else { break }
            if probes.contains(where: { c($0) == candidate }) { break }               // converged at quantiser resolution
            if let h = hiFail, candidate >= h { break }
            if let l = loFail, candidate <= l { break }
            nextC = candidate
        }

        let passing = probes.filter { qualityOK($0) && sizeOK($0) }
        let chosen: TrialResult
        if let b = passing.max(by: { c($0) < c($1) }) {
            chosen = b                                                    // most compressed that passes
        } else if maxKbps != nil, let f = probes.filter(sizeOK).max(by: { $0.quality.vmaf < $1.quality.vmaf }) {
            chosen = f                                                    // best quality that stays under the cap
        } else {
            chosen = probes.max(by: { $0.quality.vmaf < $1.quality.vmaf })!
        }
        return QualitySearchOutcome(value: value(chosen), trial: chosen, probes: probes,
                                    reachedTarget: qualityOK(chosen),
                                    cappedBySourceBitrate: probes.contains { qualityOK($0) && !sizeOK($0) })
    }

    private func value(_ t: TrialResult) -> Double { if case .quality(let v) = t.rate { return v }; return 0 }

    // MARK: lower-resolution sample

    /// Downscale an existing sample (cheap) for "would a lower resolution look better?" checks.
    public func downscaled(_ s: SampleSet, to size: PixelSize) async throws -> SampleSet {
        let out = workspace.file("samples-\(size.width)x\(size.height).mkv")
        try await FFmpegRun(tools: tools).run([
            "-i", s.url.path, "-vf", "scale=\(size.width):\(size.height):flags=lanczos+accurate_rnd+full_chroma_int,format=yuv420p10le",
            "-c:v", "ffv1", "-level", "3", "-slices", "16", "-g", "1", out.path], duration: s.duration)
        return SampleSet(url: out, duration: s.duration, size: size, fps: s.fps, isWholeVideo: s.isWholeVideo)
    }
}

extension EngineTuning {
    /// Never search below this quality value: beyond it files balloon for no
    /// visible gain (and can exceed the source).
    public static func practicalQualityLimit(_ e: EncoderID) -> Double {
        switch e {
        case .svtav1, .vp9: return 16
        case .x265, .x264: return 14
        case .vtHEVC, .vtH264: return 88
        }
    }
}
