import Foundation
import CoreGraphics
import Vision

/// One sampled moment that contains text.
public struct TextMoment: Sendable, Codable, Equatable {
    public var time: Double
    public var characters: Int
    /// Height of the smallest text line in this frame, in source display pixels.
    public var smallestLinePx: Double
    /// The text is the same a few frames later (not typing or scrolling), so it can be
    /// compared reliably between the original and an encode.
    public var stable: Bool = true
}

/// What text recognition found in a video: how much text, how small, and where.
public struct TextAnalysis: Sendable, Codable, Equatable {
    public var sampledFrames: Int
    public var framesWithText: Int
    public var totalCharacters: Int
    /// 10th-percentile text line height across all frames with text (source display px).
    public var smallestLinePx: Double
    public var medianLinePx: Double
    /// Frames with text, smallest text first (the ones most at risk).
    public var moments: [TextMoment]
    /// Short side of the source, so line heights can be rescaled to any output size.
    public var sourceShortSide: Int

    public var coverage: Double { sampledFrames > 0 ? Double(framesWithText) / Double(sampledFrames) : 0 }

    /// Enough text, in enough of the video, that its legibility matters:
    /// slides, captions, UI, documents on screen.
    public var hasText: Bool { coverage >= 0.25 && totalCharacters >= 40 }

    /// Line height of the smallest text after scaling to `size`.
    public func smallestLine(at size: PixelSize) -> Double {
        smallestLinePx * Double(size.shortSide) / Double(max(1, sourceShortSide))
    }

    /// Plain description for the UI ("slides or on-screen text in 9 of 12 sampled moments, smallest text ~14 px").
    public var summary: String {
        "Text in \(framesWithText) of \(sampledFrames) sampled moments, smallest about \(Int(smallestLinePx.rounded())) px tall"
    }

    public static let none = TextAnalysis(sampledFrames: 0, framesWithText: 0, totalCharacters: 0, smallestLinePx: 0,
                                          medianLinePx: 0, moments: [], sourceShortSide: 1)
}

/// Text-legibility thresholds (see Docs/ENCODING.md, "Text legibility guard").
public enum TextLegibility {
    /// Below this line height (px, ascender to descender as Vision measures it), small
    /// text in UI fonts becomes hard to read on a normal display regardless of bitrate.
    public static let minimumReadableLinePx: Double = 15
    /// Share of characters that must read identically after compression.
    public static let requiredAccuracy: Double = 0.97
    /// Below this on the finished file, the result carries a warning.
    public static let warnAccuracy: Double = 0.92

    /// Lowest short side at which the smallest text is still readable (nil = any size is fine).
    public static func minimumShortSide(for t: TextAnalysis) -> Int? {
        guard t.smallestLinePx > 0 else { return nil }
        let need = Double(t.sourceShortSide) * minimumReadableLinePx / t.smallestLinePx
        return need >= Double(t.sourceShortSide) ? t.sourceShortSide : Int(need.rounded(.up))
    }
}

/// Finds text in sampled frames using Apple's on-device text recognition (Vision).
public struct TextAnalyzer: Sendable {
    let tools: ToolPaths
    public init(tools: ToolPaths) { self.tools = tools }

    public func analyze(_ media: MediaInfo) async -> TextAnalysis {
        let n = media.duration < 30 ? 5 : media.duration < 300 ? 8 : 12
        let lo = media.duration * 0.05, hi = media.duration * 0.95
        let times = n == 1 || hi <= lo ? [lo] : (0..<n).map { lo + (hi - lo) * Double($0) / Double(n - 1) }
        let grabber = FrameGrabber(tools: tools)
        // Recognise at up to 1920 px on the long side; heights are rescaled to source pixels.
        let disp = media.displaySize
        let maxDim = min(1920, disp.longSide)
        let toSource = Double(disp.longSide) / Double(max(1, maxDim))
        var moments: [TextMoment] = []
        var heights: [Double] = []
        var chars = 0, sampled = 0
        for t in times {
            guard let img = try? await grabber.frame(media.url, at: t, maxDimension: maxDim) else { continue }
            sampled += 1
            let lines = OCR.lines(in: img, accurate: true)
            let count = lines.reduce(0) { $0 + $1.text.count }
            guard count >= 6 else { continue }
            let hs = lines.map { $0.heightPx * toSource }
            heights += hs
            chars += count
            var stable = false
            if let later = try? await grabber.frame(media.url, at: t + 3 / max(1, media.video.frameRate), maxDimension: maxDim) {
                let a = lines.map(\.text).joined().lowercased().filter { !$0.isWhitespace }
                stable = OCR.accuracy(reference: a, candidate: OCR.normalisedText(later)) >= 0.99
            }
            moments.append(TextMoment(time: t, characters: count, smallestLinePx: hs.min() ?? 0, stable: stable))
        }
        let sorted = heights.sorted()
        let p10 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count / 10)]
        let med = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        // Stable moments first (reliable to compare), then the smallest text.
        moments.sort { ($0.stable ? 0 : 1, $0.smallestLinePx, -$0.characters) < ($1.stable ? 0 : 1, $1.smallestLinePx, -$1.characters) }
        let a = TextAnalysis(sampledFrames: sampled, framesWithText: moments.count, totalCharacters: chars, smallestLinePx: p10,
                             medianLinePx: med, moments: moments, sourceShortSide: disp.shortSide)
        Log.info(String(format: "text %@: %d/%d frames, %d chars, smallest %.1f px, median %.1f px → %@", media.url.lastPathComponent,
                        a.framesWithText, a.sampledFrames, a.totalCharacters, a.smallestLinePx, a.medianLinePx, a.hasText ? "text" : "no text"))
        return a
    }
}

