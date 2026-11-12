import Foundation
@testable import CirrusCore

// Minimal, dependency-free unit tests for the engine's pure logic.
// Run: swift run cirrus-tests
var failures = 0, passes = 0
func check(_ cond: @autoclosure () -> Bool, _ name: String, file: String = #file, line: Int = #line) {
    if cond() { passes += 1 } else { failures += 1; print("✗ \(name)  (\(URL(fileURLWithPath: file).lastPathComponent):\(line))") }
}

// MARK: resolution
check(OutputResolution.fhd1080.resolve(source: PixelSize(3840, 2160)) == PixelSize(1920, 1080), "4K → 1080p")
check(OutputResolution.fhd1080.resolve(source: PixelSize(1440, 1080)) == PixelSize(1440, 1080), "4:3 stays")
check(OutputResolution.hd720.resolve(source: PixelSize(1440, 1080)) == PixelSize(960, 720), "4:3 → 720p")
check(OutputResolution.fhd1080.resolve(source: PixelSize(3840, 1608)) == PixelSize(1920, 804), "scope → 1080p box")
check(OutputResolution.fhd1080.resolve(source: PixelSize(2160, 3840)) == PixelSize(1080, 1920), "portrait oriented")
check(OutputResolution.uhd2160.resolve(source: PixelSize(1280, 720)) == PixelSize(1280, 720), "never upscales")
let odd = OutputResolution.sd480.resolve(source: PixelSize(1918, 1080))
check(odd.width % 2 == 0 && odd.height % 2 == 0, "even dimensions")
check(OutputResolution.stepDown(from: PixelSize(1920, 1080)) == PixelSize(1280, 720), "step down 1080→720")
check(OutputResolution.stepDown(from: PixelSize(640, 360)) == nil, "no step below 360p")

// MARK: planner
let caps = FFmpegCapabilities(version: "test", encoders: ["libsvtav1", "libx265", "libx264", "hevc_videotoolbox", "h264_videotoolbox", "libopus", "aac_at", "aac"], filters: ["libvmaf"])
func media(duration: Double = 600, size: Int64 = 1_200_000_000, w: Int = 3840, h: Int = 2160, audio: AudioStreamInfo? = nil, hdr: Bool = false) -> MediaInfo {
    let v = VideoStreamInfo(index: 0, codec: "h264", profile: "High", codedSize: PixelSize(w, h), sampleAspectRatio: 1, rotation: 0,
                            frameRate: 30, nominalFrameRate: 30, isVariableFrameRate: false, frameCount: nil, pixelFormat: "yuv420p",
                            bitDepth: 8, chromaSubsampling: "4:2:0", colorPrimaries: "bt709", colorTransfer: hdr ? "smpte2084" : "bt709",
                            colorSpace: "bt709", colorRange: "tv", dynamicRange: hdr ? .hdr10 : .sdr, isInterlaced: false, bitrate: 15_000_000)
    let a = audio ?? AudioStreamInfo(index: 1, codec: "aac", channels: 2, channelLayout: "stereo", sampleRate: 48000, bitrate: 320_000, language: nil)
    return MediaInfo(url: URL(fileURLWithPath: "/tmp/x.mp4"), fileSize: size, duration: duration, containerFormat: "mp4",
                     overallBitrate: 16_000_000, video: v, audio: [a], subtitleCount: 0, hasChapters: false)
}
let analysis = ContentAnalysis(spatialInfo: 12, temporalInfo: 3, staticFraction: 0.6, flatFraction: 0.3, gradientFraction: 0.2, noiseSigma: 1,
                               hardEdgeRatio: 0.1, colourDiversity: 30, darkFraction: 0.1, cutsPerMinute: 2, kind: .liveAction, confidence: 0.8)
func plan(_ s: CompressionSettings, _ m: MediaInfo = media(), mono: Bool = false) throws -> EncodePlan {
    try EncodePlanner.plan(media: m, analysis: analysis, settings: s, caps: caps, effectivelyMono: mono)
}

