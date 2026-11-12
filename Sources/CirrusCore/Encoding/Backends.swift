import Foundation

// Encoder back-ends. Each translates `VideoEncodeParameters` into FFmpeg
// arguments. Content-specific tuning is deliberately small and each option is
// justified in Docs/ENCODING.md by benchmark results.

// MARK: SVT-AV1

public struct SVTAV1Encoder: VideoEncoder {
    public let id = EncoderID.svtav1
    public let ffmpegName = "libsvtav1"
    public let supportsTwoPass = true
    public let supports10Bit = true
    public let qualityScale = QualityScale(range: 10...63, lowerIsBetter: true, step: 1)

    /// SVT-AV1 preset per effort level (lower = slower/better).
    public static func preset(_ s: EncoderSpeed) -> Int {
        switch s { case .fastest: return 10; case .fast: return 8; case .balanced: return 6; case .thorough: return 5; case .best: return 4 }
    }

    public func arguments(_ p: VideoEncodeParameters, rate: RateControl, pass: EncodePass, threads: Int?) -> [String] {
        var a = ["-c:v", ffmpegName, "-preset", "\(Self.preset(p.speed))"]
        switch rate {
        case .quality(let crf): a += ["-crf", "\(Int(crf.rounded()))"]
        case .bitrate(let kbps): a += ["-b:v", "\(kbps)k"]
        }
        a += ["-g", "\(p.keyframeInterval)", "-pix_fmt", p.tenBit ? "yuv420p10le" : "yuv420p"]
        var sp = [
            "tune=1",              // measured: ~6 % fewer bits than tune=0 at equal VMAF (Docs/ENCODING.md)
            "scd=1",               // scene-change detection → keyframes on cuts
        ]
        // Overlay frames help static content in constant-quality mode, but SVT-AV1
        // rejects them in multi-pass ("not supported with multi-pass encoding").
        if case .quality = rate { sp.append("enable-overlays=1") }
        // Force screen-content tools (palette, intra block copy) for screen recordings, and for
        // clean synthetic imagery with text (slides). Elsewhere scm=2 (content-adaptive) is the default.
        if p.profile == .screenRecording || (p.textGuard && p.synthetic) { sp.append("scm=1") }
        if p.filmGrain > 0 { sp += ["film-grain=\(p.filmGrain)", "film-grain-denoise=1"] }
        if p.dynamicRange == .hdr10 { sp.append("enable-hdr=1") }
        if let extra = p.extraEncoderParams, !extra.isEmpty { sp.append(extra) }
        a += ["-svtav1-params", sp.joined(separator: ":")]
        return a + passArguments(pass) + colorArguments(p)
    }
}

// MARK: x265

public struct X265Encoder: VideoEncoder {
    public let id = EncoderID.x265
    public let ffmpegName = "libx265"
    public let supportsTwoPass = true
    public let supports10Bit = true
    public let qualityScale = QualityScale(range: 8...42, lowerIsBetter: true, step: 0.5)

    public static func preset(_ s: EncoderSpeed) -> String {
        // "slower" costs ~2.5× "slow" on an M1 for ~2–3 % — not worth it; "slow" is the ceiling.
        switch s { case .fastest: return "veryfast"; case .fast: return "fast"; case .balanced: return "medium"; case .thorough, .best: return "slow" }
    }

    public func arguments(_ p: VideoEncodeParameters, rate: RateControl, pass: EncodePass, threads: Int?) -> [String] {
        var a = ["-c:v", ffmpegName, "-preset", Self.preset(p.speed)]
        switch rate {
        case .quality(let crf): a += ["-crf", String(format: "%.1f", crf)]
        case .bitrate(let kbps): a += ["-b:v", "\(kbps)k"]
        }
        if p.synthetic && p.profile != .screenRecording { a += ["-tune", "animation"] }
        a += ["-pix_fmt", p.tenBit ? "yuv420p10le" : "yuv420p", "-tag:v", "hvc1"]
        let minKey = max(1, Int(p.frameRate.rounded()))
        var xp = ["log-level=error", "keyint=\(p.keyframeInterval)", "min-keyint=\(min(minKey, p.keyframeInterval))"]
        switch pass {
        case .single: break
        case .first(let log): xp += ["pass=1", "stats=\(log).x265"]
        case .second(let log): xp += ["pass=2", "stats=\(log).x265"]
        }
        if p.dynamicRange == .hdr10 { xp += ["hdr10=1", "hdr10-opt=1", "repeat-headers=1"] }
        if let extra = p.extraEncoderParams, !extra.isEmpty { xp.append(extra) }
        a += ["-x265-params", xp.joined(separator: ":")]
        return a + colorArguments(p)
    }
}

// MARK: x264