/// Thin wrapper around VNRecognizeTextRequest.
public enum OCR {
    public struct Line: Sendable { public var text: String; public var heightPx: Double; public var confidence: Float }

    public static func lines(in image: CGImage, accurate: Bool) -> [Line] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = accurate ? .accurate : .fast
        req.usesLanguageCorrection = false          // judge the pixels, not a dictionary's guess
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([req]) } catch { return [] }
        let h = Double(image.height)
        return (req.results ?? []).compactMap { obs in
            guard let c = obs.topCandidates(1).first, c.confidence >= 0.3 else { return nil }
            let text = c.string.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else { return nil }
            return Line(text: text, heightPx: Double(obs.boundingBox.height) * h, confidence: c.confidence)
        }
    }

    /// Text of an image as one normalised string (lower-case, no whitespace), top to bottom.
    public static func normalisedText(_ image: CGImage) -> String {
        lines(in: image, accurate: true).map(\.text).joined().lowercased().filter { !$0.isWhitespace }
    }

    /// Share of the reference's characters reproduced (1 − character error rate), 0…1.
    public static func accuracy(reference: String, candidate: String) -> Double {
        guard !reference.isEmpty else { return 1 }
        return max(0, 1 - Double(levenshtein(Array(reference), Array(candidate))) / Double(reference.count))
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

/// Result of checking that text survives compression.
public struct TextLegibilityReport: Sendable, Codable, Equatable {
    /// Share of characters that read identically (0…1), weighted by characters per frame,
    /// relative to a near-lossless encode of the same moments when one was measured
    /// (OCR of very small text varies even with imperceptible changes; that noise isn't
    /// compression damage).
    public var accuracy: Double
    /// Raw OCR agreement with the original, and the near-lossless reference level.
    public var raw: Double? = nil
    public var ceiling: Double? = nil
    public var framesChecked: Int
    public var characters: Int
    public var smallestLinePx: Double
    public var summary: String {
        String(format: "%.0f%% of on-screen text reads identically (%d moments checked)", accuracy * 100, framesChecked)
    }
}

/// Compares text in reference vs. encoded frames.
public struct TextLegibilityChecker: Sendable {
    let tools: ToolPaths
    public init(tools: ToolPaths) { self.tools = tools }

    /// - Parameter pairs: (candidate reference frames, encoded frame). Several references (the original
    ///   frames either side of the moment) make the check immune to a one-frame timing offset between the
    ///   original and the encode, which on typing or scrolling text would otherwise look like lost legibility.
    public static func score(_ pairs: [([CGImage], CGImage)], smallestLinePx: Double) -> TextLegibilityReport? {
        var weighted = 0.0, total = 0, frames = 0
        for (refs, e) in pairs {
            let enc = OCR.normalisedText(e)
            var best: (acc: Double, n: Int)? = nil
            for r in refs {
                let ref = OCR.normalisedText(r)
                guard ref.count >= 6 else { continue }
                let acc = OCR.accuracy(reference: ref, candidate: enc)
                if best == nil || acc > best!.acc { best = (acc, ref.count) }
            }
            guard let b = best else { continue }
            weighted += b.acc * Double(b.n); total += b.n; frames += 1
        }
        guard total > 0 else { return nil }
        return TextLegibilityReport(accuracy: weighted / Double(total), framesChecked: frames, characters: total, smallestLinePx: smallestLinePx)
    }

    /// Original frames at `t` and up to two frames either side.
    func referenceFrames(_ source: URL, at t: Double, fps: Double, size: PixelSize, filters: String?) async throws -> [CGImage] {
        let g = FrameGrabber(tools: tools)
        let step = 1 / max(1, fps)
        var out: [CGImage] = []
        for dt in [0, -step, step, -2 * step, 2 * step] where t + dt >= 0 {
            if let img = try? await g.frame(source, at: t + dt, exactSize: size, filters: filters) { out.append(img) }
        }
        return out
    }

    /// Check a finished (or trial) encode against the source at the given moments.
    /// `encodedTime` maps (moment index, source time) to the encoded file's time (clips start at 0).
    public func check(source: URL, sourceFilters: String?, encoded: URL, size: PixelSize, fps: Double, moments: [Double],
                      encodedTime: (Int, Double) -> Double, smallestLinePx: Double) async throws -> TextLegibilityReport? {
        let g = FrameGrabber(tools: tools)
        let filters = sourceFilters.map(Self.withoutScale).flatMap { $0.isEmpty ? nil : $0 }
        var pairs: [([CGImage], CGImage)] = []
        for (i, t) in moments.enumerated() {
            try Task.checkCancellation()
            let refs = try await referenceFrames(source, at: t, fps: fps, size: size, filters: filters)
            let e = try await g.frame(encoded, at: encodedTime(i, t), exactSize: size)
            pairs.append((refs, e))
        }
        return Self.score(pairs, smallestLinePx: smallestLinePx)
    }

    /// FrameGrabber scales with `exactSize`, so drop the plan's own scale/setsar from a filter chain.
    static func withoutScale(_ chain: String) -> String {
        chain.split(separator: ",").map(String.init).filter { !$0.hasPrefix("scale=") && !$0.hasPrefix("setsar") }.joined(separator: ",")
    }
}

extension TextLegibilityReport {
    /// Express `self` relative to a near-lossless reference measurement.
    public func relative(to ceiling: TextLegibilityReport?) -> TextLegibilityReport {
        guard let c = ceiling?.accuracy, c >= 0.5 else { return self }
        var r = self
        r.raw = accuracy; r.ceiling = c
        r.accuracy = min(1, accuracy / c)
        return r
    }
}