do {
    var s = CompressionSettings(); s.resolution = .fhd1080; s.goal = .targetSize(bytes: 150_000_000); s.previewableOnThisMac = false
    let p = try plan(s)
    check(p.encoder == .svtav1, "smallest-file → SVT-AV1")
    check(p.outputSize == PixelSize(1920, 1080), "target plan resolution")
    if case .targetSize(_, let kbps) = p.rate { check(kbps > 1700 && kbps < 1950, "150 MB / 10 min → ~1.8 Mbps video (got \(kbps))") }
    else { check(false, "target-size strategy") }
    check(p.audio.codec == .opus, "AV1 pairs with Opus")
} catch { check(false, "target plan threw \(error)") }

do { var s = CompressionSettings(); s.goal = .targetSize(bytes: 2_000_000); _ = try plan(s); check(false, "impossible target must throw") }
catch { check(error.localizedDescription.contains("Try at least"), "impossible target explains itself") }

do {
    var s = CompressionSettings(); s.priority = .playsEverywhere
    let p = try plan(s)
    check(p.encoder == .x264 && !p.params.tenBit && p.audio.codec == .aac, "compatibility → H.264 8-bit + AAC")
    s.priority = .appleDevices
    let apple = try plan(s); check(apple.encoder == .x265, "Apple devices → x265")
    s.priority = .fastest
    let fast = try plan(s); check(fast.encoder == .vtHEVC, "fastest → VideoToolbox HEVC")
    s.priority = .playsEverywhere
    let h = try plan(s, media(hdr: true))
    check(h.codec == .hevc && h.params.tenBit, "HDR never goes to H.264")
} catch { check(false, "priority plans threw \(error)") }

let mp3 = media(audio: AudioStreamInfo(index: 1, codec: "mp3", channels: 2, channelLayout: "stereo", sampleRate: 44100, bitrate: 96_000, language: nil))
check(AudioPlanner.plan(media: mp3, quality: .high, codecChoice: .automatic, videoCodec: .hevc, preferCompatibility: true,
                        effectivelyMono: false, budgetPressure: 0, caps: caps).bitrateKbps <= 96, "audio never exceeds lossy source")
let aac128 = media(audio: AudioStreamInfo(index: 1, codec: "aac", channels: 2, channelLayout: "stereo", sampleRate: 48000, bitrate: 128_000, language: nil))
check(AudioPlanner.plan(media: aac128, quality: .automatic, codecChoice: .automatic, videoCodec: .hevc, preferCompatibility: true,
                        effectivelyMono: false, budgetPressure: 0, caps: caps).codec == .copy, "efficient AAC is passed through")
let mono = AudioPlanner.plan(media: media(), quality: .standard, codecChoice: .opus, videoCodec: .av1, preferCompatibility: false,
                             effectivelyMono: true, budgetPressure: 0, caps: caps)
check(mono.channels == 1 && mono.downmixToMono, "dual-mono stored as mono")

check(SVTAV1Encoder().qualityScale.better(30, by: 4) == 26, "CRF scale: better = lower")
check(VideoToolboxEncoder(codec: .hevc).qualityScale.better(60, by: 4) == 64, "VT scale: better = higher")

// MARK: classifier
var a = ContentAnalysis(spatialInfo: 15, temporalInfo: 0.3, staticFraction: 1, flatFraction: 0.74, gradientFraction: 0.02, noiseSigma: 0.8,
                        hardEdgeRatio: 0.2, colourDiversity: 17, darkFraction: 0.1, cutsPerMinute: 0, twoToneFraction: 0.19,
                        textureFraction: 0.02, frozenFraction: 1, edgeDensity: 0.1, kind: .general, confidence: 0)
ContentClassifier.classify(&a); check(a.kind == .screenRecording, "screen capture classified")
a.twoToneFraction = 0.04; a.edgeDensity = 0.05; a.flatFraction = 0.85
ContentClassifier.classify(&a); check(a.kind == .talkingHeadAnimation && a.isSynthetic, "animation classified")
a.flatFraction = 0.0; a.textureFraction = 0.7; a.noiseSigma = 2.9; a.staticFraction = 0.3; a.frozenFraction = 0.05; a.temporalInfo = 8
ContentClassifier.classify(&a); check(a.kind == .liveAction && a.isGrainy, "grainy live action classified")