public struct X264Encoder: VideoEncoder {
    public let id = EncoderID.x264
    public let ffmpegName = "libx264"
    public let supportsTwoPass = true
    public let supports10Bit = false   // High 10 decodes in software only on most devices
    public let qualityScale = QualityScale(range: 10...40, lowerIsBetter: true, step: 0.5)

    public static func preset(_ s: EncoderSpeed) -> String {
        switch s { case .fastest: return "veryfast"; case .fast: return "fast"; case .balanced: return "medium"; case .thorough: return "slow"; case .best: return "slower" }
    }

    public func arguments(_ p: VideoEncodeParameters, rate: RateControl, pass: EncodePass, threads: Int?) -> [String] {
        var a = ["-c:v", ffmpegName, "-preset", Self.preset(p.speed)]
        switch rate {
        case .quality(let crf): a += ["-crf", String(format: "%.1f", crf)]
        case .bitrate(let kbps): a += ["-b:v", "\(kbps)k"]
        }
        if p.profile == .screenRecording { a += ["-tune", "stillimage"] }
        else if p.synthetic { a += ["-tune", "animation"] }
        else if p.profile == .liveAction || p.profile == .talkingHeadAnimation { a += ["-tune", "film"] }
        a += ["-pix_fmt", "yuv420p", "-profile:v", "high", "-g", "\(p.keyframeInterval)",
              "-keyint_min", "\(max(1, min(Int(p.frameRate.rounded()), p.keyframeInterval)))"]
        if let extra = p.extraEncoderParams, !extra.isEmpty { a += ["-x264-params", extra] }
        return a + passArguments(pass) + colorArguments(p)
    }
}

// MARK: VideoToolbox (Apple Silicon media engine)

public struct VideoToolboxEncoder: VideoEncoder {
    public let codec: VideoCodec
    public var id: EncoderID { codec == .hevc ? .vtHEVC : .vtH264 }
    public var ffmpegName: String { codec == .hevc ? "hevc_videotoolbox" : "h264_videotoolbox" }
    public let supportsTwoPass = false
    public var supports10Bit: Bool { codec == .hevc }
    /// `-q:v` constant-quality (Apple Silicon only): 1…100, higher is better.
    public let qualityScale = QualityScale(range: 20...95, lowerIsBetter: false, step: 1)

    public func arguments(_ p: VideoEncodeParameters, rate: RateControl, pass: EncodePass, threads: Int?) -> [String] {
        var a = ["-c:v", ffmpegName]
        switch rate {
        case .quality(let q): a += ["-q:v", "\(Int(q.rounded()))"]
        case .bitrate(let kbps):
            // average bitrate with a VBV ceiling so the hardware RC can't overshoot wildly
            a += ["-b:v", "\(kbps)k", "-maxrate", "\(Int(Double(kbps) * 1.6))k", "-bufsize", "\(kbps * 4)k"]
        }
        if codec == .hevc {
            a += ["-pix_fmt", p.tenBit ? "p010le" : "nv12", "-profile:v", p.tenBit ? "main10" : "main", "-tag:v", "hvc1"]
        } else {
            a += ["-pix_fmt", "nv12", "-profile:v", "high"]
        }
        a += ["-g", "\(p.keyframeInterval)", "-allow_sw", "0"]
        if p.speed <= .fast { a += ["-prio_speed", "1"] }
        return a + colorArguments(p)
    }
}

// MARK: VP9

public struct VP9Encoder: VideoEncoder {
    public let id = EncoderID.vp9
    public let ffmpegName = "libvpx-vp9"
    public let supportsTwoPass = true
    public let supports10Bit = true
    public let qualityScale = QualityScale(range: 10...60, lowerIsBetter: true, step: 1)

    static func cpuUsed(_ s: EncoderSpeed) -> Int {
        switch s { case .fastest: return 5; case .fast: return 4; case .balanced: return 3; case .thorough: return 2; case .best: return 1 }
    }

    public func arguments(_ p: VideoEncodeParameters, rate: RateControl, pass: EncodePass, threads: Int?) -> [String] {
        var a = ["-c:v", ffmpegName, "-cpu-used", "\(Self.cpuUsed(p.speed))", "-row-mt", "1", "-tile-columns", "2",
                 "-auto-alt-ref", "1", "-lag-in-frames", "25"]
        switch rate {
        case .quality(let crf): a += ["-crf", "\(Int(crf.rounded()))", "-b:v", "0"]
        case .bitrate(let kbps): a += ["-b:v", "\(kbps)k"]
        }
        if p.profile == .screenRecording { a += ["-tune-content", "screen"] }
        a += ["-g", "\(p.keyframeInterval)", "-pix_fmt", p.tenBit ? "yuv420p10le" : "yuv420p"]
        if p.tenBit { a += ["-profile:v", "2"] }
        return a + passArguments(pass) + colorArguments(p)
    }
}
