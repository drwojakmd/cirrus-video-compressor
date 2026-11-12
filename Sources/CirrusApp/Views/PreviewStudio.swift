import SwiftUI
import AppKit
import CirrusCore

/// Compare the video's versions (plus a few suggestions) on its own frames before
/// compressing: each option is measured on sample scenes (size, quality, text
/// legibility, time), and chosen moments are encoded with its exact settings so you can
/// flip between them and the original at 1:1. Ticked options *are* the video's versions:
/// editing one here edits the version in the main window.
struct PreviewStudio: View {
    let engine: CompressionEngine
    @Bindable var item: QueueItem
    let source: SourceItem
    var close: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    struct Moment: Identifiable, Hashable { let id = UUID(); var time: Double; var label: String; var symbol: String }

    @MainActor @Observable final class Option: Identifiable {
        let id = UUID()
        var title: String
        var settings: CompressionSettings { didSet { if let v = linked, v.isEditable { v.settings = settings } } }
        /// The video's version this option is (nil = a suggestion, not made unless ticked).
        var linked: OutputVersion?
        var version = 0
        var evaluation: StudioEvaluation?
        var progress: (Double, String)?
        var error: String?
        /// Frames encoded with the measured settings.
        var frames: [UUID: CGImage] = [:]
        /// Frames encoded with predicted settings, shown within seconds while measuring.
        var predicted: [UUID: CGImage] = [:]
        var locked: Bool { linked.map { !$0.isEditable } ?? false }
        init(title: String, settings: CompressionSettings, linked: OutputVersion? = nil) { self.title = title; self.settings = settings; self.linked = linked }
        func reset() { version += 1; evaluation = nil; error = nil; frames = [:]; predicted = [:]; progress = nil }
    }

    enum Zoom: String, CaseIterable, Identifiable { case fit = "Fit", actual = "Actual pixels", double = "2×"; var id: String { rawValue } }