// MARK: Finder / Quick Look compatibility
do {
    let s = CompressionSettings()                                    // previewable by default
    let p = try plan(s)
    check(p.encoder == .x265 && p.previewableOnThisMac, "no AV1 decoder → previewable default uses HEVC")
    check(p.audio.codec != .opus, "previewable output avoids Opus")
    check(p.notes.contains { $0.contains("Quick Look") }, "explains why HEVC was chosen")
    var m3 = caps; m3.systemDecodesAV1 = true
    let q = try EncodePlanner.plan(media: media(), analysis: analysis, settings: s, caps: m3, effectivelyMono: false)
    check(q.encoder == .svtav1 && q.previewableOnThisMac, "AV1 decoder → AV1 stays previewable")
    var forced = s; forced.advanced.encoder = .svtav1
    let f = try plan(forced)
    check(!f.previewableOnThisMac && f.warnings.contains { $0.contains("Quick Look") }, "forced AV1 warns it won't preview")
} catch { check(false, "preview plans threw \(error)") }

// MARK: text guard
let slides = TextAnalysis(sampledFrames: 8, framesWithText: 8, totalCharacters: 900, smallestLinePx: 20, medianLinePx: 40,
                          moments: [TextMoment(time: 12, characters: 200, smallestLinePx: 20)], sourceShortSide: 1080)
let noText = TextAnalysis(sampledFrames: 8, framesWithText: 1, totalCharacters: 12, smallestLinePx: 30, medianLinePx: 30, moments: [], sourceShortSide: 1080)
check(slides.hasText && !noText.hasText, "text presence threshold")
check(abs(slides.smallestLine(at: PixelSize(1280, 720)) - 13.33) < 0.1, "text height scales with resolution")
check(TextLegibility.minimumShortSide(for: slides) == 810, "smallest readable short side")
do {
    let m = media(w: 1920, h: 1080)
    var s = CompressionSettings(); s.resolution = .hd720
    let p = try EncodePlanner.plan(media: m, analysis: analysis, settings: s, caps: caps, effectivelyMono: false, text: slides)
    check(p.textGuard.active && p.textGuard.automatic, "guard turns on automatically with text")
    check(p.textGuard.suggestedResolution == .fhd1080, "suggests a resolution that keeps text readable")
    check(p.warnings.contains { $0.contains("hard to read") }, "warns about small text at 720p")
    check(p.params.filmGrain == 0 && p.params.textGuard, "guard disables grain synthesis")
    if case .searchQuality(let t, _) = p.rate { check(t == 94, "guard raises VMAF target by one") } else { check(false, "search strategy") }
    s.textGuard = .off
    let off = try EncodePlanner.plan(media: m, analysis: analysis, settings: s, caps: caps, effectivelyMono: false, text: slides)
    check(!off.textGuard.active && !off.textGuard.moments.isEmpty, "guard off still checks text on the result")
    s.textGuard = .automatic
    let none = try EncodePlanner.plan(media: m, analysis: analysis, settings: s, caps: caps, effectivelyMono: false, text: noText)
    check(!none.textGuard.active, "automatic guard stays off without text")
} catch { check(false, "text plans threw \(error)") }
check(SVTAV1Encoder().arguments(VideoEncodeParameters(speed: .best, tenBit: true, profile: .talkingHeadAnimation, synthetic: true, textGuard: true,
      filmGrain: 0, keyframeInterval: 300, frameRate: 30, dynamicRange: .sdr), rate: .quality(40), pass: .single, threads: nil)
      .joined(separator: " ").contains("scm=1"), "slides with text use AV1 screen-content tools")
check(OCR.accuracy(reference: "entropy", candidate: "entropy") == 1, "OCR accuracy identical")
check(abs(OCR.accuracy(reference: "abcdefghij", candidate: "abcdefghxj") - 0.9) < 1e-9, "OCR accuracy one substitution")
check(OCR.accuracy(reference: "abc", candidate: "") == 0, "OCR accuracy empty")

