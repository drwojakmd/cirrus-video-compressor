import SwiftUI
import CirrusCore

/// Plain-English explanation of a choice: what it does, what you gain, what you give up.
struct Explanation {
    var summary: String
    var pros: [String]
    var cons: [String]
    var numbers: [String] = []
}

/// The explanations, with figures from the benchmark study on this Mac (Docs/ENCODING.md).
/// `synthetic` selects the measurements for animation, slides and screen content.
enum Explain {
    static func pct(_ factor: Double) -> String {
        factor >= 1 ? String(format: "about %.0f%% larger", (factor - 1) * 100) : String(format: "about %.0f%% smaller", (1 - factor) * 100)
    }
    static func times(_ f: Double) -> String { f >= 1.95 ? String(format: "about %.1f× the size", f) : pct(f) }

    static func quality(_ l: QualityLevel, synthetic: Bool) -> Explanation {
        let f = SizeEstimator.levelFactor(l, synthetic: synthetic)
        let vsBalanced = l == .balanced ? "This is the reference point for the others." : "Files are \(pct(f)) than Balanced on this kind of video."
        switch l {
        case .maximum:
            return Explanation(summary: "Aims for a picture you can’t tell apart from the original, even when you look for differences (VMAF 97).",
                               pros: ["Safe for archiving masters you may re-edit", "No visible softening, even in busy scenes"],
                               cons: ["The largest of the five levels", "Slowest: uses the encoder’s most thorough setting"],
                               numbers: [vsBalanced])
        case .high:
            return Explanation(summary: "Excellent quality: differences only show up if you pause and compare frame by frame (VMAF 95).",
                               pros: ["Good choice for uploads that will be re-encoded again (YouTube, Vimeo)", "Fine detail stays crisp"],
                               cons: ["Noticeably larger than Balanced"], numbers: [vsBalanced])
        case .balanced:
            return Explanation(summary: "Very good quality at a much smaller size (VMAF 93). Most people can’t see a difference at normal viewing.",
                               pros: ["The best trade-off for everyday viewing and sharing", "Recommended for lectures, talking heads and screen recordings"],
                               cons: ["Very fine texture (grass, gravel, film grain) may be slightly simplified"], numbers: [vsBalanced])
        case .aggressive:
            return Explanation(summary: "Small files with good quality (VMAF 90). Busy scenes soften a little.",
                               pros: ["Good for storage-limited archives and previews", "Static content (slides, talking heads) still looks clean"],
                               cons: ["Detail softens in fast or detailed scenes", "Small text can blur unless “Keep text readable” is on"],
                               numbers: [vsBalanced])
        case .maximumCompression:
            return Explanation(summary: "The smallest files (VMAF 85). Some quality loss is visible, especially in motion.",
                               pros: ["Smallest size", "Fine for reference copies or very long recordings"],
                               cons: ["Visible blur and blockiness in busy scenes", "Not a good master copy"], numbers: [vsBalanced])
        }
    }

    static func format(_ p: OutputPriority, synthetic: Bool, previewable: Bool, macDecodesAV1: Bool) -> Explanation {
        let hevc = SizeEstimator.codecFactor(.x265, synthetic: synthetic)
        let h264 = SizeEstimator.codecFactor(.x264, synthetic: synthetic)
        let vt = SizeEstimator.codecFactor(.vtHEVC, synthetic: synthetic)
        let kind = synthetic ? "animation, slides and screen recordings" : "camera footage"
        switch p {
        case .smallestFile:
            if previewable && !macDecodesAV1 {
                return Explanation(summary: "The most efficient format this Mac can preview: HEVC (H.265). Choose “AV1 · Smallest” to use AV1 instead.",
                                   pros: ["Plays in Finder (spacebar), QuickTime, Photos and on every recent iPhone, iPad and Apple TV"],
                                   cons: ["AV1 would be smaller: on \(kind), HEVC is \(times(hevc)) of AV1"],
                                   numbers: ["Measured on this Mac at equal quality (VMAF)"])
            }
            return Explanation(summary: "AV1, the most efficient video format available, with Opus audio.",
                               pros: ["Smallest files: on \(kind), HEVC needs \(times(hevc)) and H.264 \(times(h264)) for the same quality",
                                      "Plays in Chrome, Firefox, Safari on M3 Macs, VLC, IINA, and on YouTube"],
                               cons: macDecodesAV1 ? ["Older Macs (M1/M2, Intel) and older iPhones can’t play it in QuickTime"]
                                   : ["This Mac can’t play AV1 in Finder’s spacebar preview, QuickTime or Photos (that needs an M3 or later)",
                                      "Use VLC or IINA to watch it here"])
        case .appleDevices:
            return Explanation(summary: "HEVC (H.265) with AAC audio: the format Apple devices are built around.",
                               pros: ["Plays in Finder’s preview, QuickTime and Photos on every modern Mac, iPhone, iPad and Apple TV"],
                               cons: ["On \(kind), HEVC is \(times(hevc)) of AV1 at the same quality",
                                      synthetic ? "Encoding is about 2× slower than AV1 on this Mac" : "Encoding is about 2.5× slower than AV1 on this Mac"])
        case .playsEverywhere:
            return Explanation(summary: "H.264 with AAC audio: the most compatible format there is.",
                               pros: ["Plays on practically anything: old PCs, smart TVs, game consoles, any browser or editor"],
                               cons: ["The largest software-encoded files: on \(kind), H.264 is \(times(h264)) of AV1"])
        case .fastest:
            return Explanation(summary: "Uses the Apple Silicon media engine (hardware HEVC), which is many times faster than software encoders.",
                               pros: ["Very fast: about 4–18× quicker than the software encoders on this Mac", "Plays in Finder’s preview and on all Apple devices"],
                               cons: ["Much less efficient: on \(kind), files are \(times(vt)) of AV1 at the same quality"])
        }
    }

