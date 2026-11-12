import Foundation
import Darwin

/// Marks files Cirrus produced (an extended attribute), so re-adding a folder
/// skips them even after they have taken the original's name.
public enum CirrusMarker {
    static let name = "app.cirrusvideo.compressed"

    public static func mark(_ url: URL, summary: String) {
        let data = Array(summary.utf8)
        _ = url.withUnsafeFileSystemRepresentation { p in
            p.map { setxattr($0, name, data, data.count, 0, 0) } ?? -1
        }
    }

    public static func isMarked(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { p in
            guard let p else { return false }
            return getxattr(p, name, nil, 0, 0, 0) >= 0
        }
    }

    /// "Name (compressed).mp4" or "Name (compressed 2).mp4".
    public static func hasOutputName(_ url: URL) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.range(of: #" \(compressed( \d+)?\)$"#, options: .regularExpression) != nil
    }

    /// A Cirrus output for `source` already sits next to it.
    public static func existingOutput(for source: URL) -> URL? {
        let dir = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let candidate = dir.appendingPathComponent("\(stem) (compressed).mp4")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}

/// Replaces an original video with its verified compressed copy:
/// the original goes to the Trash, the copy takes its name (with an .mp4
/// extension) and its creation/modification dates and Finder tags.
public struct OriginalReplacer: Sendable {
    let tools: ToolPaths
    public init(tools: ToolPaths) { self.tools = tools }

    public struct Outcome: Sendable, Codable {
        public var finalURL: URL
        public var trashedOriginal: URL?
        public var note: String?
    }

    /// Checks that the compressed file is complete and plays: a video track, an audio track if
    /// expected, and the same duration as the original (±1 % or 0.5 s).
    public func verify(original: MediaInfo, compressed: URL, expectAudio: Bool) async throws {
        let m: MediaInfo
        do { m = try await MediaProbe(tools: tools).probe(compressed) }
        catch { throw CirrusError.invalidSettings("The compressed file couldn’t be read back, so the original was kept.") }
        let tolerance = max(0.5, original.duration * 0.01)
        if original.duration > 0 && abs(m.duration - original.duration) > tolerance {
            throw CirrusError.invalidSettings(String(format: "The compressed file is %.1f s long but the original is %.1f s, so the original was kept.", m.duration, original.duration))
        }
        if expectAudio && m.audio.isEmpty {
            throw CirrusError.invalidSettings("The compressed file has no sound but the original does, so the original was kept.")
        }
    }

    public func replace(original: MediaInfo, compressed: URL, expectAudio: Bool) async throws -> Outcome {
        try await verify(original: original, compressed: compressed, expectAudio: expectAudio)
        let fm = FileManager.default
        let src = original.url
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey, .tagNamesKey]
        let attrs = try? src.resourceValues(forKeys: keys)

        let wanted = src.deletingPathExtension().appendingPathExtension("mp4")
        let nameIsFree = wanted.standardizedFileURL == src.standardizedFileURL || !fm.fileExists(atPath: wanted.path)

        var trashed: NSURL?
        do {
            if let testTrash = ProcessInfo.processInfo.environment["CIRRUS_TEST_TRASH"] {      // integration tests: keep the real Trash clean
                let dest = URL(fileURLWithPath: testTrash).appendingPathComponent("\(UUID().uuidString.prefix(6))-\(src.lastPathComponent)")
                try fm.moveItem(at: src, to: dest); trashed = dest as NSURL
            } else {
                try fm.trashItem(at: src, resultingItemURL: &trashed)
            }
        }
        catch {
            throw CirrusError.invalidSettings("The original couldn’t be moved to the Trash (\(error.localizedDescription)). Both files were kept.")
        }
        var final = compressed
        var note: String? = nil
        if nameIsFree {
            do {
                try fm.moveItem(at: compressed, to: wanted)
                final = wanted
            } catch {
                // put the original back rather than leave the folder without it
                if let t = trashed as URL? { try? fm.moveItem(at: t, to: src) }
                throw CirrusError.invalidSettings("The compressed file couldn’t be renamed (\(error.localizedDescription)). The original was restored.")
            }
        } else {
            note = "\(wanted.lastPathComponent) already exists (a different file), so the compressed copy kept the name \(compressed.lastPathComponent)."
        }
        var values = URLResourceValues()
        values.creationDate = attrs?.creationDate
        values.contentModificationDate = attrs?.contentModificationDate
        var f = final
        try? f.setResourceValues(values)
        if let tags = attrs?.tagNames, !tags.isEmpty { try? (final as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
        return Outcome(finalURL: final, trashedOriginal: trashed as URL?, note: note)
    }
}

extension OriginalReplacer {
    /// Undo a replacement: the compressed copy goes to the Trash and the original comes back
    /// from the Trash to where it was.
    public static func restore(original: URL, from trashed: URL, compressed: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: trashed.path) else {
            throw CirrusError.invalidSettings("The original is no longer in the Trash, so it can’t be restored.")
        }
        if fm.fileExists(atPath: compressed.path) { try fm.trashItem(at: compressed, resultingItemURL: nil) }
        if fm.fileExists(atPath: original.path) {
            throw CirrusError.invalidSettings("A file named \(original.lastPathComponent) is already there, so the original was left in the Trash.")
        }
        try fm.moveItem(at: trashed, to: original)
    }
}
