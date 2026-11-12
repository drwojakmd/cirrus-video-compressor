import Foundation

public enum AudioQuality: String, Sendable, Codable, CaseIterable, Identifiable {
    case automatic = "Automatic", high = "High Quality", standard = "Standard", smaller = "Smaller File"
    public var id: String { rawValue }
}

public enum AudioCodecChoice: String, Sendable, Codable, CaseIterable, Identifiable {
    case automatic = "Automatic", aac = "AAC", opus = "Opus", copy = "Keep Original", none = "Remove Audio"
    public var id: String { rawValue }
}

public enum AudioCodec: String, Sendable, Codable { case aac = "AAC", opus = "Opus", copy = "Original", none = "None" }

/// Resolved audio encode for one output.
public struct AudioPlan: Sendable, Codable, Equatable {
    public var codec: AudioCodec
    public var streamIndex: Int?
    public var bitrateKbps: Int           // 0 for copy/none
    public var channels: Int
    public var downmixToMono: Bool
    public var encoderName: String?       // aac_at / aac / libopus
    public var note: String?

    public static let none = AudioPlan(codec: .none, streamIndex: nil, bitrateKbps: 0, channels: 0, downmixToMono: false, encoderName: nil, note: nil)

    public var summary: String {
        switch codec {
        case .none: return "No audio"
        case .copy: return "Original audio (unchanged)"
        default:
            let ch = channels == 1 ? "mono" : channels == 2 ? "stereo" : "\(channels)-channel"
            return "\(codec.rawValue) \(bitrateKbps) kbps \(ch)"
        }
    }

    public func ffmpegArguments(inputIndex: Int = 0) -> [String] {
        guard let idx = streamIndex, codec != .none else { return ["-an"] }
        var a = ["-map", "\(inputIndex):\(idx)"]
        switch codec {
        case .none: return ["-an"]
        case .copy: a += ["-c:a", "copy"]
        case .aac:
            a += ["-c:a", encoderName ?? "aac", "-b:a", "\(bitrateKbps)k"]
            if encoderName == "aac_at" { a += ["-aac_at_mode", "cvbr"] }   // Apple's constrained-VBR AAC: best AAC quality per bit
        case .opus:
            a += ["-c:a", "libopus", "-b:a", "\(bitrateKbps)k", "-vbr", "on", "-compression_level", "10"]
            if channels > 2 { a += ["-mapping_family", "1"] }
        }
        if codec != .copy {
            if downmixToMono { a += ["-ac", "1"] }
            // Opus is always 48 kHz internally; AAC keeps the source rate up to 48 kHz.
            a += ["-ar", "48000"]
        }
        return a
    }
}

/// Chooses audio codec & bitrate.
///
/// Principles: never spend more bits than the source had (re-encoding lossy
/// audio at a higher bitrate wastes space without adding quality); keep the
/// original when it is already efficient and compatible; don't degrade audio
/// to buy tiny video gains unless the size budget is genuinely tight.
public enum AudioPlanner {
    /// Bitrate tables (kbit/s) per channel class: [high, standard, smaller, floor].
    static let opus: [Int: [Int]] = [1: [96, 64, 48, 32], 2: [160, 128, 96, 64], 6: [320, 256, 192, 128], 8: [384, 320, 256, 160]]
    static let aac: [Int: [Int]] = [1: [128, 96, 80, 64], 2: [256, 192, 128, 96], 6: [448, 384, 320, 192], 8: [512, 448, 384, 256]]