    static func depth(_ d: AnalysisDepth) -> Explanation {
        switch d {
        case .quick: return Explanation(summary: "Predicts settings from the content analysis. No test encodes.",
                                        pros: ["Starts compressing straight away"],
                                        cons: ["The quality target can be missed by a few points either way", "Files tend to be larger than Smart for the same look"])
        case .smart: return Explanation(summary: "Encodes about 20 seconds of sample scenes at several settings and measures the quality (VMAF) to pick the smallest file that reaches your quality level.",
                                        pros: ["Hits the quality level reliably", "Usually the smallest file for the look"],
                                        cons: ["Adds about a minute before compression starts"])
        case .bestPossible: return Explanation(summary: "Like Smart, but also compares formats (AV1 and HEVC) and resolutions on the samples and keeps the winner.",
                                               pros: ["The best result Cirrus can find"],
                                               cons: ["Roughly twice the preparation time of Smart"])
        }
    }

    static func resolution(_ r: OutputResolution, from source: PixelSize, out: PixelSize) -> Explanation {
        let f = SizeEstimator.resolutionFactor(from: source, to: out)
        if out == OutputResolution.original.resolve(source: source) {
            return Explanation(summary: "Keeps every pixel of the original (\(source.width) × \(source.height)).",
                               pros: ["Nothing is lost to scaling", "Best for footage people will zoom into or crop"],
                               cons: ["Larger than a reduced resolution at the same quality"])
        }
        return Explanation(summary: "Scales the video down to \(out.width) × \(out.height), keeping its shape.",
                           pros: ["Usually \(pct(f)) than the original resolution at the same quality level",
                                  "On phones, laptops and most TVs the difference is hard to see"],
                           cons: ["Fine detail and small text get smaller and softer", "Can’t be undone: keep the original if you may need full resolution"],
                           numbers: ["Size estimate from how bitrate scales with picture area in the benchmark study"])
    }

    static let textGuard = Explanation(
        summary: "Finds slides, captions and other on-screen text with Apple’s on-device text recognition, then makes sure that text survives compression.",
        pros: ["Text is read back from test encodes; quality goes up only until it reads the same as in the original",
               "Never reduces the resolution below the point where the smallest text stays readable",
               "Turns off film-grain synthesis, and uses AV1’s screen-content tools on slides"],
        cons: ["Can make files larger when text is small or quality is set low (often by nothing at Balanced and above)",
               "Adds about half a minute of checking per video"])

    static func preview(macDecodesAV1: Bool, synthetic: Bool) -> Explanation {
        let hevc = SizeEstimator.codecFactor(.x265, synthetic: synthetic)
        if macDecodesAV1 {
            return Explanation(summary: "This Mac decodes AV1 in hardware, so every file Cirrus makes previews in Finder. This setting only switches audio to AAC.",
                               pros: ["Spacebar preview, QuickTime and Photos all work"], cons: ["Older Macs and iPhones may still not play AV1"])
        }
        return Explanation(summary: "Makes sure Finder’s spacebar preview (Quick Look), QuickTime and Photos can play the file on this Mac. This Mac can’t decode AV1, so HEVC is used instead.",
                           pros: ["Preview and play files instantly without extra apps", "Also plays on iPhones, iPads and Apple TV"],
                           cons: ["Larger files: HEVC is \(times(hevc)) of AV1 on \(synthetic ? "animation, slides and screen recordings" : "camera footage")",
                                  "Slower to encode than AV1"])
    }

    static let minimumSavings = Explanation(
        summary: "Leaves a video alone when compressing it would save less than this. Useful for folders that mix big recordings with files that are already compact.",
        pros: ["Doesn’t spend time re-encoding files that are already efficient", "Avoids a generation of quality loss for little gain"],
        cons: ["Skipped videos keep their original size and format"])

    static let replaceOriginals = Explanation(
        summary: "Each compressed video takes the place of its original: same folder, same name (as .mp4), same dates and Finder tags. Originals go to the Trash.",
        pros: ["Frees the space without leaving duplicates", "Other files and folders are never touched"],
        cons: ["An original is only moved to the Trash after its compressed copy is complete, plays to the same length and is smaller",
               "Empty the Trash only once you’re happy with the results"])
}

/// "What does this mean?" disclosure under a setting.
struct ExplanationView: View {
    var explanation: Explanation
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0))
                    Text(explanation.summary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption).foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Hide details" : "Pros, cons and numbers")
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(explanation.pros, id: \.self) { Bullet(symbol: "checkmark", tint: Brand.good, text: $0) }
                    ForEach(explanation.cons, id: \.self) { Bullet(symbol: "minus", tint: Brand.warn, text: $0) }
                    ForEach(explanation.numbers, id: \.self) { Bullet(symbol: "chart.bar", tint: .secondary, text: $0) }
                }
                .padding(.leading, 14)
                .transition(.opacity)
            }
        }
    }

    struct Bullet: View {
        var symbol: String; var tint: Color; var text: String
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(tint).frame(width: 10)
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
