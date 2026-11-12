import SwiftUI
import CirrusCore

/// Original vs. compressed, frame-accurate, at the output resolution.
/// Modes: side-by-side, split wipe, and flip (A/B). Zoom applies identically
/// to both images so detail can be inspected pixel for pixel.
struct CompareView: View {
    let engine: CompressionEngine
    let source: SourceItem
    let settings: CompressionSettings
    let target: CompareTarget

    @Environment(\.dismiss) private var dismiss
    enum Mode: String, CaseIterable, Identifiable { case sideBySide = "Side by Side", split = "Split", flip = "Flip"; var id: String { rawValue } }

    @State private var mode: Mode = .split
    @State private var time: Double = 0
    @State private var original: CGImage?
    @State private var compressed: CGImage?
    @State private var loadingFrames = false
    @State private var split: CGFloat = 0.5
    @State private var zoom: CGFloat = 1
    @State private var focus: UnitPoint = .center
    @State private var showOriginalInFlip = false
    // preview mode
    @State private var preview: PreviewResult?
    @State private var previewProgress: (Double, String)?
    @State private var previewError: String?
    @State private var workspace = try? TempWorkspace(label: "preview")
    @State private var previewTask: Task<Void, Never>?

    var duration: Double { source.media.duration }
    var isPreview: Bool { if case .preview = target { return true }; return false }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                Color.black
                if let original, let compressed {
                    imageStage(original, compressed)
                } else if let p = previewProgress {
                    VStack(spacing: 10) {
                        ProgressView(value: p.0).frame(width: 280).tint(Brand.accent)
                        Text(p.1).foregroundStyle(.white.opacity(0.8)).font(.callout)
                    }
                } else if let e = previewError {
                    Text(e).foregroundStyle(.white).padding()
                } else {
                    ProgressView().tint(.white)
                }
                if loadingFrames { ProgressView().controlSize(.small).tint(.white).padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) }
            }
            .frame(minHeight: 420)
            Divider()
            controls
        }
        .frame(minWidth: 980, minHeight: 700)
        .task { await start() }
        .onDisappear { previewTask?.cancel(); workspace?.remove() }
    }

    // MARK: header

    var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isPreview ? "Preview" : "Compare with Original").font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            ForEach(metrics, id: \.0) { m in
                VStack(alignment: .trailing, spacing: 1) {
                    Text(m.0).font(.system(size: 10, weight: .semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                    Text(m.1).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.large)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    var subtitle: String {
        switch target {
        case .preview:
            guard let p = preview else { return "Encoding a few seconds with your settings…" }
            return "\(Fmt.duration(p.start))–\(Fmt.duration(p.start + p.duration)) · \(p.summary)"
        case .result(let r): return "\(r.outputURL.lastPathComponent) · \(r.settingsSummary)"
        }
    }

    var metrics: [(String, String)] {
        switch target {
        case .preview:
            guard let p = preview else { return [] }
            var m: [(String, String)] = [("Bitrate here", p.kbps >= 1000 ? String(format: "%.1f Mbps", p.kbps / 1000) : "\(Int(p.kbps)) kbps")]
            if let b = p.predictedBytes { m.append(("Est. file size", "≈ " + Fmt.bytes(b))) }
            if let q = p.quality { m.append(("VMAF (this clip)", String(format: "%.1f", q.vmaf))) }
            return m
        case .result(let r):
            var m: [(String, String)] = [("Original", Fmt.bytes(r.originalBytes)), ("Compressed", Fmt.bytes(r.outputBytes))]
            if let q = r.quality { m.append(("VMAF", String(format: "%.1f", q.vmaf))); if let p = q.psnr { m.append(("PSNR", String(format: "%.1f dB", p))) } }
            return m
        }
    }

    // MARK: images

    @ViewBuilder func imageStage(_ a: CGImage, _ b: CGImage) -> some View {
        GeometryReader { geo in
            switch mode {
            case .sideBySide:
                HStack(spacing: 2) {
                    pane(a, label: "Original", size: CGSize(width: geo.size.width / 2 - 1, height: geo.size.height))
                    pane(b, label: "Compressed", size: CGSize(width: geo.size.width / 2 - 1, height: geo.size.height))
                }
            case .split:
                ZStack(alignment: .leading) {
                    pane(b, label: nil, size: geo.size)
                    pane(a, label: nil, size: geo.size)
                        .mask(HStack(spacing: 0) { Rectangle().frame(width: geo.size.width * split); Spacer(minLength: 0) })
                    Rectangle().fill(.white).frame(width: 2).shadow(radius: 2).offset(x: geo.size.width * split - 1)
                    Circle().fill(.white).frame(width: 26, height: 26).overlay(Image(systemName: "arrow.left.and.right").font(.caption.bold()).foregroundStyle(.black))
                        .offset(x: geo.size.width * split - 13).frame(maxHeight: .infinity)
                    tag("Original").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    tag("Compressed").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { split = min(1, max(0, $0.location.x / geo.size.width)) })
            case .flip:
                ZStack(alignment: .topLeading) {
                    pane(showOriginalInFlip ? a : b, label: nil, size: geo.size)
                    tag(showOriginalInFlip ? "Original" : "Compressed")
                }
                .onTapGesture { showOriginalInFlip.toggle() }
            }
        }
    }

    func pane(_ img: CGImage, label: String?, size: CGSize) -> some View {
        Image(cgImage: img)
            .resizable().interpolation(zoom > 1.5 ? .none : .high).aspectRatio(contentMode: .fit)
            .scaleEffect(zoom, anchor: focus)
            .frame(width: size.width, height: size.height).clipped()
            .overlay(alignment: .topLeading) { if let label { tag(label) } }
            .onTapGesture(count: 2) { location in
                focus = UnitPoint(x: location.x / max(1, size.width), y: location.y / max(1, size.height))
                zoom = zoom >= 4 ? 1 : zoom * 2
            }
    }

    func tag(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule()).foregroundStyle(.white).padding(10)
    }

    // MARK: controls

    var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Picker("", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                Picker("Zoom", selection: $zoom) {
                    Text("Fit").tag(CGFloat(1)); Text("2×").tag(CGFloat(2)); Text("4×").tag(CGFloat(4)); Text("8×").tag(CGFloat(8))
                }.pickerStyle(.segmented).frame(width: 220)
                Text(mode == .flip ? "Click the image to flip" : "Double-click to zoom into a spot").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if case .result(let r) = target, let q = r.quality, !q.worstMoments.isEmpty {
                    Menu {
                        ForEach(q.worstMoments, id: \.time) { w in
                            Button(String(format: "%@  —  VMAF %.1f", Fmt.duration(w.time), w.vmaf)) { time = w.time; Task { await loadFrames() } }
                        }
                    } label: { Label("Weakest moments", systemImage: "scope") }.fixedSize()
                }
            }
            HStack(spacing: 12) {
                Text(Fmt.duration(time)).monospacedDigit().frame(width: 52, alignment: .leading)
                Slider(value: $time, in: sliderRange) { editing in if !editing { Task { await reload() } } }
                Text(Fmt.duration(sliderRange.upperBound)).monospacedDigit().foregroundStyle(.secondary)
                if isPreview {
                    Button("Preview Another Moment") { Task { await choosePreviewMoment() } }
                        .disabled(previewProgress != nil)
                }
            }
        }
        .padding(14)
    }

    var sliderRange: ClosedRange<Double> {
        if isPreview, let p = preview { return p.start...(p.start + max(0.1, p.duration - 0.05)) }
        return 0...max(0.1, duration - 0.05)
    }

    // MARK: loading

    func start() async {
        switch target {
        case .result(let r):
            time = r.quality?.worstMoments.first?.time ?? duration * 0.3
            await loadFrames()
        case .preview:
            await runPreview(at: source.media.duration * 0.3)
        }
    }

    func runPreview(at t: Double) async {
        guard let ws = workspace else { previewError = "Couldn’t create a temporary folder."; return }
        previewProgress = (0, "Finding the best settings…")
        original = nil; compressed = nil
        do {
            let p = try await engine.preview(source, settings: settings, at: t, workspace: ws) { f, s in
                Task { @MainActor in if previewProgress != nil { previewProgress = (f, s) } }
            }
            preview = p
            previewProgress = nil
            time = p.start + p.duration / 2
            await loadFrames()
        } catch {
            previewProgress = nil
            previewError = error.localizedDescription
        }
    }

    func choosePreviewMoment() async {
        // move the preview window to where the scrubber was released last, or 25 % further along
        let next = preview.map { ($0.start + $0.duration + duration * 0.2).truncatingRemainder(dividingBy: max(1, duration)) } ?? duration * 0.5
        await runPreview(at: next)
    }

    func reload() async { await loadFrames() }

    func loadFrames() async {
        loadingFrames = true
        defer { loadingFrames = false }
        let grab = FrameGrabber(tools: engine.tools)
        do {
            switch target {
            case .result(let r):
                async let a = grab.frame(source.media.url, at: time, exactSize: r.outputSize,
                                         filters: source.media.video.isInterlaced ? "bwdif=mode=send_frame" : nil)
                async let b = grab.frame(r.outputURL, at: time)
                (original, compressed) = try await (a, b)
            case .preview:
                guard let p = preview else { return }
                let t = max(0, time - p.start)
                async let a = grab.frame(p.referenceURL, at: t)
                async let b = grab.frame(p.encodedURL, at: t)
                (original, compressed) = try await (a, b)
            }
        } catch {
            previewError = error.localizedDescription
        }
    }
}
