import Foundation
import CirrusCore

/// The one format control the user sees. It names the codec and what it's good for,
/// and maps onto the engine's priority + "previewable on this Mac" settings.
enum FormatChoice: String, CaseIterable, Identifiable {
    case av1, hevc, h264, hardware
    var id: String { rawValue }

    var title: String {
        switch self { case .av1: return "AV1"; case .hevc: return "HEVC"; case .h264: return "H.264"; case .hardware: return "Hardware" }
    }
    var subtitle: String {
        switch self {
        case .av1: return "Smallest"
        case .hevc: return "Previews in Finder"
        case .h264: return "Plays everywhere"
        case .hardware: return "Fastest"
        }
    }
    var label: String { "\(title) · \(subtitle)" }

    static func of(_ s: CompressionSettings, macDecodesAV1: Bool) -> FormatChoice {
        if let e = s.advanced.encoder {
            switch e {
            case .svtav1, .vp9: return .av1
            case .x265: return .hevc
            case .x264: return .h264
            case .vtHEVC, .vtH264: return .hardware
            }
        }
        switch s.priority {
        case .fastest: return .hardware
        case .playsEverywhere: return .h264
        case .appleDevices: return .hevc
        case .smallestFile: return s.previewableOnThisMac && !macDecodesAV1 ? .hevc : .av1
        }
    }

    func apply(to s: inout CompressionSettings, macDecodesAV1: Bool) {
        s.advanced.encoder = nil
        switch self {
        case .av1: s.priority = .smallestFile; s.previewableOnThisMac = macDecodesAV1
        case .hevc: s.priority = .appleDevices; s.previewableOnThisMac = true
        case .h264: s.priority = .playsEverywhere; s.previewableOnThisMac = true
        case .hardware: s.priority = .fastest; s.previewableOnThisMac = true
        }
    }

    /// The engine priority whose explanation describes this choice.
    var priority: OutputPriority {
        switch self { case .av1: return .smallestFile; case .hevc: return .appleDevices; case .h264: return .playsEverywhere; case .hardware: return .fastest }
    }
}

extension CompressionSettings {
    /// Short name for an output version, e.g. "AV1, Balanced, 1080p" (used in file names).
    func versionLabel(macDecodesAV1: Bool) -> String {
        var parts = [FormatChoice.of(self, macDecodesAV1: macDecodesAV1).title]
        switch goal {
        case .quality(let l): parts.append(l.label.replacingOccurrences(of: " Quality", with: ""))
        case .targetSize(let b): parts.append("under \(Fmt.bytes(b))")
        }
        if resolution != .original { parts.append(resolution.label.replacingOccurrences(of: "4K (2160p)", with: "4K")) }
        return parts.joined(separator: ", ")
    }
}
