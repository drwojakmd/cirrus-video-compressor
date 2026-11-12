import Foundation

/// The kinds of footage the engine tunes for. Each maps to a profile with a
/// technically distinct encoder configuration (see `ContentProfile`).
public enum ContentKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case talkingHeadAnimation = "Talking Head / Animation"
    case screenRecording = "Screen Recording"
    case liveAction = "Live Action"
    case general = "General Purpose"
    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .talkingHeadAnimation: return "person.wave.2"
        case .screenRecording: return "macwindow"
        case .liveAction: return "camera"
        case .general: return "film"
        }
    }
}

/// Measured statistics of a video, computed from short frame bursts sampled
/// across its duration at reduced resolution. All values are cheap,
/// classical image statistics — no ML models.
public struct ContentAnalysis: Sendable, Codable, Equatable {
    /// Mean Sobel gradient magnitude of luma (0–255 scale). Spatial complexity.
    public var spatialInfo: Double
    /// Mean absolute frame-to-frame luma difference. Motion / temporal complexity.
    public var temporalInfo: Double
    /// Fraction of pixels effectively unchanged between consecutive frames.
    public var staticFraction: Double
    /// Fraction of 8×8 blocks that are flat (variance < 2): flat-colour art, UI.
    public var flatFraction: Double
    /// Fraction of 8×8 blocks that are smooth-but-not-flat (gentle gradients) — banding risk.
    public var gradientFraction: Double
    /// Estimated noise / grain sigma (8-bit units, Immerkær estimator on non-edge pixels).
    public var noiseSigma: Double
    /// Fraction of edge pixels that are very hard edges (text, UI, outlines).
    public var hardEdgeRatio: Double
    /// Distinct quantised colours per 10k pixels (palette-like content is low).
    public var colourDiversity: Double
    /// Fraction of pixels in deep shadow.
    public var darkFraction: Double
    /// Scene cuts per minute observed in the sampled bursts (rough).
    public var cutsPerMinute: Double
    /// Fraction of 8×8 blocks that are high-contrast and two-toned: text glyphs, UI lines, cartoon outlines.
    public var twoToneFraction: Double = 0
    /// Fraction of 8×8 blocks with mid-level natural texture (skin, foliage, fabric, noise).
    public var textureFraction: Double = 0
    /// Fraction of pixels bit-identical between consecutive frames (truly frozen background).
    public var frozenFraction: Double = 0
    /// Fraction of pixels on an edge.
    public var edgeDensity: Double = 0
    /// Clean computer-generated imagery (animation, graphics, UI) rather than camera footage.
    public var isSynthetic: Bool = false
    /// Times (s) of the most demanding sampled moments (detail + motion), for previews.
    public var demandingMoments: [Double] = []

    public var kind: ContentKind
    /// 0…1, how strongly the measurements support `kind`.
    public var confidence: Double

    /// Single complexity score used to scale rate expectations (≈1 typical).
    public var complexity: Double {
        // spatial detail dominates intra cost; motion dominates inter cost.
        let s = spatialInfo / 18.0, t = temporalInfo / 6.0
        return max(0.05, 0.45 * s + 0.55 * t * (1 - staticFraction * 0.6) + noiseSigma * 0.08)
    }

    public var isGrainy: Bool { noiseSigma >= 2.2 && !isSynthetic }
    /// Smooth gradients or dark scenes: where 10-bit coding visibly reduces banding.
    public var bandingRisk: Bool { gradientFraction > 0.25 || darkFraction > 0.35 }

    /// Human-readable summary for the UI ("Detected: Screen Recording").
    public var summary: String {
        var parts: [String] = []
        parts.append(temporalInfo < 2 ? "Very little motion" : temporalInfo < 6 ? "Moderate motion" : "High motion")
        if staticFraction > 0.75 { parts.append("static background") }
        if isGrainy { parts.append("film grain") }
        if bandingRisk { parts.append("smooth gradients") }
        return parts.joined(separator: " · ")
    }
}

/// Classifies content from its statistics with an explicit, inspectable
/// decision list (calibrated on Benchmarks/clips: synthetic animation, screen
/// capture, Xiph camera sequences and real camera talking-head footage).
public enum ContentClassifier {
    public static func classify(_ a: inout ContentAnalysis) {
        // Synthetic imagery: large flat regions, little natural texture, little sensor noise.
        let synthetic = score([(a.flatFraction, 0.35, 0.65), (1 - a.textureFraction, 0.70, 0.92), (1 - min(a.noiseSigma / 2.5, 1), 0.3, 0.7)])
        a.isSynthetic = synthetic >= 0.6

        // Screen capture: synthetic + dense text/UI line art + almost nothing moves.
        let screen = score([(a.twoToneFraction, 0.03, 0.10), (a.staticFraction, 0.90, 0.99), (a.edgeDensity, 0.06, 0.15)]) * (a.isSynthetic ? 1 : 0.5)
        // Talking head: most of the frame frozen, modest localised motion.
        let talking = score([(a.frozenFraction, 0.45, 0.80), (1 - min(a.temporalInfo / 4, 1), 0.4, 0.85)]) * (a.textureFraction < 0.35 ? 1 : 0.5)

        if screen >= 0.6 {
            a.kind = .screenRecording; a.confidence = screen
        } else if a.isSynthetic {
            a.kind = .talkingHeadAnimation; a.confidence = synthetic           // animation (with or without a talking character)
        } else if talking >= 0.6 {
            a.kind = .talkingHeadAnimation; a.confidence = talking             // camera talking head on a static background
        } else if synthetic <= 0.35 {
            a.kind = .liveAction; a.confidence = 1 - synthetic
        } else {
            a.kind = .general; a.confidence = 0.5
        }
    }

    /// Mean of soft memberships: 0 below lo, 1 above hi, linear between.
    static func score(_ terms: [(Double, Double, Double)]) -> Double {
        terms.map { v, lo, hi in min(1, max(0, (v - lo) / (hi - lo))) }.reduce(0, +) / Double(terms.count)
    }
}
