import Foundation
import UniformTypeIdentifiers

/// Expands dropped files and folders (recursively) into the videos to compress,
/// skipping Cirrus's own outputs and originals that already have one.
public enum VideoScanner {
    public enum SkipReason: String, Sendable, Codable {
        case cirrusOutput = "Already compressed by Cirrus"
        case hasCompressedCopy = "A compressed copy already exists next to it"
    }

    public struct Scan: Sendable {
        public var videos: [URL] = []
        public var skipped: [(url: URL, reason: SkipReason)] = []
        public var foldersScanned = 0
    }

    public static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "mts", "m2ts", "ts", "mpg",
                                                      "mpeg", "3gp", "ogv", "mxf", "vob", "f4v", "y4m", "dv", "qt", "hevc", "h264", "ivf"]

    public static func isVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return true }
        if let t = UTType(filenameExtension: ext) { return t.conforms(to: .movie) || t.conforms(to: .video) }
        return false
    }

    /// - Parameter skipExisting: apply the skip rules (off = add everything, e.g. "Add skipped anyway").
    public static func scan(_ urls: [URL], skipExisting: Bool = true) -> Scan {
        var s = Scan()
        var found: [URL] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                s.foldersScanned += 1
                let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let f = e?.nextObject() as? URL {
                    if (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, isVideo(f) { found.append(f) }
                }
            } else if isVideo(u) {
                found.append(u)
            }
        }
        // Stable, human order: folder by folder, names compared like Finder does.
        found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        for f in found {
            guard skipExisting else { s.videos.append(f); continue }
            if CirrusMarker.isMarked(f) || CirrusMarker.hasOutputName(f) { s.skipped.append((f, .cirrusOutput)) }
            else if CirrusMarker.existingOutput(for: f) != nil { s.skipped.append((f, .hasCompressedCopy)) }
            else { s.videos.append(f) }
        }
        return s
    }
}
