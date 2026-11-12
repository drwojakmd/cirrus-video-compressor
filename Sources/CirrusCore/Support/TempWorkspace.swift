import Foundation

/// A private scratch directory for one job (samples, pass logs, partial
/// outputs). Removed when the job ends; stale ones from crashed sessions are
/// swept on launch. Nothing here ever touches the user's source file.
public final class TempWorkspace: @unchecked Sendable {
    public let url: URL
    private static let rootName = "CirrusVideoCompressor"

    public static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(rootName, isDirectory: true)
    }

    public init(label: String = "job") throws {
        let dir = Self.root.appendingPathComponent("\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir
    }

    public func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    public func subdirectory(_ name: String) throws -> URL {
        let d = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    public func remove() { try? FileManager.default.removeItem(at: url) }

    deinit { remove() }

    /// Delete workspaces left by a previous run that crashed or was force-quit.
    public static func sweepStale(olderThan age: TimeInterval = 6 * 3600) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items {
            let mod = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(mod) > age { try? fm.removeItem(at: item) }
        }
    }
}

public enum DiskSpace {
    public static func available(at url: URL) -> Int64? {
        let dir = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }
}
