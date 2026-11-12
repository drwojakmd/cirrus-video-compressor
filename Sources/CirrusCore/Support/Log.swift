import Foundation
import os

/// Unified logging: everything goes to the macOS unified log (Console.app,
/// subsystem `app.cirrusvideo.compressor`) and to a rolling plain-text log in
/// ~/Library/Logs/Cirrus Video Compressor/ that users can attach to bug reports.
public enum Log {
    public static let subsystem = "app.cirrusvideo.compressor"

    private static let engine = Logger(subsystem: subsystem, category: "engine")
    private static let queue = DispatchQueue(label: "cirrus.log.file")
    private static let fileHandle: FileHandle? = {
        let fm = FileManager.default
        guard let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let dir = lib.appendingPathComponent("Logs/Cirrus Video Compressor", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("engine.log")
        // Roll the log at 5 MB so it never grows without bound.
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > 5_000_000 {
            let old = dir.appendingPathComponent("engine.previous.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()

    /// Mirror log lines to stderr (the CLI turns this on).
    nonisolated(unsafe) public static var echoToStderr = false

    public static var logFileURL: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Cirrus Video Compressor/engine.log")
    }

    /// Block until all queued log lines are written (call before exiting).
    public static func flush() { queue.sync {} }

    public static func info(_ message: @autoclosure () -> String) { write("INFO", message()) }
    public static func debug(_ message: @autoclosure () -> String) { write("DEBUG", message()) }
    public static func warning(_ message: @autoclosure () -> String) { write("WARN", message()) }
    public static func error(_ message: @autoclosure () -> String) { write("ERROR", message()) }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func write(_ level: String, _ message: String) {
        switch level {
        case "ERROR": engine.error("\(message, privacy: .public)")
        case "WARN": engine.warning("\(message, privacy: .public)")
        case "DEBUG": engine.debug("\(message, privacy: .public)")
        default: engine.info("\(message, privacy: .public)")
        }
        let line = "\(stamp.string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            if let d = line.data(using: .utf8) { fileHandle?.write(d) }
            if echoToStderr { FileHandle.standardError.write(line.data(using: .utf8)!) }
        }
    }
}
