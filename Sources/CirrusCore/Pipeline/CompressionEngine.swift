import Foundation
import CoreGraphics

/// A source video that has been probed and analysed.
public struct SourceItem: Sendable, Identifiable {
    public let id = UUID()
    public var media: MediaInfo
    public var analysis: ContentAnalysis
    public var effectivelyMono: Bool
    /// Text found by on-device recognition (slides, captions, UI).
    public var text: TextAnalysis = .none
}

/// Final encoding decision produced by the optimisation stage.
public struct EncodeDecision: Sendable {
    public enum FinalRate: Sendable, Equatable {
        case constantQuality(Double)
        case twoPass(kbps: Int)            // or single-pass ABR for encoders without 2-pass
    }
    public var encoder: EncoderID
    public var params: VideoEncodeParameters
    public var outputSize: PixelSize
    public var filters: String?
    public var rate: FinalRate
    public var audio: AudioPlan
    /// Trial result on samples at the chosen settings (Smart / Best Possible).
    public var sampleTrial: TrialResult?
    public var notes: [String]
    public var warnings: [String]
    /// Text legibility measured on sample moments at the chosen settings.
    public var textCheck: TextLegibilityReport? = nil
    /// OCR agreement of a near-lossless encode of the same moments (the 100 % mark).
    public var textCeiling: TextLegibilityReport? = nil
    /// Extra size the text guard added on samples (fraction, e.g. 0.12 = +12 %).
    public var textGuardCost: Double? = nil
}

public struct CompressionResult: Sendable, Codable {
    public var outputURL: URL
    public var sourceURL: URL
    public var originalBytes: Int64
    public var outputBytes: Int64
    public var targetBytes: Int64?
    public var outputSize: PixelSize
    public var codec: VideoCodec
    public var encoder: EncoderID
    public var speedLabel: String
    public var tenBit: Bool
    public var videoKbps: Int
    public var audioSummary: String
    public var duration: Double
    public var quality: QualityReport?
    public var sampleQuality: QualityReport?
    public var elapsed: Double
    public var notes: [String]
    public var warnings: [String]
    public var settingsSummary: String
    /// Text legibility of the finished file (when the text guard was active).
    public var textCheck: TextLegibilityReport? = nil
    public var textGuardActive: Bool = false
    /// Plays in Finder's Quick Look / QuickTime on this Mac.
    public var previewableOnThisMac: Bool = true
    /// Where the original went when it was replaced (so it can be restored).
    public var trashedOriginal: URL? = nil

    public var reduction: Double { originalBytes > 0 ? 1 - Double(outputBytes) / Double(originalBytes) : 0 }
    public var metTarget: Bool? { targetBytes.map { outputBytes <= $0 } }
}

/// The engine façade used by the app and the CLI.
public final class CompressionEngine: Sendable {
    public let tools: ToolPaths
    public let caps: FFmpegCapabilities
    let decisionCache = DecisionCache()

    public init(tools: ToolPaths, caps: FFmpegCapabilities) { self.tools = tools; self.caps = caps }

    public static func make() async throws -> CompressionEngine {
        let tools = try ToolLocator.locate()
        let caps = try await ToolLocator.capabilities(of: tools)
        Log.info("FFmpeg: \(caps.version); SVT-AV1 \(caps.hasSVTAV1), x265 \(caps.hasX265), x264 \(caps.hasX264), VT \(caps.hasVTHEVC), VMAF \(caps.hasVMAF)")
        TempWorkspace.sweepStale()
        return CompressionEngine(tools: tools, caps: caps)
    }

    // MARK: inspection

    public func inspect(_ url: URL) async throws -> SourceItem {
        let media = try await MediaProbe(tools: tools).probe(url)
        async let analysis = ContentAnalyzer(tools: tools).analyze(media)
        async let mono = AudioAnalyzer(tools: tools).isEffectivelyMono(media)
        async let text = TextAnalyzer(tools: tools).analyze(media)
        return SourceItem(media: media, analysis: try await analysis, effectivelyMono: await mono, text: await text)
    }

    public func plan(_ item: SourceItem, settings: CompressionSettings) throws -> EncodePlan {
        try EncodePlanner.plan(media: item.media, analysis: item.analysis, settings: settings, caps: caps,
                               effectivelyMono: item.effectivelyMono, text: item.text)
    }

    // MARK: decision (optimisation)

