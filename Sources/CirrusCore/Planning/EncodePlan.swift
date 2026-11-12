import Foundation

/// How the final bitrate will be decided.
public enum RateStrategy: Sendable, Equatable {
    /// Constant quality at a fixed value (Quick mode, or advanced override).
    case fixedQuality(Double)
    /// Search samples for the value that reaches `targetVMAF`, then encode at constant quality.
    case searchQuality(targetVMAF: Double, initialGuess: Double)
    /// Hit a size budget. `videoKbps` is recomputed once the audio has been
    /// encoded and its exact size is known.
    case targetSize(bytes: Int64, videoKbps: Int)
}

/// A complete, explainable plan for one output file.
public struct EncodePlan: Sendable {
    public var encoder: EncoderID
    public var params: VideoEncodeParameters
    public var rate: RateStrategy
    public var outputSize: PixelSize
    public var videoFilters: [String]
    public var audio: AudioPlan
    public var depth: AnalysisDepth
    public var allowLowerResolution: Bool
    /// Candidate encoders for Best Possible mode (first = default choice).
    public var candidates: [EncoderID]
    public var notes: [String] = []
    public var warnings: [String] = []
    /// How the text legibility guard applies to this video.
    public var textGuard = TextGuardPlan.inactive
    /// Whether Finder's Quick Look / QuickTime on this Mac will play the result.
    public var previewableOnThisMac = true

    public var codec: VideoCodec { encoder.codec }
    public var filterChain: String? { videoFilters.isEmpty ? nil : videoFilters.joined(separator: ",") }
}

public struct TextGuardPlan: Sendable, Equatable {
    public var active: Bool
    /// Switched on by text detection rather than by the user.
    public var automatic: Bool
    /// Why it is on or off, in plain English.
    public var reason: String
    /// Never go below this short side automatically (smallest text stays readable).
    public var minimumShortSide: Int?
    /// Source times with the smallest text, to check legibility on.
    public var moments: [Double]
    /// Smallest text line height at the planned output size (px).
    public var smallestLineAtOutput: Double
    /// A larger resolution preset that keeps the smallest text readable, when the chosen one doesn't.
    public var suggestedResolution: OutputResolution?

    public static let inactive = TextGuardPlan(active: false, automatic: false, reason: "No text detected", minimumShortSide: nil,
                                               moments: [], smallestLineAtOutput: 0, suggestedResolution: nil)
}

/// Engine constants derived from the benchmark study (Docs/BENCHMARKS.md).
/// Kept in one place so tuning is a data change, not a code change.
public enum EngineTuning {
    /// Starting constant-quality value per encoder for each quality level
    /// [maximum, high, balanced, aggressive, maximumCompression] = VMAF [97, 95, 93, 90, 85].
    /// Medians of the value that reached each VMAF in the M1 benchmark (Docs/ENCODING.md),
    /// separately for camera footage and clean synthetic imagery, which differ by ~20 CRF.
    /// Quick mode uses these directly; Smart mode starts its search here.
    public static func initialQuality(_ e: EncoderID, _ level: QualityLevel, kind: ContentKind, synthetic: Bool = false) -> Double {
        let live: [Double], synth: [Double]
        switch e {
        case .svtav1, .vp9: live = [36, 37, 39, 42, 46];  synth = [55, 58, 60, 61, 63]
        case .x265:         live = [23, 25, 26, 28, 30];  synth = [24, 34, 37, 38, 40]
        case .x264:         live = [22, 23, 24, 25, 27];  synth = [22, 29, 31, 34, 37]
        case .vtHEVC:       live = [62, 56, 51, 47, 42];  synth = [65, 50, 41, 36, 31]
        case .vtH264:       live = [66, 61, 56, 51, 46];  synth = [63, 59, 50, 46, 42]
        }
        let isSynthetic = synthetic || kind == .screenRecording
        // Quick mode has no measurement to fall back on, so stay ~1 level conservative on synthetic content.
        let v = isSynthetic ? synth[max(0, level.rawValue - 1)] : live[level.rawValue]
        return EncoderRegistry.encoder(e).qualityScale.clamp(v)
    }

