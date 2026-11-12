import Foundation

/// Runs FFmpeg with machine-readable progress (`-progress pipe:1`) and reports
/// the fraction of `duration` processed plus encode speed.
public struct FFmpegRun: Sendable {
    let tools: ToolPaths
    public init(tools: ToolPaths) { self.tools = tools }

    public struct Tick: Sendable {
        public var fraction: Double      // 0…1 of the input duration
        public var speed: Double?        // × realtime
        public var fps: Double?
        public var outBytes: Int64?
    }

    /// `arguments` must not include global flags; they are added here.
    @discardableResult
    public func run(_ arguments: [String], duration: Double, onTick: (@Sendable (Tick) -> Void)? = nil) async throws -> ProcessResult {
        let args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"] + arguments
        final class Acc: @unchecked Sendable { var t = Tick(fraction: 0) }
        let acc = Acc()
        return try await ProcessRunner.run(tools.ffmpeg, args, options: { var o = ProcessRunner.Options(); o.collectStdout = false; return o }(),
            onStdoutLine: { line in
                guard let eq = line.firstIndex(of: "=") else { return }
                let key = line[..<eq], value = line[line.index(after: eq)...]
                switch key {
                case "out_time_us", "out_time_ms":   // both are microseconds in practice
                    if let us = Double(value), duration > 0 { acc.t.fraction = min(1, max(0, us / 1_000_000 / duration)) }
                case "speed": acc.t.speed = Double(value.replacingOccurrences(of: "x", with: "").trimmingCharacters(in: .whitespaces))
                case "fps": acc.t.fps = Double(value)
                case "total_size": acc.t.outBytes = Int64(value)
                case "progress":
                    if value == "end" { acc.t.fraction = 1 }
                    onTick?(acc.t)
                default: break
                }
            })
    }
}