    /// - Parameter light: shorter samples and fewer probes (Preview Studio and estimates). The
    ///   real compression always runs the full search.
    func decide(_ item: SourceItem, plan: EncodePlan, settings: CompressionSettings, workspace: TempWorkspace,
                tracker: ProgressTracker, light: Bool = false) async throws -> EncodeDecision {
        var d = EncodeDecision(encoder: plan.encoder, params: plan.params, outputSize: plan.outputSize, filters: plan.filterChain,
                               rate: .constantQuality(0), audio: plan.audio, sampleTrial: nil, notes: plan.notes, warnings: plan.warnings)
        let media = item.media
        let canMeasure = caps.hasVMAF

        func buildSamples() async throws -> SampleSet {
            let key = "\(item.id)|\(plan.filterChain ?? "")|\(plan.outputSize)|\(light)|\(workspace.url.path)"
            if let cached = await decisionCache.sample(key) { tracker.update(.sampling, 1); return cached }
            tracker.update(.sampling, 0, detail: "Extracting representative scenes")
            let s = try await SampleBuilder(tools: tools).build(media: media, filters: plan.filterChain, outputSize: plan.outputSize,
                                                                fps: plan.params.frameRate, totalSeconds: light ? 8 : 20, workspace: workspace,
                                                                label: "samples-\(UUID().uuidString.prefix(4))")
            await decisionCache.setSample(key, s)
            tracker.update(.sampling, 1)
            return s
        }
        let optimiser = Optimizer(tools: tools, workspace: workspace) { f, detail in tracker.update(.optimising, f, detail: detail) }
        // Re-compressing an already-compressed file must not make it bigger.
        let sourceVideoKbps = media.video.bitrate.map { Double($0) / 1000 }
        let isMezzanine = ["prores", "dnxhd", "ffv1", "rawvideo", "huffyuv", "utvideo", "v210", "qtrle", "png"].contains(media.video.codec)
        let pixelRatio = (Double(plan.outputSize.pixels) / Double(max(1, media.video.codedSize.pixels))).squareRoot().clamped(0.5, 1)
        let sizeCap: Double? = (sourceVideoKbps != nil && !isMezzanine) ? sourceVideoKbps! * 0.85 * pixelRatio : nil

        switch plan.rate {
        case .fixedQuality(let v):
            d.rate = .constantQuality(v)

        case .searchQuality(let target, let guess):
            guard canMeasure else { d.rate = .constantQuality(guess); d.notes.append("VMAF unavailable: used predicted settings."); break }
            let samples = try await buildSamples()
            var outcomes: [(EncoderID, VideoEncodeParameters, QualitySearchOutcome)] = []
            let candidates = plan.depth == .bestPossible ? bestPossibleCandidates(plan) : [plan.encoder]
            for (i, enc) in candidates.enumerated() {
                var p = plan.params
                if enc != plan.encoder { p = paramsFor(enc, base: plan.params, settings: settings, duration: media.duration) }
                let g = enc == plan.encoder ? guess : EngineTuning.initialQuality(enc, levelFor(target), kind: p.profile, synthetic: p.synthetic)
                let o = try await optimiser.searchQuality(encoder: enc, params: p, sample: samples, targetVMAF: target, initial: g,
                                                          maxKbps: sizeCap, maxProbes: light ? 3 : 5, progressBase: Double(i) / Double(candidates.count),
                                                          progressSpan: 1 / Double(candidates.count))
                outcomes.append((enc, p, o))
            }
            // Smallest bitrate among encoders that reached the target; prefer earlier (more efficient / preferred) on near-ties.
            let reached = outcomes.filter { $0.2.reachedTarget }
            let pool = reached.isEmpty ? outcomes : reached
            var best = pool[0]
            for o in pool.dropFirst() where o.2.trial.kbps < best.2.trial.kbps * 0.97 { best = o }
            if reached.isEmpty { best = outcomes.max { $0.2.trial.quality.vmaf < $1.2.trial.quality.vmaf }! }
            d.encoder = best.0; d.params = best.1; d.rate = .constantQuality(best.2.value); d.sampleTrial = best.2.trial
            if outcomes.count > 1 {
                let summary = outcomes.map { "\($0.0.codec.rawValue) \(Int($0.2.trial.kbps)) kbps" }.joined(separator: " vs ")
                d.notes.append("Compared on samples at equal quality: \(summary). Chose \(best.0.codec.rawValue).")
            }
            if plan.textGuard.active && !plan.textGuard.moments.isEmpty {
                try await guardText(item, plan: plan, decision: &d, samples: samples, optimiser: optimiser, tracker: tracker)
            }
            if !best.2.reachedTarget {
                if best.2.cappedBySourceBitrate {
                    d.notes.append("The original is already efficiently compressed; quality was capped so the result stays smaller than it.")
                } else {
                    d.notes.append(String(format: "This footage tops out around VMAF %.1f even at very high bitrates (common with noisy or already-compressed sources).", best.2.trial.quality.vmaf))
                }
            }

        case .targetSize(let bytes, let kbps0):
            var kbps = kbps0
            guard plan.depth != .quick, canMeasure else { d.rate = .twoPass(kbps: kbps); break }
            let samples = try await buildSamples()
            // Candidate (encoder, resolution) pairs.
            var sizes = [plan.outputSize]
            if plan.allowLowerResolution, let lower = OutputResolution.stepDown(from: plan.outputSize) {
                let sensible = Double(SizeMath.minimumSensibleKbps(size: plan.outputSize, fps: plan.params.frameRate, codec: plan.encoder.codec))
                    * min(3, max(0.1, item.analysis.complexity))
                let tight = Double(kbps) < sensible * 2
                if plan.depth == .bestPossible || tight { sizes.append(lower) }
                // very tight: also try two steps down
                if Double(kbps) < sensible, let lower2 = OutputResolution.stepDown(from: lower) { sizes.append(lower2) }
                // text guard: never scale below the size where the smallest text stays readable
                if plan.textGuard.active, let m = plan.textGuard.minimumShortSide {
                    let before = sizes.count
                    sizes = sizes.filter { $0 == plan.outputSize || $0.shortSide >= m }
                    if sizes.count < before { d.notes.append("Lower resolutions weren’t tried: they would make the smallest text too small to read.") }
                }
            }
            let encoders = plan.depth == .bestPossible ? bestPossibleCandidates(plan) : [plan.encoder]
            var trials: [(TrialResult, PixelSize)] = []
            let total = Double(encoders.count * sizes.count)
            var n = 0.0
            var lowerSamples: [PixelSize: SampleSet] = [:]
            for enc in encoders {
                let p = enc == plan.encoder ? plan.params : paramsFor(enc, base: plan.params, settings: settings, duration: media.duration)
                for size in sizes {
                    tracker.update(.optimising, n / total, detail: "Testing \(enc.codec.rawValue) at \(size.shortSide)p on sample scenes")
                    var s = samples
                    if size != plan.outputSize {
                        if lowerSamples[size] == nil { lowerSamples[size] = try await optimiser.downscaled(samples, to: size) }
                        s = lowerSamples[size]!
                    }
                    let t = try await optimiser.trial(encoder: enc, params: p, rate: .bitrate(kbps: kbps), sample: s, reference: samples)
                    trials.append((t, size)); n += 1
                }
            }
            // Pick best measured quality; a lower resolution or different codec must win clearly.
            var best = trials[0]
            for t in trials.dropFirst() {
                let margin = (t.1 != plan.outputSize ? 1.0 : 0) + (t.0.encoder != plan.encoder ? 0.4 : 0)
                if t.0.quality.vmaf > best.0.quality.vmaf + margin { best = t }
            }
            d.encoder = best.0.encoder; d.params = best.0.params; d.sampleTrial = best.0
            if trials.count > 1 {
                d.notes.append("Compared on samples at \(kbps) kbps: " + trials.map { String(format: "%@ %dp VMAF %.1f", $0.0.encoder.codec.rawValue, $0.1.shortSide, $0.0.quality.vmaf) }.joined(separator: ", ") + ".")
            }
            if best.1 != plan.outputSize {
                d.outputSize = best.1
                d.filters = Self.replaceScale(in: plan.filterChain, with: best.1)
                d.notes.append("At this size, \(best.1.shortSide)p looks better than \(plan.outputSize.shortSide)p (measured), so the video was scaled to \(best.1).")
                kbps = Int(Double(kbps) * EngineTuning.sizeSafety(d.encoder) / EngineTuning.sizeSafety(plan.encoder))
            }
            d.rate = .twoPass(kbps: kbps)

            // Generous budget? If the target bitrate is already transparent, find the
            // constant-quality setting for "Maximum Quality" and use only what's needed.
            if best.0.quality.vmaf >= QualityLevel.maximum.targetVMAF {
                tracker.update(.optimising, 0.9, detail: "Budget is generous — checking how little space is needed")
                let o = try await optimiser.searchQuality(encoder: d.encoder, params: d.params, sample: samples,
                                                          targetVMAF: QualityLevel.maximum.targetVMAF,
                                                          initial: EngineTuning.initialQuality(d.encoder, .maximum, kind: d.params.profile, synthetic: d.params.synthetic),
                                                          maxKbps: Double(kbps) * 0.9, maxProbes: 3, progressBase: 0.9, progressSpan: 0.1)
                if o.reachedTarget {
                    d.rate = .constantQuality(o.value); d.sampleTrial = o.trial
                    d.notes.append("\(Fmt.bytes(bytes)) is more than this video needs: it reaches near-transparent quality with less, so the file will come in under the target.")
                }
            } else if best.0.quality.vmaf < 70 {
                d.warnings.append(String(format: "Measured on samples, quality at this size is low (VMAF %.0f). A larger target or lower resolution will look noticeably better.", best.0.quality.vmaf))
            }
        }
        return d
    }