    /// Approximate VMAF change per native quality unit around the operating
    /// point (measured on camera footage; the search refines it after 2 probes).
    public static func vmafPerUnit(_ e: EncoderID) -> Double {
        switch e {
        case .svtav1, .vp9: return 0.9
        case .x265, .x264: return 1.4
        case .vtHEVC, .vtH264: return 0.6
        }
    }

    /// Fraction of the video budget aimed for. Measured two-pass accuracy on this M1
    /// (Benchmarks/results/ratecontrol.jsonl): SVT-AV1 always lands under its target
    /// (median −6 %), x265/x264 can overshoot by up to +7.5 % / +11 %, single-pass
    /// VideoToolbox by up to +28 %. Overshoots are caught by the verify-and-correct
    /// loop; these margins just make a correction pass rare.
    public static func sizeSafety(_ e: EncoderID) -> Double {
        switch e {
        case .svtav1: return 1.0
        case .vp9: return 0.97
        case .x265, .x264: return 0.96
        case .vtHEVC, .vtH264: return 0.88
        }
    }

    /// Default effort for a quality level, moderated by video length so a long
    /// video at "Maximum Quality" doesn't take all night.
    public static func speed(for goal: SizeGoal, duration: Double, encoder: EncoderID) -> EncoderSpeed {
        var s: EncoderSpeed
        switch goal {
        case .quality(let l):
            switch l {
            case .maximum, .high: s = .best
            case .balanced: s = .thorough
            case .aggressive, .maximumCompression: s = .thorough
            }
        case .targetSize: s = .best      // a hard size cap is exactly where encoder effort pays most
        }
        if duration > 3600 { s = min(s, .balanced) } else if duration > 1200 { s = min(s, .thorough) }
        return s
    }
}

