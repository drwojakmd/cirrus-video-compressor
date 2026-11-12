import Foundation

/// Requested output resolution. Presets describe a bounding box (oriented to
/// match the source, so "1080p" of a portrait phone video is 1080 × 1920);
/// the aspect ratio is always preserved unless a custom size asks otherwise,
/// and video is never upscaled unless explicitly allowed.
public enum OutputResolution: Hashable, Codable, Sendable, Identifiable {
    case original, uhd2160, qhd1440, fhd1080, hd720, sd480
    case custom(width: Int, height: Int, keepAspect: Bool)

    public var id: String { label }
    public static let presets: [OutputResolution] = [.original, .uhd2160, .qhd1440, .fhd1080, .hd720, .sd480]

    public var label: String {
        switch self {
        case .original: return "Original"
        case .uhd2160: return "4K (2160p)"
        case .qhd1440: return "1440p"
        case .fhd1080: return "1080p"
        case .hd720: return "720p"
        case .sd480: return "480p"
        case .custom(let w, let h, _): return "Custom \(w) × \(h)"
        }
    }

    public var box: PixelSize? {
        switch self {
        case .original: return nil
        case .uhd2160: return PixelSize(3840, 2160)
        case .qhd1440: return PixelSize(2560, 1440)
        case .fhd1080: return PixelSize(1920, 1080)
        case .hd720: return PixelSize(1280, 720)
        case .sd480: return PixelSize(854, 480)
        case .custom(let w, let h, _): return PixelSize(w, h)
        }
    }

    /// Resolve against a source's display size.
    public func resolve(source: PixelSize, allowUpscale: Bool = false) -> PixelSize {
        guard var box else { return Self.even(source) }
        if case .custom(_, _, false) = self { return Self.even(allowUpscale ? box : PixelSize(min(box.width, source.width), min(box.height, source.height))) }
        // orient the box like the source
        if source.isPortrait != box.isPortrait && box.width != box.height { box = PixelSize(box.height, box.width) }
        let scale = min(Double(box.width) / Double(source.width), Double(box.height) / Double(source.height))
        let s = allowUpscale ? scale : min(1.0, scale)
        return Self.even(PixelSize(Int((Double(source.width) * s).rounded()), Int((Double(source.height) * s).rounded())))
    }

    static func even(_ p: PixelSize) -> PixelSize { PixelSize(max(2, p.width / 2 * 2), max(2, p.height / 2 * 2)) }

    /// Next lower preset (for "would a lower resolution look better?" checks).
    public static func stepDown(from size: PixelSize) -> PixelSize? {
        let ladder = [2160, 1440, 1080, 720, 540, 480, 360]
        guard let next = ladder.first(where: { $0 < size.shortSide - 8 }), next >= 360 else { return nil }
        let s = Double(next) / Double(size.shortSide)
        return even(PixelSize(Int((Double(size.width) * s).rounded()), Int((Double(size.height) * s).rounded())))
    }
}

/// The five plain-English compression levels.
public enum QualityLevel: Int, Codable, Sendable, CaseIterable, Identifiable {
    case maximum = 0, high, balanced, aggressive, maximumCompression
    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .maximum: return "Maximum Quality"
        case .high: return "High Quality"
        case .balanced: return "Balanced"
        case .aggressive: return "Aggressive"
        case .maximumCompression: return "Maximum Compression"
        }
    }
    public var blurb: String {
        switch self {
        case .maximum: return "Visually indistinguishable from the original. Still much smaller."
        case .high: return "Excellent quality; differences only visible frame-by-frame."
        case .balanced: return "Strong compression with very good quality. Recommended."
        case .aggressive: return "Small files. Fine detail softens in busy scenes."
        case .maximumCompression: return "Smallest files. Some visible quality loss is likely."
        }
    }
    /// Perceptual target (VMAF, 0–100) the optimiser aims for on this level.
    /// ~93+ is generally considered "good to excellent", 97+ near-transparent.
    public var targetVMAF: Double {
        switch self {
        case .maximum: return 97
        case .high: return 95
        case .balanced: return 93
        case .aggressive: return 90
        case .maximumCompression: return 85
        }
    }
}

public enum SizeGoal: Hashable, Codable, Sendable {
    case quality(QualityLevel)
    /// Maximum output size in bytes (decimal MB, as Finder shows them).
    case targetSize(bytes: Int64)
}