    /// Text legibility guard (constant-quality modes): encode short clips around the moments with
    /// the smallest text, read the text back with on-device OCR, and raise quality until at least
    /// `TextLegibility.requiredAccuracy` of the characters read identically to the original.
    func guardText(_ item: SourceItem, plan: EncodePlan, decision d: inout EncodeDecision, samples: SampleSet,
                   optimiser: Optimizer, tracker: ProgressTracker) async throws {
        guard case .constantQuality(var v) = d.rate else { return }
        let scale = EncoderRegistry.encoder(d.encoder).qualityScale
        let stepAmount = max(scale.step, (2.5 / EngineTuning.vmafPerUnit(d.encoder) / scale.step).rounded() * scale.step)
        let limit = EngineTuning.practicalQualityLimit(d.encoder)
        var report: TextLegibilityReport? = nil
        var raised = 0
        let ceilingKey = "\(item.id)|\(d.encoder.rawValue)|\(d.filters ?? "")|\(d.outputSize)"
        var ceiling = await decisionCache.ceiling(ceilingKey)
        if ceiling == nil {
            tracker.update(.optimising, 0.9, detail: "Reading on-screen text at near-lossless quality (reference)")
            ceiling = try await textClipCheck(item, decision: d, value: limit, plan: plan)
            if let c = ceiling { await decisionCache.setCeiling(ceilingKey, c) }
        }
        d.textCeiling = ceiling
        while true {
            tracker.update(.optimising, 0.92, detail: raised == 0 ? "Checking that text stays readable" : "Raising quality for small text (step \(raised))")
            report = try await textClipCheck(item, decision: d, value: v, plan: plan)?.relative(to: ceiling)
            guard let r = report, r.accuracy < TextLegibility.requiredAccuracy, raised < 3 else { break }
            let next = scale.better(v, by: stepAmount)
            if next == v || (scale.lowerIsBetter ? next < limit : next > limit) { break }
            v = next; raised += 1
        }
        d.textCheck = report
        guard raised > 0 else { return }
        let before = d.sampleTrial?.kbps
        d.rate = .constantQuality(v)
        let t = try await optimiser.trial(encoder: d.encoder, params: d.params, rate: .quality(v), sample: samples, reference: samples)
        d.sampleTrial = t
        if let b = before, b > 0 { d.textGuardCost = t.kbps / b - 1 }
        let cost = d.textGuardCost.map { String(format: " (about %+.0f%% size)", $0 * 100) } ?? ""
        d.notes.append("Quality raised so small text stays readable\(cost).")
        if let r = report, r.accuracy < TextLegibility.requiredAccuracy {
            d.warnings.append(String(format: "Some small text still doesn’t read perfectly (%.0f%% of characters match). A higher resolution would help.", r.accuracy * 100))
        }
    }

