import Foundation

/// Samples short bursts of frames across the video at low resolution and
/// computes `ContentAnalysis`. Typical cost: 1–3 s for any length of video.
public struct ContentAnalyzer: Sendable {
    let tools: ToolPaths
    public var burstLength = 10
    public var analysisWidth = 960

    public init(tools: ToolPaths) { self.tools = tools }

    struct Burst { var w: Int; var h: Int; var frames: [[UInt8]]; var chroma: [UInt8]; var t: Double = 0 }

    public func analyze(_ media: MediaInfo) async throws -> ContentAnalysis {
        let disp = media.displaySize
        // analysis frame: long side ≈ 480, even dimensions
        let scale = Double(analysisWidth) / Double(max(disp.width, disp.height))
        let w = max(16, Int((Double(disp.width) * scale / 2).rounded()) * 2)
        let h = max(16, Int((Double(disp.height) * scale / 2).rounded()) * 2)

        let positions = Self.samplePositions(duration: media.duration, fps: media.video.frameRate, burst: burstLength)
        var bursts: [Burst] = []
        try await withThrowingTaskGroup(of: Burst?.self) { group in
            var it = positions.makeIterator()
            func addNext() { if let p = it.next() { group.addTask { try await self.readBurst(media.url, at: p, w: w, h: h) } } }
            for _ in 0..<4 { addNext() }
            while let b = try await group.next() {
                if let b { bursts.append(b) }
                addNext()
            }
        }
        guard !bursts.isEmpty else { throw CirrusError.unreadableInput("No frames could be decoded for analysis.") }
        var a = Self.measure(bursts, fps: media.video.frameRate)
        ContentClassifier.classify(&a)
        Log.info(String(format: "analysis %@: SI %.1f TI %.2f static %.2f frozen %.2f flat %.2f grad %.2f tex %.2f twoTone %.3f edges %.2f noise %.2f colours %.1f → %@%@ (%.2f)",
                        media.url.lastPathComponent, a.spatialInfo, a.temporalInfo, a.staticFraction, a.frozenFraction, a.flatFraction,
                        a.gradientFraction, a.textureFraction, a.twoToneFraction, a.edgeDensity, a.noiseSigma, a.colourDiversity,
                        a.kind.rawValue, a.isSynthetic ? " [synthetic]" : "", a.confidence))
        return a
    }

    static func samplePositions(duration: Double, fps: Double, burst: Int) -> [Double] {
        let n = duration < 20 ? 4 : min(16, max(6, Int(duration / 20)))
        let burstSecs = Double(burst) / max(fps, 1)
        let usable = max(0, duration - burstSecs - 0.1)
        // skip the first/last 4 % (intros, fades, end cards)
        let lo = usable * 0.04, hi = usable * 0.96
        if n == 1 || hi <= lo { return [lo] }
        return (0..<n).map { lo + (hi - lo) * Double($0) / Double(n - 1) }
    }

