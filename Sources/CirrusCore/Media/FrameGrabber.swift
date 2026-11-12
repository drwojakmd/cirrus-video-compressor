import Foundation
import CoreGraphics
import ImageIO

/// Decodes single frames with FFmpeg (works for every codec FFmpeg reads,
/// including AV1 on Macs without AV1 hardware) and returns CGImages.
public struct FrameGrabber: Sendable {
    let tools: ToolPaths
    public init(tools: ToolPaths) { self.tools = tools }

    /// - Parameter maxDimension: scale so the long side is at most this (nil = native size).
    /// - Parameter exactSize: scale to exactly this size (used to compare original vs. output 1:1).
    public func frame(_ url: URL, at time: Double, maxDimension: Int? = nil, exactSize: PixelSize? = nil,
                      filters: String? = nil) async throws -> CGImage {
        var vf: [String] = []
        if let filters { vf.append(filters) }
        if let s = exactSize { vf.append("scale=\(s.width):\(s.height):flags=lanczos") }
        else if let m = maxDimension { vf.append("scale='min(\(m),iw)':'min(\(m),ih)':force_original_aspect_ratio=decrease") }
        let r = try await ProcessRunner.run(tools.ffmpeg, [
            "-v", "error", "-nostdin", "-ss", String(format: "%.3f", max(0, time)), "-i", url.path, "-map", "0:v:0",
            "-frames:v", "1"] + (vf.isEmpty ? [] : ["-vf", vf.joined(separator: ",")]) + ["-f", "image2pipe", "-c:v", "png", "-"])
        guard let src = CGImageSourceCreateWithData(r.stdout as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw CirrusError.unreadableInput("Couldn’t decode a frame at \(Fmt.duration(time)).")
        }
        return img
    }
}
