import Foundation

/// Everything the engine needs to know about a source file.
public struct MediaInfo: Sendable, Codable, Equatable {
    public var url: URL
    public var fileSize: Int64
    public var duration: Double            // seconds
    public var containerFormat: String
    public var overallBitrate: Int?        // bits/s
    public var video: VideoStreamInfo
    public var audio: [AudioStreamInfo]
    public var subtitleCount: Int
    public var hasChapters: Bool

    /// Display dimensions after rotation and sample-aspect-ratio correction.
    public var displaySize: PixelSize { video.displaySize }
}

public struct PixelSize: Sendable, Codable, Hashable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    public init(_ w: Int, _ h: Int) { width = w; height = h }
    public var pixels: Int { width * height }
    public var shortSide: Int { min(width, height) }
    public var longSide: Int { max(width, height) }
    public var isPortrait: Bool { height > width }
    public var description: String { "\(width) × \(height)" }
}

public enum DynamicRange: String, Sendable, Codable {
    case sdr, hdr10 = "HDR10 (PQ)", hlg = "HLG", dolbyVision = "Dolby Vision"
    public var isHDR: Bool { self != .sdr }
}

public struct VideoStreamInfo: Sendable, Codable, Equatable {
    public var index: Int
    public var codec: String               // ffprobe codec_name
    public var profile: String?
    public var codedSize: PixelSize
    public var sampleAspectRatio: Double   // 1.0 for square pixels
    public var rotation: Int               // degrees, as displayed (0/90/180/270)
    public var frameRate: Double           // average fps
    public var nominalFrameRate: Double    // r_frame_rate
    public var isVariableFrameRate: Bool
    public var frameCount: Int?
    public var pixelFormat: String
    public var bitDepth: Int
    public var chromaSubsampling: String   // "4:2:0", "4:2:2", "4:4:4"
    public var colorPrimaries: String?
    public var colorTransfer: String?
    public var colorSpace: String?
    public var colorRange: String?
    public var dynamicRange: DynamicRange
    public var isInterlaced: Bool
    public var bitrate: Int?               // bits/s (estimated if container doesn't say)

    public var displaySize: PixelSize {
        var w = Double(codedSize.width) * (sampleAspectRatio > 0 ? sampleAspectRatio : 1)
        var h = Double(codedSize.height)
        if rotation % 180 != 0 { swap(&w, &h) }
        return PixelSize(Int(w.rounded()), Int(h.rounded()))
    }
    public var aspectRatio: Double { Double(displaySize.width) / Double(max(1, displaySize.height)) }

    /// Friendly codec name for the UI.
    public var codecDisplayName: String { CodecNames.video[codec] ?? codec.uppercased() }
}

public struct AudioStreamInfo: Sendable, Codable, Equatable {
    public var index: Int
    public var codec: String
    public var channels: Int
    public var channelLayout: String?
    public var sampleRate: Int
    public var bitrate: Int?               // bits/s
    public var language: String?
    public var isLossless: Bool { ["flac", "alac", "truehd", "mlp"].contains(codec) || codec.hasPrefix("pcm_") }
    public var codecDisplayName: String { CodecNames.audio[codec] ?? codec.uppercased() }
}

enum CodecNames {
    static let video = ["h264": "H.264", "hevc": "HEVC", "av1": "AV1", "vp9": "VP9", "vp8": "VP8", "prores": "ProRes",
                        "mpeg4": "MPEG-4", "mpeg2video": "MPEG-2", "dnxhd": "DNxHD", "mjpeg": "Motion JPEG", "ffv1": "FFV1"]
    static let audio = ["aac": "AAC", "opus": "Opus", "mp3": "MP3", "ac3": "Dolby Digital", "eac3": "Dolby Digital Plus",
                        "flac": "FLAC", "alac": "Apple Lossless", "vorbis": "Vorbis", "pcm_s16le": "PCM", "pcm_s24le": "PCM"]
}