/// Builds an `EncodePlan` from source facts + user settings. Pure function,
/// no I/O — easy to unit-test.
public enum EncodePlanner {
    public static func plan(media: MediaInfo, analysis: ContentAnalysis, settings: CompressionSettings,
                            caps: FFmpegCapabilities, effectivelyMono: Bool, text: TextAnalysis = .none) throws -> EncodePlan {
        let adv = settings.advanced
        var notes: [String] = [], warnings: [String] = []
        let profile = adv.profile ?? analysis.kind
        let finderSafe = needsFinderCompatibility(settings, caps: caps)

        // ---- encoder
        let candidates = candidateEncoders(settings: settings, caps: caps, hdr: media.video.dynamicRange.isHDR)
        guard var encoderID = candidates.first else { throw CirrusError.encoderUnavailable("required") }
        if let forced = adv.encoder {
            guard EncoderRegistry.encoder(forced).isAvailable(caps) else { throw CirrusError.encoderUnavailable(forced.rawValue) }
            encoderID = forced
        }
        if media.video.dynamicRange.isHDR && encoderID.codec == .h264 {
            encoderID = caps.hasX265 ? .x265 : .vtHEVC
            notes.append("HDR video: H.264 can’t carry HDR, so HEVC is used to keep the original colours.")
        }
        let encoder = EncoderRegistry.encoder(encoderID)
        let previewable = Self.playsInQuickLook(encoderID.codec, caps: caps)
        if settings.previewableOnThisMac && !previewable {
            warnings.append("\(encoderID.codec.rawValue) won’t play in Finder’s Quick Look or QuickTime on this Mac (it needs an AV1 hardware decoder, M3 or later). VLC, IINA, browsers and YouTube play it.")
        } else if finderSafe && settings.priority == .smallestFile && adv.encoder == nil {
            notes.append("HEVC instead of AV1, so the file plays in Finder’s Quick Look and QuickTime on this Mac. AV1 would be smaller (about 7 % on camera footage, less than half the size on animation, slides and screen recordings); choose “AV1 · Smallest” under Format for the smallest file.")
        }

        // ---- geometry & filters
        let outSize = settings.resolution.resolve(source: media.displaySize)

        // ---- text legibility guard
        var guardPlan = TextGuardPlan.inactive
        if text.hasText { guardPlan.moments = Array(text.moments.prefix(4).map(\.time)) }   // checked on the result either way
        switch settings.textGuard {
        case .off: guardPlan.reason = text.hasText ? "Off (text was detected: \(text.summary.lowercased()))" : "Off"
        case .on, .automatic:
            let on = settings.textGuard == .on || text.hasText
            guardPlan.active = on
            guardPlan.automatic = settings.textGuard == .automatic
            if !on { guardPlan.reason = text.sampledFrames > 0 ? "No slides, captions or on-screen text detected" : "Not checked" }
            else if text.hasText { guardPlan.reason = settings.textGuard == .automatic ? "On because text was detected: \(text.summary.lowercased())" : text.summary }
            else { guardPlan.reason = "On (no text detected, so it has nothing to protect)" }
            if on && text.smallestLinePx > 0 {
                guardPlan.moments = Array(text.moments.prefix(4).map(\.time))
                guardPlan.minimumShortSide = TextLegibility.minimumShortSide(for: text)
                guardPlan.smallestLineAtOutput = text.smallestLine(at: outSize)
                if guardPlan.smallestLineAtOutput < TextLegibility.minimumReadableLinePx && outSize.shortSide < media.displaySize.shortSide {
                    let need = guardPlan.minimumShortSide ?? media.displaySize.shortSide
                    let suggestion = OutputResolution.presets.filter { $0 != .original }.reversed()
                        .first { ($0.box?.height ?? 0) >= need && ($0.box?.height ?? .max) <= media.displaySize.shortSide } ?? .original
                    guardPlan.suggestedResolution = suggestion
                    warnings.append("At \(outSize.shortSide)p the smallest text would be about \(Int(guardPlan.smallestLineAtOutput.rounded())) px tall, which is hard to read. \(suggestion.label) keeps it readable.")
                }
            }
        }
        if case .custom(let w, let h, _) = settings.resolution, w > media.displaySize.width || h > media.displaySize.height {
            notes.append("The source is smaller than the requested size; it was kept at \(outSize) rather than upscaled.")
        }
        var filters: [String] = []
        if media.video.isInterlaced { filters.append("bwdif=mode=send_frame"); notes.append("Interlaced source deinterlaced.") }
        var fps = media.video.frameRate
        if let cap = adv.frameRateCap, cap > 0, fps > cap * 1.01 {
            filters.append("fps=\(String(format: "%.3f", cap))"); fps = cap
        }
        if outSize != media.video.codedSize || media.video.sampleAspectRatio != 1 {
            filters.append("scale=\(outSize.width):\(outSize.height):flags=lanczos+accurate_rnd+full_chroma_int")
            filters.append("setsar=1")
        }

        // Colour signalling: set on the frames themselves. (FFmpeg 9 encoders ignore
        // -color_primaries/-color_trc output options; frame properties always win.)
        var colourParams: [String] = []
        if let v = media.video.colorPrimaries, v != "unknown" { colourParams.append("color_primaries=\(v)") }
        if let v = media.video.colorTransfer, v != "unknown" { colourParams.append("color_trc=\(v)") }
        if let v = media.video.colorSpace, v != "unknown" { colourParams.append("colorspace=\(v)") }
        if let v = media.video.colorRange, v != "unknown" { colourParams.append("range=\(v)") }
        if !colourParams.isEmpty { filters.append("setparams=" + colourParams.joined(separator: ":")) }

        // ---- bit depth
        let tenBit: Bool
        switch adv.tenBit {
        case .on: tenBit = encoder.supports10Bit
        case .off: tenBit = false
        case .automatic:
            // Measured (Docs/ENCODING.md): on 8-bit camera footage 10-bit AV1 gave no
            // efficiency gain but cost ~35 % speed. It is used where it matters:
            // >8-bit or HDR sources, and smooth gradients / dark scenes / clean
            // synthetic imagery where 8-bit quantisation causes visible banding.
            // H.264 stays 8-bit (High 10 lacks hardware decode almost everywhere).
            tenBit = encoder.supports10Bit && (media.video.bitDepth > 8 || media.video.dynamicRange.isHDR
                                               || analysis.bandingRisk || analysis.isSynthetic)
        }
        if media.video.dynamicRange.isHDR && !tenBit { warnings.append("HDR source encoded at 8-bit: expect banding.") }

        // ---- film grain (AV1 only)
        var grain = 0
        if encoderID == .svtav1 {
            let wantGrain = adv.filmGrain ?? (analysis.isGrainy && profile == .liveAction && !guardPlan.active)
            if wantGrain { grain = min(16, max(4, Int((analysis.noiseSigma * 3).rounded()))) }
            if grain > 0 { notes.append("Film grain is modelled and re-synthesised on playback instead of being stored pixel by pixel.") }
        }

        let gopSecs = adv.keyframeSeconds ?? 10
        let speed = adv.speed ?? (encoderID.isHardware ? .balanced : EngineTuning.speed(for: settings.goal, duration: media.duration, encoder: encoderID))
        let params = VideoEncodeParameters(
            speed: speed, tenBit: tenBit, profile: profile,
            synthetic: adv.profile == .liveAction ? false : (adv.profile == .screenRecording ? true : analysis.isSynthetic),
            textGuard: guardPlan.active,
            filmGrain: grain,
            keyframeInterval: max(1, min(1200, Int((fps * gopSecs).rounded()))), frameRate: fps,
            dynamicRange: media.video.dynamicRange, colorPrimaries: media.video.colorPrimaries,
            colorTransfer: media.video.colorTransfer, colorSpace: media.video.colorSpace, colorRange: media.video.colorRange,
            extraEncoderParams: adv.extraEncoderParams.isEmpty ? nil : adv.extraEncoderParams)

        // ---- audio. For size targets, first plan at the standard tier, then step down only
        // if that would take a large share of the budget.
        func planAudio(_ pressure: Double) -> AudioPlan {
            AudioPlanner.plan(media: media, quality: settings.audio, codecChoice: adv.audioCodec, videoCodec: encoderID.codec,
                              preferCompatibility: settings.priority != .smallestFile || settings.previewableOnThisMac,
                              effectivelyMono: effectivelyMono,
                              budgetPressure: pressure, caps: caps, overrideKbps: adv.audioBitrateKbps)
        }
        var audio = planAudio(0)
        if case .targetSize(let bytes) = settings.goal, media.duration > 0, bytes > 0 {
            let share = Double(audio.bitrateKbps) * 1000 / 8 * media.duration / Double(bytes)
            audio = planAudio(share)
        }
        if let n = audio.note { notes.append(n) }

        // ---- rate strategy
        let rate: RateStrategy
        switch settings.goal {
        case .quality(let level):
            if let q = adv.qualityValue {
                rate = .fixedQuality(encoder.qualityScale.clamp(q))
            } else {
                let guess = EngineTuning.initialQuality(encoderID, level, kind: profile, synthetic: analysis.isSynthetic)
                var target = level.targetVMAF
                // Text sharpness is under-weighted by VMAF: one point more for screen recordings and guarded text.
                if profile == .screenRecording || guardPlan.active { target = min(98, target + 1) }
                if let t = adv.targetVMAF { target = min(99, max(50, t)) }
                rate = settings.depth == .quick ? .fixedQuality(guess) : .searchQuality(targetVMAF: target, initialGuess: guess)
            }
        case .targetSize(let bytes):
            let audioBytes = Double(audio.bitrateKbps) * 1000 / 8 * media.duration
            let overhead = SizeMath.containerOverhead(duration: media.duration, fps: fps, hasAudio: audio.codec != .none)
            let videoBytes = (Double(bytes) - audioBytes - overhead) * EngineTuning.sizeSafety(encoderID)
            let kbps = Int(videoBytes * 8 / max(media.duration, 0.1) / 1000)
            // Scaled by measured complexity: a static animation needs a fraction of what a crowd scene does.
            let minKbps = Int(Double(SizeMath.minimumSensibleKbps(size: outSize, fps: fps, codec: encoderID.codec))
                              * min(3, max(0.1, analysis.complexity)))
            if kbps < max(20, minKbps / 12) {
                let suggest = SizeMath.bytes(forVideoKbps: minKbps, audioKbps: audio.bitrateKbps, duration: media.duration)
                throw CirrusError.targetUnreachable(
                    "\(Fmt.bytes(bytes)) is too small for \(Fmt.duration(media.duration)) of \(outSize.shortSide)p video — " +
                    "there would only be \(max(0, kbps)) kbps for the picture. Try at least \(Fmt.bytes(suggest)), or a lower resolution.")
            }
            if kbps < minKbps / 2 {
                warnings.append("\(Fmt.bytes(bytes)) is very tight for this video at \(outSize.shortSide)p. The engine will do its best (and try lower resolutions if allowed), but expect obvious quality loss.")
            } else if kbps < minKbps {
                warnings.append("\(Fmt.bytes(bytes)) is a tight budget for \(outSize.shortSide)p at this length: expect visible softening and blockiness in busy scenes.")
            }
            if bytes >= media.fileSize && media.fileSize > 0 {
                notes.append("The target is larger than the original file, so the engine will aim for transparent quality and use only the space it needs.")
            }
            rate = .targetSize(bytes: bytes, videoKbps: max(8, kbps))
        }

        return EncodePlan(encoder: encoderID, params: params, rate: rate, outputSize: outSize, videoFilters: filters,
                          audio: audio, depth: settings.depth, allowLowerResolution: adv.allowLowerResolution,
                          candidates: candidates, notes: notes, warnings: warnings, textGuard: guardPlan,
                          previewableOnThisMac: previewable)
    }