// MARK: settings decoding (older saved settings lack newer keys)
do {
    let old = #"{"resolution":{"fhd1080":{}},"goal":{"quality":{"_0":2}},"audio":"Automatic","priority":"Smallest File","depth":"Smart","measureQuality":true,"advanced":{"allowLowerResolution":true,"keepAllAudioTracks":false,"extraEncoderParams":"","tenBit":"Automatic","preferHardware":false,"audioCodec":"Automatic"}}"#
    let s = try JSONDecoder().decode(CompressionSettings.self, from: Data(old.utf8))
    check(s.resolution == .fhd1080 && s.previewableOnThisMac && s.textGuard == .automatic && s.minimumSavings == 0.10, "old settings decode with new defaults")
} catch { check(false, "settings decoding threw \(error)") }

// MARK: folder scanning & output detection
do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cirrus-scan-\(UUID().uuidString)")
    let sub = root.appendingPathComponent("Week 1/Day 2")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    for f in ["a.mov", "Week 1/b.mp4", "Week 1/b (compressed).mp4", "Week 1/Day 2/c.mkv", "Week 1/Day 2/notes.pdf", "Week 1/Day 2/d.mp4", ".hidden.mp4"] {
        FileManager.default.createFile(atPath: root.appendingPathComponent(f).path, contents: Data([0]))
    }
    CirrusMarker.mark(sub.appendingPathComponent("d.mp4"), summary: "test")
    let scan = VideoScanner.scan([root])
    let names = Set(scan.videos.map(\.lastPathComponent))
    check(names == ["a.mov", "c.mkv"], "scan finds videos in subfolders, skipping outputs (got \(names))")
    check(scan.skipped.count == 3, "skips: marked output, named output, original with a copy")
    check(scan.skipped.contains { $0.url.lastPathComponent == "b.mp4" && $0.reason == .hasCompressedCopy }, "original with compressed copy skipped")
    check(VideoScanner.scan([root], skipExisting: false).videos.count == 5, "add-anyway includes everything")
    try? FileManager.default.removeItem(at: root)
} catch { check(false, "scan threw \(error)") }
check(CirrusMarker.hasOutputName(URL(fileURLWithPath: "/x/Talk (compressed 3).mp4")), "numbered output name recognised")
check(!CirrusMarker.hasOutputName(URL(fileURLWithPath: "/x/compressed talk.mp4")), "ordinary name not mistaken for output")

// MARK: version output names
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cirrus-names-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let src = dir.appendingPathComponent("Talk.mov")
    let a = try CompressionEngine.outputURL(for: src, in: dir, settings: CompressionSettings(), label: "AV1, Balanced")
    check(a.lastPathComponent == "Talk (AV1, Balanced).mp4", "version output named after its settings")
    FileManager.default.createFile(atPath: a.path, contents: Data([0]))
    let b = try CompressionEngine.outputURL(for: src, in: dir, settings: CompressionSettings(), label: "AV1, Balanced")
    check(b.lastPathComponent == "Talk (AV1, Balanced 2).mp4", "version names never overwrite")
    check((try? OriginalReplacer.restore(original: src, from: dir.appendingPathComponent("gone.mov"), compressed: a)) == nil,
          "restore refuses when the original is no longer in the Trash")
    try? FileManager.default.removeItem(at: dir)
} catch { check(false, "names threw \(error)") }

// MARK: estimates
check(SizeEstimator.levelFactor(.maximum, synthetic: false) > SizeEstimator.levelFactor(.high, synthetic: false), "level factors ordered")
check(SizeEstimator.codecFactor(.x265, synthetic: true) > SizeEstimator.codecFactor(.x265, synthetic: false), "HEVC gap larger on synthetic")
check(abs(SizeEstimator.resolutionFactor(from: PixelSize(1920, 1080), to: PixelSize(1280, 720)) - 0.544) < 0.01, "resolution factor")

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
