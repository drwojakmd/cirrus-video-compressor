import Foundation

public enum VideoCodec: String, Sendable, Codable, CaseIterable {
    case av1 = "AV1", hevc = "HEVC", h264 = "H.264", vp9 = "VP9"
}

/// Concrete encoder implementations the engine can drive.
public enum EncoderID: String, Sendable, Codable, CaseIterable, Identifiable {
    case svtav1 = "SVT-AV1"
    case x265 = "x265"
    case x264 = "x264"
    case vtHEVC = "VideoToolbox HEVC"
    case vtH264 = "VideoToolbox H.264"
    case vp9 = "libvpx VP9"
    public var id: String { rawValue }

    public var codec: VideoCodec {
        switch self {
        case .svtav1: return .av1
        case .x265, .vtHEVC: return .hevc
        case .x264, .vtH264: return .h264
        case .vp9: return .vp9
        }
    }
    public var isHardware: Bool { self == .vtHEVC || self == .vtH264 }
}

/// Encoder effort. Mapped to each encoder's native preset scale.
public enum EncoderSpeed: Int, Sendable, Codable, CaseIterable, Identifiable, Comparable {
    case fastest = 0, fast, balanced, thorough, best
    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .fastest: return "Fastest"
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .thorough: return "Thorough"
        case .best: return "Best (slowest)"
        }
    }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// How the bitstream size is controlled.
public enum RateControl: Sendable, Equatable, Codable {
    /// Constant quality. `value` is on the encoder's native scale (CRF for
    /// software encoders — lower is better; `-q:v` for VideoToolbox — higher is better).
    case quality(Double)
    /// Average bitrate in kbit/s (two-pass when the encoder supports it).
    case bitrate(kbps: Int)
}

public enum EncodePass: Sendable, Equatable {
    case single
    case first(logPrefix: String)
    case second(logPrefix: String)
}

/// Encoder-independent description of a video encode.
public struct VideoEncodeParameters: Sendable, Equatable, Codable {
    public var speed: EncoderSpeed
    public var tenBit: Bool
    public var profile: ContentKind
    /// Clean computer-generated imagery (drives "animation" tunings in x264/x265).
    public var synthetic: Bool = false
    /// Text legibility guard active (screen-content tools for synthetic text, no grain synthesis).
    public var textGuard: Bool = false
    /// Film-grain synthesis level (SVT-AV1 only; 0 = off).
    public var filmGrain: Int
    public var keyframeInterval: Int        // frames
    public var frameRate: Double
    public var dynamicRange: DynamicRange
    public var colorPrimaries: String?
    public var colorTransfer: String?
    public var colorSpace: String?
    public var colorRange: String?
    /// Expert-only extra parameters appended to the encoder's private options.
    public var extraEncoderParams: String?
}

/// The native quality scale of an encoder, so the optimiser can search any of them.
public struct QualityScale: Sendable {
    public var range: ClosedRange<Double>
    public var lowerIsBetter: Bool
    public var step: Double
    /// Clamp & quantise a raw value onto the scale.
    public func clamp(_ v: Double) -> Double {
        let s = (v / step).rounded() * step
        return min(range.upperBound, max(range.lowerBound, s))
    }
    /// Move `v` toward higher quality by `amount` native units.
    public func better(_ v: Double, by amount: Double) -> Double { clamp(lowerIsBetter ? v - amount : v + amount) }
}

/// One encoder implementation. Back-ends only translate parameters into FFmpeg
/// arguments; planning and optimisation live elsewhere.
public protocol VideoEncoder: Sendable {
    var id: EncoderID { get }
    var ffmpegName: String { get }
    var supportsTwoPass: Bool { get }
    var supports10Bit: Bool { get }
    var qualityScale: QualityScale { get }
    func isAvailable(_ caps: FFmpegCapabilities) -> Bool
    /// FFmpeg output arguments for the video stream (codec, rate control, tuning, pixel format, tags).
    func arguments(_ p: VideoEncodeParameters, rate: RateControl, pass: EncodePass, threads: Int?) -> [String]
}

extension VideoEncoder {
    public func isAvailable(_ caps: FFmpegCapabilities) -> Bool { caps.encoders.contains(ffmpegName) }

    /// Colour signalling copied from the source so players show the same colours.
    func colorArguments(_ p: VideoEncodeParameters) -> [String] {
        var a: [String] = []
        if let v = p.colorPrimaries, v != "unknown" { a += ["-color_primaries", v] }
        if let v = p.colorTransfer, v != "unknown" { a += ["-color_trc", v] }
        if let v = p.colorSpace, v != "unknown" { a += ["-colorspace", v] }
        if let v = p.colorRange, v != "unknown" { a += ["-color_range", v] }
        return a
    }

    func passArguments(_ pass: EncodePass) -> [String] {
        switch pass {
        case .single: return []
        case .first(let log): return ["-pass", "1", "-passlogfile", log]
        case .second(let log): return ["-pass", "2", "-passlogfile", log]
        }
    }
}

public enum EncoderRegistry {
    public static func encoder(_ id: EncoderID) -> any VideoEncoder {
        switch id {
        case .svtav1: return SVTAV1Encoder()
        case .x265: return X265Encoder()
        case .x264: return X264Encoder()
        case .vtHEVC: return VideoToolboxEncoder(codec: .hevc)
        case .vtH264: return VideoToolboxEncoder(codec: .h264)
        case .vp9: return VP9Encoder()
        }
    }
}