    /// Whether Apple's playback stack on this Mac (Quick Look, QuickTime, Photos) plays a codec.
    public static func playsInQuickLook(_ c: VideoCodec, caps: FFmpegCapabilities) -> Bool {
        switch c {
        case .h264, .hevc: return true
        case .av1: return caps.systemDecodesAV1
        case .vp9: return false
        }
    }

    /// The “Preview in Finder on this Mac” setting changes the encoder only where this Mac can't play AV1.
    public static func needsFinderCompatibility(_ s: CompressionSettings, caps: FFmpegCapabilities) -> Bool {
        s.previewableOnThisMac && !caps.systemDecodesAV1
    }

    /// Ordered encoder candidates for a priority, filtered by what this FFmpeg build offers.
    public static func candidateEncoders(settings: CompressionSettings, caps: FFmpegCapabilities, hdr: Bool) -> [EncoderID] {
        let order: [EncoderID]
        if settings.advanced.preferHardware {
            order = [.vtHEVC, .vtH264, .svtav1, .x265, .x264]
        } else {
            switch settings.priority {
            case .smallestFile where needsFinderCompatibility(settings, caps: caps): order = [.x265, .vtHEVC, .x264]
            case .smallestFile: order = [.svtav1, .x265, .vp9, .x264, .vtHEVC]
            case .appleDevices: order = [.x265, .vtHEVC, .x264]
            case .playsEverywhere: order = hdr ? [.x265, .vtHEVC] : [.x264, .vtH264]
            case .fastest: order = [.vtHEVC, .vtH264, .x264]
            }
        }
        return order.filter { EncoderRegistry.encoder($0).isAvailable(caps) }
    }
}