    public static func plan(media: MediaInfo, quality: AudioQuality, codecChoice: AudioCodecChoice,
                            videoCodec: VideoCodec, preferCompatibility: Bool, effectivelyMono: Bool,
                            budgetPressure: Double, caps: FFmpegCapabilities, overrideKbps: Int? = nil) -> AudioPlan {
        guard let src = media.audio.first, codecChoice != .none else { return .none }

        // Codec: Opus is ~25–35 % more efficient than AAC, but QuickTime/iOS
        // only play it inside MP4 on recent OS versions. Pair Opus with AV1/VP9
        // (already a "modern players" choice) and AAC with HEVC/H.264.
        var codec: AudioCodec
        switch codecChoice {
        case .aac: codec = .aac
        case .opus: codec = caps.hasOpus ? .opus : .aac
        case .copy: codec = .copy
        case .none: return .none
        case .automatic:
            codec = ((videoCodec == .av1 || videoCodec == .vp9) && !preferCompatibility && caps.hasOpus) ? .opus : .aac
        }

        let channels = effectivelyMono ? 1 : src.channels
        let cls = channels <= 1 ? 1 : channels <= 2 ? 2 : channels <= 6 ? 6 : 8
        let table = (codec == .opus ? opus : aac)[cls]!
        var tier: Int
        switch quality {
        case .high: tier = 0
        case .standard: tier = 1
        case .smaller: tier = 2
        case .automatic:
            // budgetPressure = share of the total size budget the standard tier would take.
            tier = budgetPressure > 0.35 ? 3 : budgetPressure > 0.2 ? 2 : 1
        }
        var kbps = overrideKbps ?? table[tier]

        // Never exceed the source's own bitrate when it is lossy.
        if let sb = src.bitrate, !src.isLossless {
            let srcKbps = sb / 1000
            let sameFamily = (codec == .aac && src.codec == "aac") || (codec == .opus && src.codec == "opus")
            if codecChoice == .automatic && sameFamily && srcKbps <= Int(Double(kbps) * 1.15) && !effectivelyMono {
                // Already efficient & compatible: keep it bit-for-bit (no generational loss).
                return AudioPlan(codec: .copy, streamIndex: src.index, bitrateKbps: srcKbps, channels: src.channels,
                                 downmixToMono: false, encoderName: nil, note: "Original \(src.codecDisplayName) kept (already efficient)")
            }
            kbps = min(kbps, max(table[3], Int(Double(srcKbps) * 0.95)))
        }
        if codec == .copy {
            return AudioPlan(codec: .copy, streamIndex: src.index, bitrateKbps: (src.bitrate ?? 0) / 1000, channels: src.channels,
                             downmixToMono: false, encoderName: nil, note: nil)
        }
        let encoder = codec == .opus ? "libopus" : (caps.hasAudioToolboxAAC ? "aac_at" : "aac")
        return AudioPlan(codec: codec, streamIndex: src.index, bitrateKbps: kbps, channels: channels,
                         downmixToMono: effectivelyMono && src.channels > 1, encoderName: encoder,
                         note: effectivelyMono && src.channels > 1 ? "Stereo track is identical in both channels — stored as mono" : nil)
    }
}

/// Cheap audio inspection: are the two channels identical (dual-mono)?
public struct AudioAnalyzer: Sendable {
    let tools: ToolPaths
    public init(tools: ToolPaths) { self.tools = tools }

    /// Measures the RMS of (L − R) over up to 3 minutes of audio. Below −60 dBFS
    /// the channels are the same signal, so storing one halves the audio cost.
    public func isEffectivelyMono(_ media: MediaInfo) async -> Bool {
        guard let a = media.audio.first, a.channels == 2 else { return false }
        let r = try? await ProcessRunner.run(tools.ffmpeg, [
            "-v", "info", "-nostdin", "-t", "180", "-i", media.url.path, "-map", "0:\(a.index)",
            "-af", "pan=mono|c0=0.5*c0-0.5*c1,astats=measure_perchannel=none:measure_overall=RMS_level+Peak_level",
            "-f", "null", "-",
        ], options: { var o = ProcessRunner.Options(); o.allowFailure = true; o.collectStdout = false; return o }())
        guard let log = r?.stderr else { return false }
        // "RMS level dB: -inf" or a number
        for line in log.split(separator: "\n") where line.contains("RMS level dB") {
            let v = line.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if v == "-inf" { return true }
            if let d = Double(v) { return d < -60 }
        }
        return false
    }
}