    @State private var options: [Option] = []
    @State private var moments: [Moment] = []
    @State private var selectedMoment: UUID?
    @State private var originals: [UUID: CGImage] = [:]
    @State private var showing = 1             // 0 = original
    @State private var zoom: Zoom = .fit
    @State private var customTime: Double = 0
    @State private var worker: Task<Void, Never>?
    @State private var workspace = try? TempWorkspace(label: "studio")

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                viewer
                Divider()
                momentsColumn.frame(width: 210)
            }
            Divider()
            optionRow
        }
        .frame(minWidth: 1120, minHeight: 820)
        .onAppear(perform: setUp)
        .onDisappear { worker?.cancel(); workspace?.remove() }
    }

    // MARK: header

    var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Preview Studio").font(.title3.weight(.semibold))
                Text("\(item.name) · ticked options are the versions Cirrus will make · frames are encoded with each option’s exact settings")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Picker("", selection: $showing) {
                Text("Original").tag(0)
                ForEach(Array(options.enumerated()), id: \.element.id) { i, o in Text(o.linked == nil ? "Idea · \(o.title)" : "\(letter(o)) · \(o.title)").tag(i + 1) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Flip between the original and each option (← → or 0–\(options.count))")
            Picker("", selection: $zoom) { ForEach(Zoom.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.large)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background {
            // keyboard: arrows cycle, digits pick
            Group {
                Button("") { showing = (showing + options.count) % (options.count + 1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { showing = (showing + 1) % (options.count + 1) }.keyboardShortcut(.rightArrow, modifiers: [])
                ForEach(0..<7, id: \.self) { n in Button("") { if n <= options.count { showing = n } }.keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: []) }
            }.opacity(0).allowsHitTesting(false)
        }
    }

    // MARK: viewer

    var referenceSize: PixelSize {
        let sizes = options.compactMap { o in o.evaluation?.outputSize ?? (try? engine.plan(source, settings: o.settings))?.outputSize }
        return sizes.max { $0.pixels < $1.pixels } ?? source.media.displaySize
    }

    var currentImage: CGImage? {
        guard let m = selectedMoment else { return nil }
        if showing == 0 { return originals[m] }
        guard showing - 1 < options.count else { return nil }
        let o = options[showing - 1]
        return o.frames[m] ?? o.predicted[m]
    }

    var showingPredicted: Bool {
        guard showing > 0, showing - 1 < options.count, let m = selectedMoment else { return false }
        let o = options[showing - 1]
        return o.frames[m] == nil && o.predicted[m] != nil
    }

    var viewer: some View {
        ZStack {
            Color.black
            if let img = currentImage {
                let ref = referenceSize
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                switch zoom {
                case .fit:
                    Image(cgImage: img).resizable().interpolation(.high).aspectRatio(CGFloat(ref.width) / CGFloat(ref.height), contentMode: .fit)
                case .actual, .double:
                    let f: CGFloat = zoom == .double ? 2 : 1
                    ScrollView([.horizontal, .vertical]) {
                        Image(cgImage: img).resizable().interpolation(zoom == .double ? .none : .high)
                            .frame(width: CGFloat(ref.width) * f / scale, height: CGFloat(ref.height) * f / scale)
                    }
                    .defaultScrollAnchor(.center)
                }
            } else {
                VStack(spacing: 10) {
                    if showing > 0, showing - 1 < options.count, let p = options[showing - 1].progress {
                        ProgressView(value: p.0).frame(width: 260).tint(Brand.accent)
                        Text(p.1).foregroundStyle(.white.opacity(0.8)).font(.callout)
                    } else if showing > 0, showing - 1 < options.count, let e = options[showing - 1].error {
                        Text(e).foregroundStyle(.white).multilineTextAlignment(.center).frame(maxWidth: 420)
                    } else {
                        ProgressView().tint(.white)
                        Text(showing == 0 ? "Loading the original frame…" : "Waiting for this option…").foregroundStyle(.white.opacity(0.7)).font(.callout)
                    }
                }
            }
            VStack {
                HStack {
                    Text(showing == 0 ? "Original" : (showing - 1 < options.count ? label(options[showing - 1]) : ""))
                        .font(.caption.weight(.semibold)).padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule()).foregroundStyle(.white)
                    if showingPredicted {
                        Text("Predicted settings · measuring…").font(.caption).padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Brand.dawnFixed.opacity(0.9), in: Capsule()).foregroundStyle(Brand.altitude)
                    }
                    Spacer()
                    if let m = moments.first(where: { $0.id == selectedMoment }) {
                        Text("\(m.label) · \(Fmt.duration(m.time))").font(.caption).padding(.horizontal, 9).padding(.vertical, 5)
                            .background(.black.opacity(0.55), in: Capsule()).foregroundStyle(.white.opacity(0.9))
                    }
                }
                Spacer()
            }.padding(12)
        }
        .frame(minHeight: 420)
    }

    // MARK: moments

    var momentsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Moments", systemImage: "film.stack")
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(moments) { m in
                        Button { selectedMoment = m.id; pump() } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.85))
                                    if let o = originals[m.id] { Image(cgImage: o).resizable().aspectRatio(contentMode: .fit) }
                                }
                                .frame(height: 96).clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selectedMoment == m.id ? Brand.accent : .clear, lineWidth: 2))
                                Label("\(m.label) · \(Fmt.duration(m.time))", systemImage: m.symbol).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            Divider()
            Text("Another moment").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Slider(value: $customTime, in: 0...max(0.1, source.media.duration - 0.1))
            HStack {
                Text(Fmt.duration(customTime)).monospacedDigit().font(.caption)
                Spacer()
                Button("Add") { addMoment(customTime, label: "Chosen", symbol: "hand.point.up.left") }.controlSize(.small)
            }
        }
        .padding(12)
    }

    // MARK: options

    var optionRow: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(options.enumerated()), id: \.element.id) { i, o in
                    OptionCard(option: o, letter: letter(o), isShowing: showing == i + 1,
                               baseline: i == 0 ? nil : options.first?.evaluation,
                               original: source.media.fileSize, source: source, engine: engine,
                               canUntick: item.versions.count > 1,
                               show: { showing = i + 1 },
                               changed: { o.reset(); pump() },
                               remove: o.linked == nil ? { removeOption(o) } : nil,
                               keep: { setKeep(o, $0) },
                               keepOnly: { keepOnly(o) })
                }
                if options.count < 6 {
                    Button { addOption() } label: {
                        VStack(spacing: 6) { Image(systemName: "plus").font(.title2); Text("Try another").font(.callout) }
                            .frame(width: 140, height: 200).foregroundStyle(.secondary)
                            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    }.buttonStyle(.plain)
                }
            }
            .padding(14)
        }
        .frame(height: 300)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                let pending = item.pendingVersions
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(pending.count) version\(pending.count == 1 ? "" : "s") to make" + (totals.map { " · about \(Fmt.bytes($0.0)) · about \(Fmt.eta($0.1))" } ?? ""))
                        .font(.callout.weight(.medium)).monospacedDigit()
                    Text("Tick “Make this version” on an option to add it; untick to drop it. Changes show in the main window too.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.items.count > 1 {
                    Button("Use for All Videos") { model.applyVersions(of: item) }
                        .help("Make every video in the list in these same versions")
                }
                Button("Done") { close() }
                Button(model.prefs.outputMode == .replaceOriginals ? "Compress and Replace" : "Compress \(pending.count) Version\(pending.count == 1 ? "" : "s")") {
                    model.requestCompress([item])
                    close()
                }
                .buttonStyle(ProminentButtonStyle())
                .disabled(pending.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)
        }
    }

    /// Size and time of the versions still to make: measured here where possible, otherwise estimated.
    var totals: (Int64, Double)? {
        var b: Int64 = 0, t = 0.0
        for v in item.pendingVersions {
            if let e = options.first(where: { $0.linked?.id == v.id })?.evaluation { b += e.predictedBytes; t += e.estimatedSeconds }
            else if let e = item.estimate(for: v.settings, engine: engine) { b += e.bytes; t += e.seconds }
            else { return nil }
        }
        return (b, t)
    }

    func letter(_ o: Option) -> String { o.linked.map { item.letter($0) } ?? "+" }
    func label(_ o: Option) -> String { o.linked == nil ? "Idea · \(o.title)" : "\(letter(o)) · \(o.title)" }

    func setKeep(_ o: Option, _ on: Bool) {
        if on, o.linked == nil {
            o.linked = item.addVersion(o.settings, select: false)
            o.title = o.settings.versionLabel(macDecodesAV1: engine.caps.systemDecodesAV1)
        } else if !on, let v = o.linked, v.isEditable, item.versions.count > 1 {
            item.removeVersion(v)
            o.linked = nil
        }
        model.saveQueue()
    }

    /// Make this option the only version still to make.
    func keepOnly(_ o: Option) {
        setKeep(o, true)
        for other in options where other.id != o.id && other.linked?.isEditable == true { setKeep(other, false) }
        if let v = o.linked { item.selectedVersionID = v.id }
    }

    // MARK: setup & work

    func setUp() {
        guard options.isEmpty else { return }
        let mac = engine.caps.systemDecodesAV1
        var list: [Option] = item.versions.map { v in
            Option(title: item.hasVersions ? v.settings.versionLabel(macDecodesAV1: mac) : "Your settings", settings: v.settings, linked: v)
        }
        // with one version, suggest alternatives to compare it with
        if !item.hasVersions {
            let current = item.settings
            let plan = try? engine.plan(source, settings: current)
            switch current.goal {
            case .quality(let l) where l != .maximumCompression:
                list.append(Option(title: "Smaller", settings: current.with { $0.goal = .quality(QualityLevel(rawValue: l.rawValue + 1)!) }))
            case .quality:
                list.append(Option(title: "Higher quality", settings: current.with { $0.goal = .quality(.aggressive) }))
            case .targetSize(let b):
                list.append(Option(title: "Smaller target", settings: current.with { $0.goal = .targetSize(bytes: b * 6 / 10) }))
            }
            if let p = plan, p.codec != .av1, engine.caps.hasSVTAV1 {
                list.append(Option(title: "AV1 · smallest", settings: current.with { FormatChoice.av1.apply(to: &$0, macDecodesAV1: mac) }))
            } else if let p = plan, let lower = OutputResolution.stepDown(from: p.outputSize),
                      let preset = OutputResolution.presets.first(where: { $0.box?.shortSide == lower.shortSide }) {
                list.append(Option(title: "\(preset.shortLabel)", settings: current.with { $0.resolution = preset }))
            }
        }
        options = list
        if let i = options.firstIndex(where: { $0.linked?.id == item.selectedVersionID }) { showing = i + 1 }

        let D = source.media.duration
        var ms: [Moment] = []
        for t in source.text.moments.prefix(3) { ms.append(Moment(time: t.time, label: ms.isEmpty ? "Smallest text" : "Text", symbol: "text.viewfinder")) }
        for t in source.analysis.demandingMoments where !ms.contains(where: { abs($0.time - t) < 2 }) {
            ms.append(Moment(time: t, label: "Most detail & motion", symbol: "figure.run"))
        }
        if ms.isEmpty { ms = [Moment(time: D * 0.3, label: "Early", symbol: "film"), Moment(time: D * 0.65, label: "Later", symbol: "film")] }
        moments = ms
        selectedMoment = ms.first?.id
        customTime = D * 0.5
        pump()
    }

    func addMoment(_ t: Double, label: String, symbol: String) {
        let m = Moment(time: t, label: label, symbol: symbol)
        moments.append(m)
        selectedMoment = m.id
        pump()
    }

    func addOption() {
        let base = options.last?.settings ?? item.settings
        options.append(Option(title: "Your idea", settings: base))
        showing = options.count
        pump()
    }

    func removeOption(_ o: Option) {
        options.removeAll { $0.id == o.id }
        showing = min(showing, options.count)
    }

    func frameKey(_ o: Option, _ m: Moment) -> String { "\(o.settings.hashValue)|\(m.time)" }

    /// Single worker: evaluate options, then fill frames (selected moment first).
    func pump() {
        guard worker == nil else { return }
        worker = Task { @MainActor in
            defer { worker = nil }
            while !Task.isCancelled, let ws = workspace {
                // 1. original frame for the selected moment, then for the rest
                let ref = referenceSize
                if let m = moments.first(where: { $0.id == selectedMoment && originals[$0.id] == nil }) ?? moments.first(where: { originals[$0.id] == nil }) {
                    originals[m.id] = try? await engine.originalFrame(source, at: m.time, size: ref)
                    if originals[m.id] == nil { originals[m.id] = CGImage.placeholder }
                    continue
                }
                // 2. within seconds: every option's selected moment with predicted settings
                if let m = moments.first(where: { $0.id == selectedMoment }),
                   let o = options.first(where: { $0.frames[m.id] == nil && $0.predicted[m.id] == nil && $0.error == nil }) {
                    let v = o.version
                    if let cached = item.studioFrames[frameKey(o, m)] { o.frames[m.id] = cached; continue }
                    o.progress = (0.05, "Previewing with predicted settings")
                    var frame = CGImage.placeholder
                    if let d = try? engine.predictedDecision(source, settings: o.settings),
                       let img = try? await engine.encodedFrame(source, decision: d, at: m.time, workspace: ws) { frame = img }
                    if o.version == v { o.predicted[m.id] = frame; if o.evaluation == nil { o.progress = (0.1, "Measuring sample scenes") } }
                    continue
                }
                // 3. evaluate options in order
                if let o = options.first(where: { $0.evaluation == nil && $0.error == nil }) {
                    let v = o.version
                    o.progress = (0, "Measuring sample scenes")
                    do {
                        let e = try await engine.evaluate(source, settings: o.settings, workspace: ws) { f, s in
                            Task { @MainActor in if o.version == v { o.progress = (f, s) } }
                        }
                        if o.version == v { o.evaluation = e; o.progress = nil }
                    } catch {
                        if Task.isCancelled { return }
                        if o.version == v { o.error = error.localizedDescription; o.progress = nil }
                    }
                    continue
                }
                // 4. frames with the measured settings: selected moment for every option, then the rest
                let order = moments.filter { $0.id == selectedMoment } + moments.filter { $0.id != selectedMoment }
                var did = false
                outer: for m in order {
                    for o in options {
                        guard let e = o.evaluation, o.frames[m.id] == nil else { continue }
                        let v = o.version
                        if let cached = item.studioFrames[frameKey(o, m)] { o.frames[m.id] = cached; did = true; break outer }
                        o.progress = (0.5, "Encoding \(Fmt.duration(m.time)) with these settings")
                        let img = (try? await engine.encodedFrame(source, decision: e.decision, at: m.time, workspace: ws)) ?? CGImage.placeholder
                        if o.version == v { o.frames[m.id] = img; o.progress = nil; item.studioFrames[frameKey(o, m)] = img }
                        did = true
                        break outer
                    }
                }
                if !did { break }
            }
        }
    }
}