public enum SizeMath {
    /// MP4 index + headers: per-sample tables dominate (~12 B/frame, ~10 B/audio packet).
    public static func containerOverhead(duration: Double, fps: Double, hasAudio: Bool) -> Double {
        let frames = duration * fps
        let audioPackets = hasAudio ? duration * 48 : 0
        return 4096 + frames * 12 + audioPackets * 10
    }

    /// Below this the picture is likely to fall apart for typical content
    /// (bits per pixel per frame, codec-adjusted). Used only for warnings.
    public static func minimumSensibleKbps(size: PixelSize, fps: Double, codec: VideoCodec) -> Int {
        let bpp: Double
        switch codec {
        case .av1: bpp = 0.012
        case .hevc, .vp9: bpp = 0.017
        case .h264: bpp = 0.026
        }
        return Int(Double(size.pixels) * min(fps, 60) * bpp / 1000)
    }

    public static func bytes(forVideoKbps v: Int, audioKbps a: Int, duration: Double) -> Int64 {
        Int64(Double(v + a) * 1000 / 8 * duration * 1.03)
    }
}

/// Formatting helpers shared by engine messages and the UI.
public enum Fmt {
    public static func bytes(_ b: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: b)
    }
    public static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) }
        return String(format: "%d:%02d", t / 60, t % 60)
    }
    public static func eta(_ s: Double) -> String {
        if s < 60 { return "\(max(1, Int(s))) s" }
        if s < 3600 { return "\(Int(s / 60)) min \(Int(s) % 60) s" }
        return "\(Int(s / 3600)) h \(Int(s / 60) % 60) min"
    }
}