    /// Encode 2-second clips around the text moments at `value` and score legibility.
    func textClipCheck(_ item: SourceItem, decision d: EncodeDecision, value: Double, plan: EncodePlan) async throws -> TextLegibilityReport? {
        let ws = try TempWorkspace(label: "text")
        defer { ws.remove() }
        let enc = EncoderRegistry.encoder(d.encoder)
        let run = FFmpegRun(tools: tools)
        var starts: [Double] = []
        var clips: [URL] = []
        for (i, t) in plan.textGuard.moments.enumerated() {
            // The checked frame sits ~5 s after the clip's keyframe, like most frames of the real
            // encode (a frame right after a keyframe looks better than average and would flatter the check).
            let start = max(0, t - 5)
            let out = ws.file("text-\(i).mkv")
            var a = ["-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", t - start + 0.5), "-i", item.media.url.path, "-map", "0:v:0"]
            if let f = d.filters { a += ["-vf", f] }
            try await run.run(a + enc.arguments(d.params, rate: .quality(value), pass: .single, threads: nil) + ["-an", out.path], duration: t - start + 0.5)
            starts.append(start); clips.append(out)
        }
        let checker = TextLegibilityChecker(tools: tools)
        let g = FrameGrabber(tools: tools)
        let refFilters = d.filters.map(TextLegibilityChecker.withoutScale).flatMap { $0.isEmpty ? nil : $0 }
        var pairs: [([CGImage], CGImage)] = []
        for (i, t) in plan.textGuard.moments.enumerated() {
            let refs = try await checker.referenceFrames(item.media.url, at: t, fps: d.params.frameRate, size: d.outputSize, filters: refFilters)
            let e = try await g.frame(clips[i], at: t - starts[i], exactSize: d.outputSize)
            pairs.append((refs, e))
        }
        let report = TextLegibilityChecker.score(pairs, smallestLinePx: item.text.smallestLine(at: d.outputSize))
        if let r = report { Log.info(String(format: "text check @%.1f: %.1f%% of %d chars", value, r.accuracy * 100, r.characters)) }
        return report
    }

    /// Encoders worth comparing in Best Possible mode (efficient software encoders of the chosen priority).
    func bestPossibleCandidates(_ plan: EncodePlan) -> [EncoderID] {
        var c = [plan.encoder]
        for e in plan.candidates where !e.isHardware && e != plan.encoder && c.count < 2 {
            if plan.encoder == .svtav1 && e == .x265 { c.append(e) }
            if plan.encoder == .x265 && e == .x264 { continue }
        }
        return c
    }

    func paramsFor(_ e: EncoderID, base: VideoEncodeParameters, settings: CompressionSettings, duration: Double) -> VideoEncodeParameters {
        var p = base
        p.speed = settings.advanced.speed ?? EngineTuning.speed(for: settings.goal, duration: duration, encoder: e)
        p.tenBit = EncoderRegistry.encoder(e).supports10Bit && base.tenBit
        if e != .svtav1 { p.filmGrain = 0 }
        p.extraEncoderParams = nil
        return p
    }

    func levelFor(_ vmaf: Double) -> QualityLevel { QualityLevel.allCases.min { abs($0.targetVMAF - vmaf) < abs($1.targetVMAF - vmaf) }! }

    static func replaceScale(in chain: String?, with size: PixelSize) -> String {
        let scale = "scale=\(size.width):\(size.height):flags=lanczos+accurate_rnd+full_chroma_int"
        var parts = (chain ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        if let i = parts.firstIndex(where: { $0.hasPrefix("scale=") }) { parts[i] = scale } else { parts += [scale, "setsar=1"] }
        return parts.joined(separator: ",")
    }

    // MARK: compress

    /// Compress one item. Never touches the source; writes to a hidden partial
    /// file next to the destination and renames it only on success.
    /// - Parameter versionLabel: names the output "<name> (<label>).mp4" (several versions of one video).
    public func compress(_ item: SourceItem, settings: CompressionSettings, destinationDirectory: URL, versionLabel: String? = nil,
                         progress: @escaping @Sendable (JobProgress) -> Void) async throws -> CompressionResult {
        let started = Date()
        let media = item.media
        let tracker = ProgressTracker(sink: progress)
        let plan = try self.plan(item, settings: settings)
        let workspace = try TempWorkspace(label: "job")
        defer { workspace.remove() }

        let outURL = try Self.outputURL(for: media.url, in: destinationDirectory, settings: settings, label: versionLabel)
        let partial = destinationDirectory.appendingPathComponent(".\(outURL.deletingPathExtension().lastPathComponent).cirrus-partial-\(UUID().uuidString.prefix(6)).mp4")
        let cleanup = { try? FileManager.default.removeItem(at: partial) }

        // Disk space: output can't be bigger than the source (or target), plus samples.
        let expected = { () -> Int64 in if case .targetSize(let b) = settings.goal { return b }; return media.fileSize }()
        if let avail = DiskSpace.available(at: destinationDirectory), avail < expected + 200_000_000 {
            throw CirrusError.insufficientDiskSpace(needed: expected + 200_000_000, available: avail)
        }

        // Stage weights in "seconds of final-encode work".
        let D = media.duration
        let searching: Bool = { if case .fixedQuality = plan.rate { return false }; if case .targetSize = plan.rate { return plan.depth != .quick }; return true }()
        let candidates = Double(plan.depth == .bestPossible ? 2 : 1)
        let optimiseCost = searching ? min(D * 3, 20 * 4 * candidates) : 0
        let twoPass: Bool = { if case .targetSize = plan.rate { return EncoderRegistry.encoder(plan.encoder).supportsTwoPass }; return false }()
        tracker.configure([(.sampling, searching ? min(D, 20) * 0.3 : 0), (.optimising, optimiseCost), (.encodingAudio, plan.audio.codec == .none || plan.audio.codec == .copy ? 0 : D * 0.01),
                           (.firstPass, twoPass ? D * 0.3 : 0), (.encoding, D), (.measuring, settings.measureQuality && caps.hasVMAF ? D * 0.2 : 0),
                           (.finishing, D * 0.01)])

        do {
            var d = try await cachedDecision(item, plan: plan, settings: settings, workspace: workspace, tracker: tracker)
            try Task.checkCancellation()

            // ---- not worth it? (sample prediction; the finished file is checked again below)
            let mustShrink: Bool = { if case .targetSize(let b) = settings.goal { return media.fileSize > b }; return false }()
            let minSave = mustShrink ? 0 : max(0, settings.minimumSavings)
            if minSave > 0, let t = d.sampleTrial, media.fileSize > 0, D > 0 {
                let predicted = (t.kbps + Double(d.audio.bitrateKbps)) * 1000 / 8 * D
                let saving = 1 - predicted / Double(media.fileSize)
                if saving < minSave * 0.5 {
                    throw CirrusError.notWorthIt(String(format: "Skipped: this video is already efficiently compressed. Re-encoding would save only about %.0f%% (your minimum is %.0f%%), so the original was left as it is.", max(0, saving) * 100, minSave * 100))
                }
            }

            // ---- audio first, so its exact size is known before the video budget is fixed
            var audioInput: URL? = nil
            var audioBytes: Double = 0
            switch d.audio.codec {
            case .aac, .opus:
                tracker.update(.encodingAudio, 0, detail: d.audio.summary)
                let a = workspace.file("audio.mp4")
                try await FFmpegRun(tools: tools).run(["-i", media.url.path, "-vn", "-sn", "-dn"] + d.audio.ffmpegArguments() + [a.path],
                                                      duration: D) { tracker.update(.encodingAudio, $0.fraction) }
                audioInput = a
                audioBytes = Double((try? FileManager.default.attributesOfItem(atPath: a.path)[.size] as? NSNumber)?.int64Value ?? 0)
            case .copy:
                audioBytes = Double(d.audio.bitrateKbps) * 1000 / 8 * D
            case .none: break
            }
            var targetBytes: Int64? = nil
            if case .targetSize(let bytes) = settings.goal {
                targetBytes = bytes
                if case .twoPass = d.rate {
                    let overhead = SizeMath.containerOverhead(duration: D, fps: d.params.frameRate, hasAudio: d.audio.codec != .none)
                    let video = (Double(bytes) - audioBytes - overhead) * EngineTuning.sizeSafety(d.encoder)
                    let kbps = max(8, Int(video * 8 / max(D, 0.1) / 1000))
                    d.rate = .twoPass(kbps: kbps)
                }
            }

            // ---- video
            let enc = EncoderRegistry.encoder(d.encoder)
            let passlog = workspace.file("pass").path
            var finalKbps: Int? = nil
            var didFirstPass = false
            func encodeArgs(_ rate: RateControl, _ pass: EncodePass, output: String) -> [String] {
                var a = ["-i", media.url.path]
                if let audioInput { a += ["-i", audioInput.path] }
                a += ["-map", "0:v:0"]
                if let f = d.filters { a += ["-vf", f] }
                if media.video.isVariableFrameRate && !(d.filters ?? "").contains("fps=") { a += ["-fps_mode", "passthrough"] }
                a += enc.arguments(d.params, rate: rate, pass: pass, threads: nil)
                if case .first = pass { return a + ["-an", "-f", "null", "-"] }
                if audioInput != nil { a += ["-map", "1:a:0", "-c:a", "copy"] }
                else { a += d.audio.ffmpegArguments() }
                a += ["-map_metadata", "0", "-map_chapters", "0", "-movflags", "+faststart",
                      "-f", "mp4", output]
                return a
            }
            let run = FFmpegRun(tools: tools)
            switch d.rate {
            case .constantQuality(let v):
                tracker.update(.encoding, 0, detail: "\(d.encoder.codec.rawValue) · \(d.outputSize)")
                try await run.run(encodeArgs(.quality(v), .single, output: partial.path), duration: D) {
                    tracker.update(.encoding, $0.fraction, speed: $0.speed)
                }
            case .twoPass(let kbps):
                finalKbps = kbps
                if enc.supportsTwoPass {
                    tracker.update(.firstPass, 0, detail: "Pass 1 of 2")
                    try await run.run(encodeArgs(.bitrate(kbps: kbps), .first(logPrefix: passlog), output: "-"), duration: D) {
                        tracker.update(.firstPass, $0.fraction, speed: $0.speed)
                    }
                    didFirstPass = true
                }
                tracker.update(.encoding, 0, detail: enc.supportsTwoPass ? "Pass 2 of 2" : nil)
                try await run.run(encodeArgs(.bitrate(kbps: kbps), enc.supportsTwoPass ? .second(logPrefix: passlog) : .single, output: partial.path), duration: D) {
                    tracker.update(.encoding, $0.fraction, speed: $0.speed)
                }
            }

            // ---- size verification (target mode): never silently exceed the target
            if let target = targetBytes {
                var attempt = 0
                var actual = Self.fileSize(partial)
                while actual > target && attempt < 2 {
                    attempt += 1
                    let nonVideo = audioBytes + SizeMath.containerOverhead(duration: D, fps: d.params.frameRate, hasAudio: d.audio.codec != .none)
                    let prevKbps: Int = finalKbps ?? Int((Double(actual) - nonVideo) * 8 / D / 1000)
                    let ratio = (Double(target) * 0.985 - nonVideo) / max(1, Double(actual) - nonVideo)
                    let kbps = max(8, Int(Double(prevKbps) * ratio))
                    Log.warning("output \(actual) B > target \(target) B; re-encoding at \(kbps) kbps (attempt \(attempt))")
                    tracker.addStage(.adjusting, weight: D, after: .encoding)
                    tracker.update(.adjusting, 0, detail: "Slightly over target — tightening")
                    if enc.supportsTwoPass && !didFirstPass {
                        // came from a constant-quality encode: needs a first pass now
                        try await run.run(encodeArgs(.bitrate(kbps: kbps), .first(logPrefix: passlog), output: "-"), duration: D) {
                            tracker.update(.adjusting, $0.fraction * 0.3)
                        }
                        didFirstPass = true
                    }
                    try? FileManager.default.removeItem(at: partial)
                    try await run.run(encodeArgs(.bitrate(kbps: kbps), enc.supportsTwoPass ? .second(logPrefix: passlog) : .single, output: partial.path), duration: D) {
                        tracker.update(.adjusting, 0.3 + $0.fraction * 0.7)
                    }
                    finalKbps = kbps
                    actual = Self.fileSize(partial)
                    d.rate = .twoPass(kbps: kbps)
                }
                if actual > target {
                    d.warnings.append("The result is \(Fmt.bytes(actual - target)) over the target after two corrections.")
                }
            }

            // ---- worth keeping?
            let partialBytes = Self.fileSize(partial)
            if media.fileSize > 0 && !mustShrink {
                let saving = 1 - Double(partialBytes) / Double(media.fileSize)
                if saving <= 0 || saving < minSave {
                    cleanup()
                    throw CirrusError.notWorthIt(saving <= 0
                        ? "Skipped: the result wasn’t smaller than the original, so the original was left as it is."
                        : String(format: "Skipped: compressing saved only %.0f%% (your minimum is %.0f%%), so the original was left as it is.", saving * 100, minSave * 100))
                }
            }

            // ---- quality measurement on the real output
            var report: QualityReport? = nil
            if settings.measureQuality && caps.hasVMAF {
                tracker.update(.measuring, 0, detail: "Comparing every frame with the original (VMAF)")
                let frames = D * d.params.frameRate
                let sub = max(1, Int((frames / 2400).rounded(.up)))       // ≤ ~2400 scored frames
                do {
                    report = try await QualityMeter(tools: tools).measure(
                        reference: media.url, referenceFilters: d.filters, distorted: partial, size: d.outputSize, fps: d.params.frameRate,
                        subsample: sub, duration: D, scope: .fullVideo, workspace: workspace) { tracker.update(.measuring, $0) }
                } catch CirrusError.cancelled { throw CirrusError.cancelled
                } catch { d.warnings.append("Quality measurement failed: \(error.localizedDescription)") }
            }

            // ---- text legibility of the finished file
            var textReport: TextLegibilityReport? = nil
            if !plan.textGuard.moments.isEmpty {
                tracker.update(.measuring, 1, detail: "Checking that on-screen text is readable")
                if d.textCeiling == nil, case let limit = EngineTuning.practicalQualityLimit(d.encoder) {
                    d.textCeiling = try? await textClipCheck(item, decision: d, value: limit, plan: plan)
                }
                textReport = try? await TextLegibilityChecker(tools: tools).check(
                    source: media.url, sourceFilters: d.filters, encoded: partial, size: d.outputSize, fps: d.params.frameRate,
                    moments: plan.textGuard.moments,
                    encodedTime: { $1 }, smallestLinePx: item.text.smallestLine(at: d.outputSize))?.relative(to: d.textCeiling)
                if let r = textReport, r.accuracy < TextLegibility.warnAccuracy {
                    d.warnings.append(String(format: "Some small text may be hard to read: %.0f%% of the characters read the same as the original. %@", r.accuracy * 100,
                                             plan.textGuard.active ? "A higher quality level or resolution will help." : "Turn on “Keep text readable” to protect it."))
                }
            }

            tracker.update(.finishing, 0)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: partial, to: outURL)
            CirrusMarker.mark(outURL, summary: Self.describe(d))
            tracker.update(.finishing, 1)

            let outBytes = Self.fileSize(outURL)
            if let t = targetBytes, Double(outBytes) < Double(t) * 0.85, !d.notes.contains(where: { $0.contains("under the target") }) {
                let q = report.map { String(format: " (measured VMAF %.1f)", $0.vmaf) } ?? ""
                d.notes.append("Finished under the target: \(Fmt.bytes(outBytes)) of \(Fmt.bytes(t)). This video reached its quality\(q) without needing the rest — the encoder had nothing useful to spend it on.")
            }
            let vKbps = Int((Double(outBytes) - audioBytes) * 8 / max(D, 0.1) / 1000)
            let result = CompressionResult(
                outputURL: outURL, sourceURL: media.url, originalBytes: media.fileSize, outputBytes: outBytes, targetBytes: targetBytes,
                outputSize: d.outputSize, codec: d.encoder.codec, encoder: d.encoder, speedLabel: d.params.speed.label, tenBit: d.params.tenBit,
                videoKbps: vKbps, audioSummary: d.audio.summary, duration: D, quality: report, sampleQuality: d.sampleTrial?.quality,
                elapsed: Date().timeIntervalSince(started), notes: d.notes, warnings: d.warnings,
                settingsSummary: Self.describe(d), textCheck: textReport ?? d.textCheck, textGuardActive: plan.textGuard.active,
                previewableOnThisMac: EncodePlanner.playsInQuickLook(d.encoder.codec, caps: caps))
            Log.info("done \(outURL.lastPathComponent): \(Fmt.bytes(outBytes)) (\(String(format: "%.1f", result.reduction * 100))% smaller), \(result.settingsSummary), VMAF \(report.map { String(format: "%.2f", $0.vmaf) } ?? "n/a") in \(Int(result.elapsed)) s")
            return result
        } catch {
            cleanup()
            if Task.isCancelled { throw CirrusError.cancelled }
            throw error
        }
    }

    static func describe(_ d: EncodeDecision) -> String {
        var s = "\(d.encoder.rawValue) \(presetName(d.encoder, d.params.speed)), \(d.params.tenBit ? "10" : "8")-bit"
        switch d.rate {
        case .constantQuality(let v): s += ", constant quality \(Int(v))"
        case .twoPass(let k): s += ", \(k) kbps \(EncoderRegistry.encoder(d.encoder).supportsTwoPass ? "two-pass" : "average")"
        }
        if d.params.filmGrain > 0 { s += ", film grain \(d.params.filmGrain)" }
        return s
    }

    /// The encoder's own name for the effort level ("preset 4", "slow").
    public static func presetName(_ e: EncoderID, _ s: EncoderSpeed) -> String {
        switch e {
        case .svtav1: return "preset \(SVTAV1Encoder.preset(s))"
        case .x265: return "preset \(X265Encoder.preset(s))"
        case .x264: return "preset \(X264Encoder.preset(s))"
        case .vp9: return "cpu-used \(VP9Encoder.cpuUsed(s))"
        case .vtHEVC, .vtH264: return "hardware"
        }
    }

    static func fileSize(_ u: URL) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value ?? 0 }

    /// "<name> (compressed).mp4" or "<name> (<label>).mp4", made unique; never the source itself.
    public static func outputURL(for source: URL, in dir: URL, settings: CompressionSettings, label: String? = nil) throws -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let tag = (label ?? "compressed").replacingOccurrences(of: "/", with: "-")
        var candidate = dir.appendingPathComponent("\(stem) (\(tag)).mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) || candidate.standardizedFileURL == source.standardizedFileURL {
            candidate = dir.appendingPathComponent("\(stem) (\(tag) \(n)).mp4"); n += 1
        }
        return candidate
    }
}

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, self)) }
}
