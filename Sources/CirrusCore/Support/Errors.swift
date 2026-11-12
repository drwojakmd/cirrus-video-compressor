import Foundation

/// Errors surfaced to the user. Every case carries a plain-English description
/// and, where possible, a suggestion — never a raw FFmpeg dump.
public enum CirrusError: LocalizedError, Equatable {
    case toolsMissing(String)
    case unreadableInput(String)
    case noVideoStream
    case encoderUnavailable(String)
    case processFailed(tool: String, status: Int32, detail: String)
    case cancelled
    case outputExists(String)
    case targetUnreachable(String)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case invalidSettings(String)
    /// Compression wouldn't save enough to be worth replacing/keeping (the original is untouched).
    case notWorthIt(String)

    public var errorDescription: String? {
        switch self {
        case .toolsMissing(let s): return "The encoding engine is missing: \(s)"
        case .unreadableInput(let s): return "This file couldn’t be read as a video. \(s)"
        case .noVideoStream: return "This file doesn’t contain a video track."
        case .encoderUnavailable(let s): return "The \(s) encoder isn’t available in this build."
        case .processFailed(let tool, let status, let detail):
            return "\(tool) stopped unexpectedly (code \(status)). \(Self.summarise(detail))"
        case .cancelled: return "Cancelled."
        case .outputExists(let s): return "A file already exists at \(s)."
        case .targetUnreachable(let s): return s
        case .insufficientDiskSpace(let need, let have):
            let f = ByteCountFormatter()
            return "Not enough free disk space: about \(f.string(fromByteCount: need)) needed, \(f.string(fromByteCount: have)) available."
        case .invalidSettings(let s): return s
        case .notWorthIt(let s): return s
        }
    }

    /// Pull the most relevant line out of an FFmpeg error log.
    static func summarise(_ log: String) -> String {
        let lines = log.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let keywords = ["Error", "error", "Invalid", "No such", "not supported", "Unsupported", "failed", "Permission"]
        if let hit = lines.last(where: { l in keywords.contains { l.contains($0) } }) { return hit }
        return lines.last ?? ""
    }
}
