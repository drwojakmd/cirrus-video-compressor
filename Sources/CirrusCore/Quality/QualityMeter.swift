import Foundation

/// Measured perceptual quality of an encode. Every number here was computed
/// by libvmaf — nothing is estimated or invented.
public struct QualityReport: Sendable, Codable, Equatable {
    public var vmaf: Double             // mean
    public var vmafHarmonic: Double
    public var vmafMin: Double
    public var vmafP5: Double           // 5th percentile — "worst moments"
    public var psnr: Double?
    public var ssim: Double?
    public var framesMeasured: Int
    public var model: String
    /// (time in seconds, VMAF) of the weakest frames, for the comparison view.
    public var worstMoments: [WorstMoment]
    public var measuredOn: Scope

    public enum Scope: String, Sendable, Codable { case fullVideo = "Whole video", samples = "Sampled scenes" }

    public struct WorstMoment: Sendable, Codable, Equatable { public var time: Double; public var vmaf: Double }

    public var rating: QualityRating { QualityRating(vmaf: vmaf, p5: vmafP5) }
}

public enum QualityRating: String, Sendable, Codable {
    case excellent = "Excellent", veryGood = "Very Good", good = "Good", fair = "Fair", poor = "Poor"
    /// Mean VMAF tempered by the worst 5 % of frames, so a mostly-good encode
    /// with ugly moments isn't called "Excellent".
    public init(vmaf: Double, p5: Double) {
        let v = min(vmaf, p5 + 6)
        switch v {
        case 95...: self = .excellent
        case 90..<95: self = .veryGood
        case 80..<90: self = .good
        case 70..<80: self = .fair
        default: self = .poor
        }
    }
    public var explanation: String {
        switch self {
        case .excellent: return "Practically indistinguishable from the original in normal viewing."
        case .veryGood: return "Differences are hard to spot without pausing and comparing."
        case .good: return "Slight softening is visible in detailed or fast scenes."
        case .fair: return "Visible compression artefacts in busy scenes."
        case .poor: return "Obvious quality loss."
        }
    }
}

/// Computes VMAF (+ PSNR/SSIM) with FFmpeg's libvmaf filter using the built-in
/// models (no model files to ship). The reference passes through the same
/// deinterlace/scale chain as the encode so both are compared at output size.
public struct QualityMeter: Sendable {
    let tools: ToolPaths
    public init(tools: ToolPaths) { self.tools = tools }

    public func measure(reference: URL, referenceFilters: String?, distorted: URL, size: PixelSize, fps: Double,
                        subsample: Int = 1, duration: Double, scope: QualityReport.Scope,
                        workspace: TempWorkspace, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> QualityReport {
        let model = size.shortSide >= 1800 ? "vmaf_4k_v0.6.1" : "vmaf_v0.6.1"
        let log = workspace.file("vmaf-\(UUID().uuidString.prefix(6)).json")
        let threads = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let ref = [referenceFilters, "scale=\(size.width):\(size.height):flags=bicubic", "format=yuv420p10le"].compactMap { $0 }.joined(separator: ",")
        // Pair frames by index, not timestamp: containers round timestamps differently
        // (MKV to 1 ms, MP4 exactly), and timestamp pairing then matches neighbouring
        // frames. Both sides carry the same frame sequence because the reference goes
        // through the encode's own filter chain.
        let index = "settb=1/1000,setpts=N"
        let graph = "[0:v]\(index),scale=\(size.width):\(size.height):flags=bicubic,format=yuv420p10le[d];" +
                    "[1:v]\(ref),\(index)[r];" +
                    "[d][r]libvmaf=model='version=\(model)':feature='name=psnr|name=float_ssim':n_threads=\(threads)" +
                    ":n_subsample=\(max(1, subsample)):log_fmt=json:log_path=\(log.path):shortest=1"
        try await FFmpegRun(tools: tools).run(["-i", distorted.path, "-i", reference.path, "-filter_complex", graph, "-f", "null", "-"],
                                              duration: duration, onTick: { onProgress?($0.fraction) })
        return try Self.parse(log, model: model, fps: fps, scope: scope)
    }

    static func parse(_ url: URL, model: String, fps: Double, scope: QualityReport.Scope) throws -> QualityReport {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pooled = root["pooled_metrics"] as? [String: Any],
              let v = pooled["vmaf"] as? [String: Any] else {
            throw CirrusError.processFailed(tool: "VMAF", status: 0, detail: "Unreadable VMAF log")
        }
        let frames = (root["frames"] as? [[String: Any]] ?? []).compactMap { f -> (Int, Double)? in
            guard let n = f["frameNum"] as? Int, let m = f["metrics"] as? [String: Any], let s = m["vmaf"] as? Double else { return nil }
            return (n, s)
        }
        let sorted = frames.map(\.1).sorted()
        let p5 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.05))]
        // worst moments: lowest-scoring frames, at least 2 s apart
        var worst: [QualityReport.WorstMoment] = []
        for (n, s) in frames.sorted(by: { $0.1 < $1.1 }) {
            let t = Double(n) / max(fps, 1)
            if worst.allSatisfy({ abs($0.time - t) > 2 }) { worst.append(.init(time: t, vmaf: s)) }
            if worst.count == 6 { break }
        }
        func mean(_ k: String) -> Double? { (pooled[k] as? [String: Any])?["mean"] as? Double }
        return QualityReport(vmaf: (v["mean"] as? Double) ?? 0, vmafHarmonic: (v["harmonic_mean"] as? Double) ?? 0,
                             vmafMin: (v["min"] as? Double) ?? 0, vmafP5: p5, psnr: mean("psnr_y"), ssim: mean("float_ssim"),
                             framesMeasured: frames.count, model: model, worstMoments: worst, measuredOn: scope)
    }
}