/// One option: its settings (editable) and what they'd produce.
struct OptionCard: View {
    @Bindable var option: PreviewStudio.Option
    var letter: String
    var isShowing: Bool
    var baseline: StudioEvaluation?
    var original: Int64
    var source: SourceItem
    var engine: CompressionEngine
    var canUntick: Bool
    var show: () -> Void
    var changed: () -> Void
    var remove: (() -> Void)?
    var keep: (Bool) -> Void
    var keepOnly: () -> Void

    var macDecodesAV1: Bool { engine.caps.systemDecodesAV1 }
    var format: FormatChoice { FormatChoice.of(option.settings, macDecodesAV1: macDecodesAV1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(letter).font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(option.linked == nil ? Color.secondary : Color(nsColor: .windowBackgroundColor))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(option.linked == nil ? Color.clear : Brand.accent))
                    .overlay(Circle().strokeBorder(option.linked == nil ? Color.secondary.opacity(0.6) : .clear, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                TextField("", text: $option.title).textFieldStyle(.plain).font(.system(size: 13.5, weight: .semibold))
                Spacer()
                if let remove { Button { remove() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove this option") }
            }
            // settings
            Group {
            HStack(spacing: 6) {
                Menu(option.settings.resolution.shortLabel) {
                    ForEach(OutputResolution.presets) { r in Button(r.label) { option.settings.resolution = r; changed() } }
                }.fixedSize()
                Menu(goalLabel) {
                    ForEach(QualityLevel.allCases) { l in Button(l.label) { option.settings.goal = .quality(l); changed() } }
                    Divider()
                    ForEach([0.75, 0.5, 0.25, 0.1], id: \.self) { f in
                        let b = Int64(Double(original) * f)
                        Button("Target \(Fmt.bytes(b)) (\(Int(f * 100)) % of original)") { option.settings.goal = .targetSize(bytes: b); changed() }
                    }
                }.fixedSize()
            }.controlSize(.small)
            HStack(spacing: 6) {
                Menu(format.label) {
                    ForEach(FormatChoice.allCases) { f in Button(f.label) { f.apply(to: &option.settings, macDecodesAV1: macDecodesAV1); changed() } }
                }.fixedSize()
                Toggle("Text guard", isOn: Binding(get: { option.settings.textGuard != .off }, set: { option.settings.textGuard = $0 ? .on : .off; changed() }))
                    .toggleStyle(.checkbox)
            }.controlSize(.small)
            }
            .disabled(option.locked)
            Divider()
            if let e = option.evaluation {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    stat("Size", "≈ \(Fmt.bytes(e.predictedBytes))", pct(e.predictedBytes, original, "vs original"))
                    if let b = baseline { stat("vs A", pct(e.predictedBytes, b.predictedBytes, "") ?? "same", nil) }
                    stat("Dimensions", "\(e.outputSize.width) × \(e.outputSize.height)", nil)
                    stat("Quality", e.sampleVMAF.map { String(format: "VMAF %.1f", $0) } ?? "not measured", nil)
                    if let t = e.textCheck { stat("Text", String(format: "%.0f%% reads the same", t.accuracy * 100), nil) }
                    stat("Time", "about \(Fmt.eta(e.estimatedSeconds))", nil)
                    stat("Quick Look", e.previewableOnThisMac ? "Plays on this Mac" : "Not on this Mac", nil)
                }
                .font(.system(size: 11.5))
            } else if let p = option.progress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: p.0).tint(Brand.accent)
                    Text(p.1).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            } else if let err = option.error {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(4)
            } else {
                Text("Waiting…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if option.locked {
                    Label(lockedText, systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle("Make this version", isOn: Binding(get: { option.linked != nil }, set: { keep($0) }))
                        .toggleStyle(.checkbox).controlSize(.small)
                        .disabled(option.linked != nil && !canUntick)
                        .help(option.linked != nil && !canUntick ? "A video needs at least one version" : "Ticked options are the versions Cirrus will make")
                }
                Spacer()
                if !option.locked {
                    Button("Only This") { keepOnly() }.controlSize(.small)
                        .help("Make this the only version (drops the other unmade versions)")
                }
            }
        }
        .padding(12)
        .frame(width: 250, height: 272, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isShowing ? Brand.accent : Color.secondary.opacity(0.25), lineWidth: isShowing ? 2 : 0.5))
        .contentShape(Rectangle())
        .onTapGesture { show() }
    }

    var lockedText: String {
        switch option.linked?.job {
        case .done: return "Already made"
        case .skipped: return "Left as it is"
        default: return "Compressing"
        }
    }

    var goalLabel: String {
        switch option.settings.goal {
        case .quality(let l): return l.label
        case .targetSize(let b): return "≤ \(Fmt.bytes(b))"
        }
    }

    func pct(_ a: Int64, _ b: Int64, _ suffix: String) -> String? {
        guard b > 0 else { return nil }
        let r = Double(a) / Double(b) - 1
        if abs(r) < 0.005 { return nil }
        return String(format: r < 0 ? "−%.0f%%" : "+%.0f%%", abs(r) * 100) + (suffix.isEmpty ? "" : " " + suffix)
    }

    @ViewBuilder func stat(_ k: String, _ v: String, _ extra: String?) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(v).fontWeight(.medium).monospacedDigit()
                if let extra { Text(extra).foregroundStyle(extra.hasPrefix("−") ? Brand.good : Brand.warn).monospacedDigit() }
            }
        }
    }
}

extension CGImage {
    /// 2×2 grey image used when a frame couldn't be produced (keeps the worker moving).
    static let placeholder: CGImage = {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return ctx.makeImage()!
    }()
}
