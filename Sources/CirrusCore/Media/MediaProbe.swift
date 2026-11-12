import Foundation

/// Reads container/stream metadata with FFprobe (JSON output) and detects
/// variable frame rate by sampling packet timestamps.
public struct MediaProbe: Sendable {
    let tools: ToolPaths
    public init(tools: ToolPaths) { self.tools = tools }

    public func probe(_ url: URL) async throws -> MediaInfo {
        let r = try await ProcessRunner.run(tools.ffprobe, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-show_chapters", url.path,
        ], options: { var o = ProcessRunner.Options(); o.allowFailure = true; return o }())
        guard r.status == 0, let root = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any] else {
            throw CirrusError.unreadableInput(CirrusError.summarise(r.stderr))
        }
        let streams = root["streams"] as? [[String: Any]] ?? []
        let format = root["format"] as? [String: Any] ?? [:]
        // Ignore cover art / attached pictures masquerading as video streams.
        guard let vs = streams.first(where: {
            ($0["codec_type"] as? String) == "video" && ((($0["disposition"] as? [String: Any])?["attached_pic"] as? Int) ?? 0) == 0
        }) else { throw CirrusError.noVideoStream }

        let fileSize = Int64(str(format["size"])) ?? ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        var duration = Double(str(format["duration"])) ?? Double(str(vs["duration"])) ?? 0

        var video = parseVideo(vs)
        if duration <= 0, let n = video.frameCount, video.frameRate > 0 { duration = Double(n) / video.frameRate }

        // VFR: r_frame_rate vs avg_frame_rate disagreement is a hint; confirm with timestamps.
        if abs(video.nominalFrameRate - video.frameRate) / max(video.frameRate, 1) > 0.02 {
            video.isVariableFrameRate = (try? await detectVFR(url, streamIndex: video.index)) ?? true
        }
        let audio = streams.filter { ($0["codec_type"] as? String) == "audio" }.map(parseAudio)
        let overall = Int(str(format["bit_rate"]))
        if video.bitrate == nil, let o = overall {
            let audioBits = audio.reduce(0) { $0 + ($1.bitrate ?? 128_000) }
            video.bitrate = max(0, o - audioBits)
        }
        return MediaInfo(url: url, fileSize: fileSize, duration: duration,
                         containerFormat: (format["format_name"] as? String) ?? "",
                         overallBitrate: overall, video: video, audio: audio,
                         subtitleCount: streams.filter { ($0["codec_type"] as? String) == "subtitle" }.count,
                         hasChapters: !((root["chapters"] as? [Any]) ?? []).isEmpty)
    }

    private func parseVideo(_ s: [String: Any]) -> VideoStreamInfo {
        let w = s["width"] as? Int ?? 0, h = s["height"] as? Int ?? 0
        let pix = s["pix_fmt"] as? String ?? "yuv420p"
        let trc = s["color_transfer"] as? String
        var rotation = 0
        if let side = s["side_data_list"] as? [[String: Any]] {
            for sd in side { if let r = sd["rotation"] as? Int { rotation = r } else if let r = sd["rotation"] as? Double { rotation = Int(r) } }
        }
        if let tags = s["tags"] as? [String: Any], let r = Int(str(tags["rotate"])) { rotation = r }
        rotation = ((rotation % 360) + 360) % 360

        var dr: DynamicRange = .sdr
        if trc == "smpte2084" { dr = .hdr10 } else if trc == "arib-std-b67" { dr = .hlg }
        if let side = s["side_data_list"] as? [[String: Any]],
           side.contains(where: { ($0["side_data_type"] as? String)?.contains("DOVI") ?? false }) { dr = .dolbyVision }

        let fieldOrder = s["field_order"] as? String ?? "progressive"
        let avg = rate(s["avg_frame_rate"]), nominal = rate(s["r_frame_rate"])
        return VideoStreamInfo(
            index: s["index"] as? Int ?? 0, codec: s["codec_name"] as? String ?? "unknown", profile: s["profile"] as? String,
            codedSize: PixelSize(w, h), sampleAspectRatio: ratio(s["sample_aspect_ratio"]) ?? 1, rotation: rotation,
            frameRate: avg > 0 ? avg : nominal, nominalFrameRate: nominal, isVariableFrameRate: false,
            frameCount: Int(str(s["nb_frames"])), pixelFormat: pix, bitDepth: Self.bitDepth(pix),
            chromaSubsampling: Self.chroma(pix), colorPrimaries: s["color_primaries"] as? String, colorTransfer: trc,
            colorSpace: s["color_space"] as? String, colorRange: s["color_range"] as? String, dynamicRange: dr,
            isInterlaced: !["progressive", "unknown"].contains(fieldOrder), bitrate: Int(str(s["bit_rate"])))
    }

    private func parseAudio(_ s: [String: Any]) -> AudioStreamInfo {
        AudioStreamInfo(index: s["index"] as? Int ?? 0, codec: s["codec_name"] as? String ?? "unknown",
                        channels: s["channels"] as? Int ?? 2, channelLayout: s["channel_layout"] as? String,
                        sampleRate: Int(str(s["sample_rate"])) ?? 48000, bitrate: Int(str(s["bit_rate"])),
                        language: (s["tags"] as? [String: Any])?["language"] as? String)
    }

    /// Look at the first ~600 packet durations; > 3 % spread ⇒ VFR.
    func detectVFR(_ url: URL, streamIndex: Int) async throws -> Bool {
        let r = try await ProcessRunner.run(tools.ffprobe, [
            "-v", "error", "-select_streams", "\(streamIndex)", "-read_intervals", "%+20",
            "-show_entries", "packet=pts_time", "-of", "csv=p=0", url.path])
        let pts = r.stdoutString.split(separator: "\n")
            .compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: " ,\r\t"))) }
            .sorted()
        guard pts.count > 10 else { return false }
        let deltas = zip(pts.dropFirst(), pts).map { $0 - $1 }.filter { $0 > 0 }
        guard let mn = deltas.min(), let mx = deltas.max(), mn > 0 else { return false }
        return (mx - mn) / mn > 0.03
    }

    static func bitDepth(_ pix: String) -> Int {
        if pix.contains("12") { return 12 }
        if pix.contains("10") || pix.hasPrefix("p010") { return 10 }
        if pix.contains("16") { return 16 }
        return 8
    }
    static func chroma(_ pix: String) -> String {
        if pix.contains("444") || pix.hasPrefix("rgb") || pix.hasPrefix("gbr") { return "4:4:4" }
        if pix.contains("422") { return "4:2:2" }
        return "4:2:0"
    }
}

private func str(_ v: Any?) -> String {
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}
private func rate(_ v: Any?) -> Double { ratio(v, separator: "/") ?? 0 }
private func ratio(_ v: Any?, separator: Character = ":") -> Double? {
    let parts = str(v).split(separator: separator)
    guard parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b != 0, a != 0 else { return nil }
    return a / b
}
