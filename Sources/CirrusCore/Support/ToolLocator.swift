import Foundation
import VideoToolbox
import CoreMedia

/// Paths of the external media tools the engine drives.
public struct ToolPaths: Sendable, Equatable {
    public let ffmpeg: URL
    public let ffprobe: URL
    public init(ffmpeg: URL, ffprobe: URL) { self.ffmpeg = ffmpeg; self.ffprobe = ffprobe }
}

/// What the located FFmpeg build can actually do. Encoder choice is driven by
/// this, never by assumption, so a leaner FFmpeg build degrades gracefully.
public struct FFmpegCapabilities: Sendable, Equatable {
    public var version: String
    public var encoders: Set<String>
    public var filters: Set<String>
    /// This Mac can decode AV1 in hardware, which is what Quick Look, QuickTime,
    /// Photos and Safari need to play AV1 (Apple ships no software AV1 decoder).
    /// True on M3 and later; false on M1/M2 and Intel Macs.
    public var systemDecodesAV1: Bool = false

    public var hasSVTAV1: Bool { encoders.contains("libsvtav1") }
    public var hasX265: Bool { encoders.contains("libx265") }
    public var hasX264: Bool { encoders.contains("libx264") }
    public var hasVP9: Bool { encoders.contains("libvpx-vp9") }
    public var hasVTHEVC: Bool { encoders.contains("hevc_videotoolbox") }
    public var hasVTH264: Bool { encoders.contains("h264_videotoolbox") }
    public var hasOpus: Bool { encoders.contains("libopus") }
    public var hasAudioToolboxAAC: Bool { encoders.contains("aac_at") }
    public var hasVMAF: Bool { filters.contains("libvmaf") }
}

/// Locates FFmpeg/FFprobe without hard-coding install paths.
///
/// Search order:
///   1. `$CIRRUS_TOOLS_DIR` (developer override)
///   2. The app bundle: `Contents/Helpers/` (how the shipped app finds its bundled build)
///   3. The directory containing the running executable (CLI next to tools)
///   4. Every directory on `$PATH`
///   5. Conventional package-manager prefixes, because GUI apps launched from
///      Finder do not inherit the shell's `$PATH` (Homebrew on Apple Silicon and
///      Intel, MacPorts). Only consulted when nothing is bundled.
public enum ToolLocator {
    public static let overrideEnvironmentKey = "CIRRUS_TOOLS_DIR"
    static let conventionalPrefixes = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    public static func candidateDirectories() -> [URL] {
        var dirs: [URL] = []
        let env = ProcessInfo.processInfo.environment
        if let o = env[overrideEnvironmentKey], !o.isEmpty { dirs.append(URL(fileURLWithPath: o)) }
        dirs.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true))
        if let exe = Bundle.main.executableURL { dirs.append(exe.deletingLastPathComponent()) }
        for p in (env["PATH"] ?? "").split(separator: ":") { dirs.append(URL(fileURLWithPath: String(p))) }
        dirs += conventionalPrefixes.map { URL(fileURLWithPath: $0) }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    public static func locate() throws -> ToolPaths {
        let fm = FileManager.default
        for dir in candidateDirectories() {
            let ff = dir.appendingPathComponent("ffmpeg"), fp = dir.appendingPathComponent("ffprobe")
            if fm.isExecutableFile(atPath: ff.path) && fm.isExecutableFile(atPath: fp.path) {
                Log.info("Using media tools in \(dir.path)")
                return ToolPaths(ffmpeg: ff, ffprobe: fp)
            }
        }
        throw CirrusError.toolsMissing("FFmpeg and FFprobe were not found inside the app or on this Mac.")
    }

    /// Query encoders/filters once; cheap (~50 ms).
    public static func capabilities(of tools: ToolPaths) async throws -> FFmpegCapabilities {
        async let enc = ProcessRunner.run(tools.ffmpeg, ["-hide_banner", "-encoders"])
        async let fil = ProcessRunner.run(tools.ffmpeg, ["-hide_banner", "-filters"])
        async let ver = ProcessRunner.run(tools.ffmpeg, ["-hide_banner", "-version"])
        let (e, f, v) = try await (enc, fil, ver)
        func names(_ text: String) -> Set<String> {
            // lines look like: " V....D libx264   libx264 H.264 ..." or " TS psnr  VV->V ..."
            Set(text.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, parts[0].count <= 6, !parts[0].contains("=") else { return nil }
                return String(parts[1])
            })
        }
        let version = v.stdoutString.split(separator: "\n").first.map(String.init) ?? "unknown"
        return FFmpegCapabilities(version: version, encoders: names(e.stdoutString), filters: names(f.stdoutString),
                                  systemDecodesAV1: SystemPlayback.decodesAV1)
    }
}

/// What Apple's own playback stack (AVFoundation: Quick Look, QuickTime, Photos) can decode on this Mac.
public enum SystemPlayback {
    public static let decodesAV1: Bool = {
        if let o = ProcessInfo.processInfo.environment["CIRRUS_ASSUME_AV1_DECODE"] { return o == "1" }   // for tests
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    }()
}