/// What matters most beyond quality-per-megabyte.
public enum OutputPriority: String, Codable, Sendable, CaseIterable, Identifiable {
    case smallestFile = "Smallest File"
    case appleDevices = "Apple Devices"
    case playsEverywhere = "Plays Everywhere"
    case fastest = "Fastest"
    public var id: String { rawValue }
    public var blurb: String {
        switch self {
        case .smallestFile: return "Best quality per megabyte (AV1). Plays in browsers, VLC, IINA, YouTube and on M3+ Macs and recent iPhones."
        case .appleDevices: return "HEVC. Plays natively on every modern Mac, iPhone, iPad and Apple TV."
        case .playsEverywhere: return "H.264. Plays on practically any device or app, at a larger size."
        case .fastest: return "Uses the Apple Silicon media engine. Very fast; larger files than the other options."
        }
    }
}

/// How much work the engine may spend finding the best settings.
public enum AnalysisDepth: String, Codable, Sendable, CaseIterable, Identifiable {
    case quick = "Quick"
    case smart = "Smart"
    case bestPossible = "Best Possible"
    public var id: String { rawValue }
    public var blurb: String {
        switch self {
        case .quick: return "Settings predicted from content analysis. No trial encodes."
        case .smart: return "Trial-encodes short samples and measures quality (VMAF) to tune settings. Adds a few percent to encode time."
        case .bestPossible: return "Compares encoders and resolutions on samples and verifies the result. Slowest, best result."
        }
    }
}

public enum TenBitMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic = "Automatic", on = "Always 10-bit", off = "8-bit"
    public var id: String { rawValue }
}

/// Expert options. Every field defaults to "let the engine decide".
public struct AdvancedSettings: Codable, Sendable, Hashable {
    public var encoder: EncoderID? = nil
    public var speed: EncoderSpeed? = nil
    public var frameRateCap: Double? = nil
    public var audioCodec: AudioCodecChoice = .automatic
    public var audioBitrateKbps: Int? = nil
    public var keyframeSeconds: Double? = nil
    public var preferHardware: Bool = false
    /// Constant-quality value on the chosen encoder's native scale.
    public var qualityValue: Double? = nil
    /// Explicit perceptual target (VMAF) overriding the quality level's target.
    public var targetVMAF: Double? = nil
    public var tenBit: TenBitMode = .automatic
    public var profile: ContentKind? = nil
    public var filmGrain: Bool? = nil
    public var allowLowerResolution: Bool = true
    public var keepAllAudioTracks: Bool = false
    public var extraEncoderParams: String = ""
    public init() {}
}

/// "Keep text readable": automatic follows text detection; on/off are explicit choices.
public enum TextGuardMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic, on, off
    public var id: String { rawValue }
}

public struct CompressionSettings: Codable, Sendable, Hashable {
    public var resolution: OutputResolution = .original
    public var goal: SizeGoal = .quality(.balanced)
    public var audio: AudioQuality = .automatic
    public var priority: OutputPriority = .smallestFile
    public var depth: AnalysisDepth = .smart
    /// Measure VMAF of the finished file (sub-sampled). Required for the quality badge.
    public var measureQuality: Bool = true
    /// Only make files this Mac can play in Finder's Quick Look, QuickTime and Photos.
    /// On Macs without an AV1 hardware decoder (M1/M2) this means HEVC instead of AV1.
    public var previewableOnThisMac: Bool = true
    /// Protect the legibility of slides, captions and on-screen text.
    public var textGuard: TextGuardMode = .automatic
    /// Keep the original (and discard the result) unless compression saves at least
    /// this fraction of the file size. 0 = always keep the result if it is smaller.
    public var minimumSavings: Double = 0.10
    public var advanced = AdvancedSettings()
    public init() {}

    enum CodingKeys: String, CodingKey {
        case resolution, goal, audio, priority, depth, measureQuality, previewableOnThisMac, textGuard, minimumSavings, advanced
    }
    // Tolerant decoding: settings saved by older versions (or presets) lack newer keys.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        resolution = try c.decodeIfPresent(OutputResolution.self, forKey: .resolution) ?? .original
        goal = try c.decodeIfPresent(SizeGoal.self, forKey: .goal) ?? .quality(.balanced)
        audio = try c.decodeIfPresent(AudioQuality.self, forKey: .audio) ?? .automatic
        priority = try c.decodeIfPresent(OutputPriority.self, forKey: .priority) ?? .smallestFile
        depth = try c.decodeIfPresent(AnalysisDepth.self, forKey: .depth) ?? .smart
        measureQuality = try c.decodeIfPresent(Bool.self, forKey: .measureQuality) ?? true
        previewableOnThisMac = try c.decodeIfPresent(Bool.self, forKey: .previewableOnThisMac) ?? true
        textGuard = try c.decodeIfPresent(TextGuardMode.self, forKey: .textGuard) ?? .automatic
        minimumSavings = try c.decodeIfPresent(Double.self, forKey: .minimumSavings) ?? 0.10
        advanced = try c.decodeIfPresent(AdvancedSettings.self, forKey: .advanced) ?? AdvancedSettings()
    }
}