    func readBurst(_ url: URL, at t: Double, w: Int, h: Int) async throws -> Burst? {
        let r = try await ProcessRunner.run(tools.ffmpeg, [
            "-v", "error", "-nostdin", "-ss", String(format: "%.3f", t), "-i", url.path,
            "-map", "0:v:0", "-frames:v", "\(burstLength)", "-vf", "scale=\(w):\(h):flags=area,format=yuv420p",
            "-f", "rawvideo", "-",
        ], options: { var o = ProcessRunner.Options(); o.allowFailure = true; return o }())
        let frameBytes = w * h * 3 / 2
        let count = r.stdout.count / frameBytes
        guard count >= 2 else { return nil }
        var frames: [[UInt8]] = []
        var chroma: [UInt8] = []
        r.stdout.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self)
            for i in 0..<count {
                let off = i * frameBytes
                frames.append(Array(base[off..<(off + w * h)]))
                if i == 0 { chroma = Array(base[(off + w * h)..<(off + frameBytes)]) }
            }
        }
        return Burst(w: w, h: h, frames: frames, chroma: chroma, t: t)
    }

    // MARK: - measurements

    static func measure(_ bursts: [Burst], fps: Double) -> ContentAnalysis {
        var si: [Double] = [], ti: [Double] = [], stat: [Double] = [], flat: [Double] = [], grad: [Double] = []
        var noise: [Double] = [], hard: [Double] = [], colours: [Double] = [], dark: [Double] = []
        var twoTone: [Double] = [], texture: [Double] = [], frozen: [Double] = [], edgeDensity: [Double] = []
        var cuts = 0, pairs = 0
        var demand: [(Double, Double)] = []          // (time, complexity) per burst
        for b in bursts {
            let tiStart = ti.count
            let w = b.w, h = b.h
            let f0 = b.frames[0]
            // --- spatial: Sobel, hard edges, noise (Immerkær) on non-edge pixels
            var gsum = 0.0, edges = 0, hardEdges = 0, nsum = 0.0, ncount = 0, darkCount = 0
            for y in 1..<(h - 1) {
                let r0 = (y - 1) * w, r1 = y * w, r2 = (y + 1) * w
                for x in 1..<(w - 1) {
                    let a = Int(f0[r0 + x - 1]), bb = Int(f0[r0 + x]), c = Int(f0[r0 + x + 1])
                    let d = Int(f0[r1 + x - 1]), e = Int(f0[r1 + x]), f = Int(f0[r1 + x + 1])
                    let g = Int(f0[r2 + x - 1]), hh = Int(f0[r2 + x]), i = Int(f0[r2 + x + 1])
                    let gx = (c + 2 * f + i) - (a + 2 * d + g)
                    let gy = (g + 2 * hh + i) - (a + 2 * bb + c)
                    let mag = Double(abs(gx) + abs(gy)) * 0.5
                    gsum += mag
                    if mag > 24 { edges += 1; if mag > 150 { hardEdges += 1 } }
                    else if mag < 12 {
                        // Laplacian-difference mask [1 -2 1; -2 4 -2; 1 -2 1]
                        let l = a - 2 * bb + c - 2 * d + 4 * e - 2 * f + g - 2 * hh + i
                        nsum += Double(abs(l)); ncount += 1
                    }
                    if e < 40 { darkCount += 1 }
                }
            }
            let inner = Double((w - 2) * (h - 2))
            si.append(gsum / inner)
            hard.append(edges > 0 ? Double(hardEdges) / Double(edges) : 0)
            edgeDensity.append(Double(edges) / inner)
            noise.append(ncount > 100 ? sqrt(Double.pi / 2) * nsum / (6 * Double(ncount)) : 0)
            dark.append(Double(darkCount) / inner)

            // --- 8×8 block variance: flat vs. smooth gradient
            // two-tone = high-contrast block made of ~two levels (text glyphs, UI lines, outlines);
            // texture = mid-variance block that isn't two-tone (natural detail: skin, foliage, fabric).
            var flatBlocks = 0, gradBlocks = 0, twoToneBlocks = 0, textureBlocks = 0, blocks = 0
            var by = 0
            while by + 8 <= h {
                var bx = 0
                while bx + 8 <= w {
                    var s = 0, s2 = 0, mn = 255, mx = 0
                    for yy in by..<(by + 8) { let row = yy * w; for xx in bx..<(bx + 8) {
                        let v = Int(f0[row + xx]); s += v; s2 += v * v; mn = min(mn, v); mx = max(mx, v) } }
                    let mean = Double(s) / 64, v = Double(s2) / 64 - mean * mean
                    if v < 2 { flatBlocks += 1 }
                    else if v < 24 { gradBlocks += 1 }
                    else {
                        var extreme = 0
                        let range = mx - mn, lo = mn + range / 5, hi = mx - range / 5
                        if range >= 60 {
                            for yy in by..<(by + 8) { let row = yy * w; for xx in bx..<(bx + 8) {
                                let p = Int(f0[row + xx]); if p <= lo || p >= hi { extreme += 1 } } }
                        }
                        if range >= 60 && extreme >= 52 { twoToneBlocks += 1 } else if v < 900 { textureBlocks += 1 }
                    }
                    blocks += 1; bx += 8
                }
                by += 8
            }
            let nb = Double(max(1, blocks))
            flat.append(Double(flatBlocks) / nb)
            grad.append(Double(gradBlocks) / nb)
            twoTone.append(Double(twoToneBlocks) / nb)
            texture.append(Double(textureBlocks) / nb)

            // --- colour diversity (quantised YUV of first frame, luma subsampled to chroma grid)
            let cw = w / 2, ch = h / 2
            var set = Set<Int>()
            for y in 0..<ch { for x in 0..<cw {
                let yv = Int(f0[(y * 2) * w + x * 2]) >> 3
                let u = Int(b.chroma[y * cw + x]) >> 3, v = Int(b.chroma[cw * ch + y * cw + x]) >> 3
                set.insert(yv << 10 | u << 5 | v)
            } }
            colours.append(Double(set.count) / Double(cw * ch) * 10_000)

            // --- temporal
            for k in 1..<b.frames.count {
                let p = b.frames[k - 1], q = b.frames[k]
                var diff = 0, still = 0, zero = 0
                for j in 0..<(w * h) { let d = abs(Int(q[j]) - Int(p[j])); diff += d; if d <= 2 { still += 1; if d == 0 { zero += 1 } } }
                let md = Double(diff) / Double(w * h)
                if md > 35 { cuts += 1; continue }          // scene cut — exclude from motion stats
                ti.append(md); stat.append(Double(still) / Double(w * h)); frozen.append(Double(zero) / Double(w * h)); pairs += 1
            }
            let burstTI = ti.count > tiStart ? ti[tiStart...].reduce(0, +) / Double(ti.count - tiStart) : 0
            demand.append((b.t, 0.45 * (si.last ?? 0) / 18 + 0.55 * burstTI / 6))
        }
        func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        let observedSecs = Double(pairs + cuts) / max(fps, 1)
        return ContentAnalysis(
            spatialInfo: mean(si), temporalInfo: mean(ti), staticFraction: median(stat), flatFraction: median(flat),
            gradientFraction: median(grad), noiseSigma: median(noise), hardEdgeRatio: median(hard),
            colourDiversity: median(colours), darkFraction: median(dark),
            cutsPerMinute: observedSecs > 0 ? Double(cuts) / observedSecs * 60 : 0,
            twoToneFraction: median(twoTone), textureFraction: median(texture), frozenFraction: median(frozen),
            edgeDensity: median(edgeDensity), isSynthetic: false,
            demandingMoments: demand.sorted { $0.1 > $1.1 }.prefix(2).map(\.0).sorted(),
            kind: .general, confidence: 0)
    }
}
