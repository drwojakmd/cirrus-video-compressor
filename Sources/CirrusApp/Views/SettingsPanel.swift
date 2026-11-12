import SwiftUI
import CirrusCore

struct SettingsPanel: View {
    @Environment(AppModel.self) private var model
    @Bindable var item: QueueItem
    var openStudio: () -> Void
    @State private var showAdvanced = false
    @State private var appliedNote: String?

    var body: some View {
        let src = item.source!
        let media = src.media
        let synthetic = src.analysis.isSynthetic || src.analysis.kind == .screenRecording
        let plan = try? model.engine?.plan(src, settings: item.settings)
        let caps = model.engine?.caps
        Card {
            HStack(spacing: 10) {
                SectionLabel(title: item.hasVersions ? "Version \(item.letter(item.current)) settings" : "Settings", systemImage: "slider.horizontal.3")
                Spacer()
                PresetMenu(targets: [item], label: "Preset")
                if model.items.count > 1 {
                    Menu {
                        if item.hasVersions {
                            Button("Make These \(item.versions.count) Versions for All Videos") {
                                let n = model.applyVersions(of: item)
                                appliedNote = "All \(n) videos will now be made in these \(item.versions.count) versions."
                            }
                            Divider()
                        }
                        Button(item.hasVersions ? "Apply Version \(item.letter(item.current))’s Settings to All Videos" : "Apply to All \(model.items.count) Videos") { apply(nil) }
                        Button("Apply to Videos Not Yet Compressed") { apply(model.items.filter { !$0.isFinished }) }
                    } label: { Label("Apply to All", systemImage: "square.on.square") }
                        .fixedSize()
                        .help("Give every video in the list these settings (content type stays per video)")
                }
            }
            SettingsSummaryLine(item: item, plan: plan)
            if let n = appliedNote ?? item.appliedNote { InfoRow(systemImage: "checkmark.circle.fill", text: n, tint: Brand.good) }

            // Resolution
            Row(title: "Resolution", systemImage: "rectangle.expand.vertical") {
                ResolutionPicker(item: item, source: media.displaySize)
                if let p = plan { ExplanationView(explanation: Explain.resolution(item.settings.resolution, from: media.displaySize, out: p.outputSize)) }
            }
            Divider()
            // Size
            Row(title: "File size", systemImage: "internaldrive") {
                SizeGoalPicker(item: item, media: media, synthetic: synthetic)
            }
            Divider()
            Row(title: "Format", systemImage: "sparkles") {
                let mac = caps?.systemDecodesAV1 ?? false
                let current = FormatChoice.of(item.settings, macDecodesAV1: mac)
                HStack(alignment: .top, spacing: 8) {
                    ForEach(FormatChoice.allCases) { f in
                        OptionPill(title: f.label, selected: current == f,
                                   caption: item.estimate(for: item.settings.with { f.apply(to: &$0, macDecodesAV1: mac) }, engine: model.engine),
                                   original: media.fileSize) { f.apply(to: &item.settings, macDecodesAV1: mac) }
                    }
                    Spacer(minLength: 0)
                    if plan?.previewableOnThisMac == false {
                        Chip(text: "No Quick Look on this Mac", systemImage: "eye.slash", tint: Brand.warn)
                            .help("Finder’s spacebar preview, QuickTime and Photos can’t play AV1 on this Mac (that needs an M3 or later). VLC, IINA, browsers and YouTube can.")
                    } else {
                        Chip(text: "Plays in Quick Look", systemImage: "eye", tint: Brand.good)
                    }
                }
                ExplanationView(explanation: Explain.format(current.priority, synthetic: synthetic,
                                                            previewable: current != .av1, macDecodesAV1: mac))
            }
            Divider()
            // Protections
            TextGuardRow(item: item, plan: plan)
            Divider()
            HStack(alignment: .top, spacing: 26) {
                Row(title: "Audio", systemImage: "waveform") {
                    Picker("", selection: $item.settings.audio) {
                        ForEach(AudioQuality.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                Row(title: "Content", systemImage: "person.crop.rectangle") {
                    Picker("", selection: $item.settings.advanced.profile) {
                        Text("Automatic (\(item.source?.analysis.kind.rawValue ?? "…"))").tag(ContentKind?.none)
                        Divider()
                        ForEach(ContentKind.allCases) { Text($0.rawValue).tag(ContentKind?.some($0)) }
                    }.labelsHidden().fixedSize()
                }
                Row(title: "Effort", systemImage: "gauge.with.dots.needle.67percent") {
                    Picker("", selection: $item.settings.depth) {
                        ForEach(AnalysisDepth.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Row(title: "Skip if saving under", systemImage: "arrow.uturn.backward.circle") {
                    Picker("", selection: $item.settings.minimumSavings) {
                        Text("Off").tag(0.0)
                        ForEach([0.05, 0.10, 0.20, 0.30], id: \.self) { Text("\(Int($0 * 100)) %").tag($0) }
                    }.labelsHidden().fixedSize()
                }
            }
            ExplanationView(explanation: Explain.depth(item.settings.depth))
            ExplanationView(explanation: Explain.minimumSavings)

            EstimateSummary(item: item, plan: plan, openStudio: openStudio)
            PlanSummary(item: item)

            DisclosureGroup(isExpanded: $showAdvanced) {
                AdvancedSettingsView(settings: $item.settings, caps: model.engine?.caps).padding(.top, 10)
            } label: {
                Text("Advanced").font(.callout.weight(.medium))
            }
        }
        .onChange(of: item.settings) { _, new in
            // new videos start from the main (first) version's settings, not from a "Fit for email" copy
            if item.current.id == item.versions.first?.id { model.prefs.settings = new; model.prefs.save() }
            appliedNote = nil; item.appliedNote = nil
        }
        .onAppear { model.ensureEstimate(item) }
    }

    func apply(_ targets: [QueueItem]?) {
        let n = model.applySettings(item.settings, to: targets)
        appliedNote = "These settings now apply to \(n) video\(n == 1 ? "" : "s")."
    }

    struct Row<C: View>: View {
        var title: String; var systemImage: String
        @ViewBuilder var content: C
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: title, systemImage: systemImage)
                content
            }
        }
    }
}

/// A pill with the estimated size for that choice underneath.
struct OptionPill: View {
    var title: String
    var selected: Bool
    var caption: SizeEstimate?
    var original: Int64
    var disabled = false
    var action: () -> Void
    var body: some View {
        VStack(spacing: 4) {
            PillButton(title: title, selected: selected, action: action).disabled(disabled).opacity(disabled ? 0.35 : 1)
            EstimateLabel(estimate: caption, original: original, compact: true)
                .font(.system(size: 10.5)).foregroundStyle(caption?.wouldSkip == true ? Brand.warn : .secondary)
                .help(caption.map { e in e.wouldSkip ? "Would save too little and be skipped" : (e.measured ? "Measured on sample scenes" : "Estimated from a measurement and benchmark ratios") } ?? "Estimating…")
        }
    }
}

struct TextGuardRow: View {
    @Bindable var item: QueueItem
    var plan: EncodePlan?
    var body: some View {
        let g = plan?.textGuard ?? .inactive
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(get: { g.active }, set: { item.settings.textGuard = $0 ? .on : .off })) {
                    Label("Keep text readable", systemImage: "text.viewfinder").font(.system(size: 13, weight: .medium))
                }
                .toggleStyle(.switch).controlSize(.small)
                if item.settings.textGuard != .automatic {
                    Button("Automatic") { item.settings.textGuard = .automatic }.buttonStyle(.link).font(.caption)
                        .help("Turn on whenever slides, captions or other text are detected")
                }
                Spacer()
                if let r = g.suggestedResolution {
                    Button("Use \(r.label)") { item.settings.resolution = r }.controlSize(.small)
                }
            }
            Text(g.reason).font(.caption).foregroundStyle(g.active ? Brand.accent : .secondary)
            ExplanationView(explanation: Explain.textGuard)
        }
    }
}

/// The headline estimate for the current settings.
struct EstimateSummary: View {
    @Environment(AppModel.self) private var model
    var item: QueueItem
    var plan: EncodePlan?
    var openStudio: () -> Void
    var body: some View {
        let media = item.source!.media
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Estimated result").font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(.secondary).kerning(0.4)
                if let e = item.estimate(for: item.settings, engine: model.engine) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        EstimateLabel(estimate: e, original: media.fileSize).font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text(verbatim: "\(e.outputSize.width) × \(e.outputSize.height)").foregroundStyle(.secondary).monospacedDigit()
                        Text("about \(Fmt.eta(e.seconds))").foregroundStyle(.secondary)
                    }
                    Text(e.wouldSkip ? "This would save less than your minimum, so the video would be skipped and left as it is."
                                     : (e.measured ? "Measured on sample scenes of this video." : "Scaled from a measurement on this video using the differences measured between settings. Preview Studio gives exact figures."))
                        .font(.caption).foregroundStyle(e.wouldSkip ? Brand.warn : Color.secondary)
                } else {
                    switch item.estimate {
                    case .running: HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Measuring sample scenes…").foregroundStyle(.secondary) }
                    case .failed: Text("Couldn’t estimate this video.").foregroundStyle(.secondary)
                    default: Text(model.isBusy ? "Estimates appear when the queue is idle." : "Waiting…").foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button { openStudio() } label: { Label("Preview Studio…", systemImage: "square.grid.2x2") }
                .controlSize(.large)
                .help("See frames as each option would look, with exact sizes, before compressing")
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ResolutionPicker: View {
    @Environment(AppModel.self) private var model
    @Bindable var item: QueueItem
    var source: PixelSize

    var body: some View {
        let resolution = item.settings.resolution
        HStack(alignment: .top, spacing: 6) {
            ForEach(OutputResolution.presets) { r in
                let resolved = r.resolve(source: source)
                let upscale = r != .original && resolved == OutputResolution.original.resolve(source: source) && (r.boxShortSide ?? 0) > source.shortSide
                OptionPill(title: r == .original ? "Original" : r.shortLabel, selected: resolution == r,
                           caption: upscale ? nil : item.estimate(for: item.settings.with { $0.resolution = r }, engine: model.engine), original: item.source?.media.fileSize ?? 0,
                           disabled: upscale) { item.settings.resolution = r }
                    .help(upscale ? "The source is only \(source.shortSide)p. Cirrus never upscales." : "\(resolved.width) × \(resolved.height)")
            }
            PillButton(title: "Custom", selected: isCustom) {
                let r = resolution.resolve(source: source)
                item.settings.resolution = .custom(width: r.width, height: r.height, keepAspect: true)
            }
        }
        if case .custom(let w, let h, let keep) = resolution {
            HStack(spacing: 8) {
                TextField("Width", value: Binding(get: { w }, set: { item.settings.resolution = .custom(width: max(16, $0), height: h, keepAspect: keep) }), format: .number)
                    .frame(width: 70)
                Text("×").foregroundStyle(.secondary)
                TextField("Height", value: Binding(get: { h }, set: { item.settings.resolution = .custom(width: w, height: max(16, $0), keepAspect: keep) }), format: .number)
                    .frame(width: 70)
                Toggle("Keep aspect ratio", isOn: Binding(get: { keep }, set: { item.settings.resolution = .custom(width: w, height: h, keepAspect: $0) }))
                    .toggleStyle(.checkbox)
            }.textFieldStyle(.roundedBorder)
        }
        let out = resolution.resolve(source: source)
        Text(verbatim: out == source ? "Output: \(out.width) × \(out.height) (unchanged)" : "Output: \(out.width) × \(out.height)")
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }

    var isCustom: Bool { if case .custom = item.settings.resolution { return true }; return false }
}

extension OutputResolution {
    var shortLabel: String {
        switch self {
        case .uhd2160: return "4K"
        case .qhd1440: return "1440p"
        case .fhd1080: return "1080p"
        case .hd720: return "720p"
        case .sd480: return "480p"
        default: return label
        }
    }
    var boxShortSide: Int? { box?.shortSide }
}

struct SizeGoalPicker: View {
    @Environment(AppModel.self) private var model
    @Bindable var item: QueueItem
    var media: MediaInfo
    var synthetic: Bool
    @State private var unitGB = false

    static let presetsMB: [Int] = [500, 250, 150, 100, 50]

    var isTarget: Bool { if case .targetSize = item.settings.goal { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: Binding(get: { isTarget }, set: { t in
                item.settings.goal = t ? .targetSize(bytes: Int64(defaultTarget * 1_000_000)) : .quality(.balanced)
            })) {
                Text("Choose quality").tag(false)
                Text("Choose file size").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)

            switch item.settings.goal {
            case .quality(let level):
                HStack(alignment: .top, spacing: 6) {
                    ForEach(QualityLevel.allCases) { l in
                        OptionPill(title: l.label, selected: l == level, caption: item.estimate(for: item.settings.with { $0.goal = .quality(l) }, engine: model.engine),
                                   original: media.fileSize) { item.settings.goal = .quality(l) }
                    }
                }
                ExplanationView(explanation: Explain.quality(level, synthetic: synthetic))
            case .targetSize(let bytes):
                HStack(spacing: 6) {
                    ForEach(Self.presetsMB, id: \.self) { mb in
                        PillButton(title: "\(mb) MB", selected: bytes == Int64(mb) * 1_000_000) { item.settings.goal = .targetSize(bytes: Int64(mb) * 1_000_000) }
                    }
                    Divider().frame(height: 18)
                    TextField("", value: Binding(get: { Double(bytes) / (unitGB ? 1e9 : 1e6) },
                                                  set: { item.settings.goal = .targetSize(bytes: Int64(max(0.1, $0) * (unitGB ? 1e9 : 1e6))) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder).frame(width: 72).multilineTextAlignment(.trailing)
                    Picker("", selection: $unitGB) { Text("MB").tag(false); Text("GB").tag(true) }
                        .labelsHidden().fixedSize()
                }
                TargetHint(bytes: bytes, media: media)
                Text("The file will never be larger than this: Cirrus checks the result and re-encodes if it’s over. Quality is the best that fits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// A sensible starting target: ~25 % of the original, rounded to a preset.
    var defaultTarget: Double {
        let quarter = Double(media.fileSize) / 4 / 1e6
        return Double(Self.presetsMB.min { abs(Double($0) - quarter) < abs(Double($1) - quarter) } ?? 150)
    }
}

/// Plain-English feedback on how demanding the target is (from bitrate maths, labelled as an estimate).
struct TargetHint: View {
    var bytes: Int64
    var media: MediaInfo
    var body: some View {
        let kbps = Double(bytes) * 8 / max(media.duration, 0.1) / 1000
        let ratio = Double(bytes) / Double(max(1, media.fileSize))
        HStack(spacing: 6) {
            if ratio >= 1 {
                Image(systemName: "checkmark.circle").foregroundStyle(Brand.good)
                Text("Larger than the original (\(Fmt.bytes(media.fileSize))). Cirrus will use only the space it needs.")
            } else {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(String(format: "≈ %@ total for %@ · %.0f%% of the original", kbps >= 1000 ? String(format: "%.1f Mbps", kbps / 1000) : "\(Int(kbps)) kbps",
                            Fmt.duration(media.duration), ratio * 100))
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

/// Shows what the engine is going to do, so nothing is a black box.
struct PlanSummary: View {
    @Environment(AppModel.self) private var model
    var item: QueueItem
    var body: some View {
        if let result = item.plan(with: model.engine) {
            switch result {
            case .success(let p):
                VStack(alignment: .leading, spacing: 5) {
                    InfoRow(systemImage: "cpu", text: summary(p), tint: Brand.accent)
                    ForEach(p.warnings, id: \.self) { InfoRow(systemImage: "exclamationmark.triangle.fill", text: $0, tint: Brand.warn) }
                    ForEach(p.notes, id: \.self) { InfoRow(systemImage: "info.circle", text: $0) }
                }
                .padding(.horizontal, 2)
            case .failure(let e):
                InfoRow(systemImage: "xmark.octagon.fill", text: e.localizedDescription, tint: .red)
            }
        }
    }

    func summary(_ p: EncodePlan) -> String {
        var s = "\(p.codec.rawValue) via \(p.encoder.rawValue) · \(p.outputSize.width) × \(p.outputSize.height) · \(p.params.tenBit ? "10-bit" : "8-bit") · \(p.audio.summary)"
        switch p.rate {
        case .searchQuality(let t, _): s += String(format: " · tuned to VMAF %.0f on sample scenes", t)
        case .fixedQuality: s += " · predicted settings"
        case .targetSize(_, let k): s += " · ≈ \(k >= 1000 ? String(format: "%.1f Mbps", Double(k) / 1000) : "\(k) kbps") video, two-pass"
        }
        return s
    }
}

extension CompressionSettings {
    func with(_ change: (inout CompressionSettings) -> Void) -> CompressionSettings { var c = self; change(&c); return c }
}

/// "You'll get: HEVC · 1920 × 1080 · Balanced · ≈ 1.4 MB · text kept readable · plays in Quick Look"
struct SettingsSummaryLine: View {
    @Environment(AppModel.self) private var model
    var item: QueueItem
    var plan: EncodePlan?
    var body: some View {
        let mac = model.engine?.caps.systemDecodesAV1 ?? false
        let f = FormatChoice.of(item.settings, macDecodesAV1: mac)
        let est = item.estimate(for: item.settings, engine: model.engine)
        HStack(spacing: 8) {
            Text("You’ll get").foregroundStyle(.secondary)
            Chip(text: f.title, systemImage: "film", tint: Brand.accent)
            if let p = plan { Chip(text: "\(p.outputSize.width) × \(p.outputSize.height)", systemImage: "rectangle.expand.vertical", tint: Brand.accent) }
            switch item.settings.goal {
            case .quality(let l): Chip(text: l.label, systemImage: "dial.medium", tint: Brand.accent)
            case .targetSize(let b): Chip(text: "Under \(Fmt.bytes(b))", systemImage: "target", tint: Brand.accent)
            }
            if let e = est { Chip(text: "≈ \(Fmt.bytes(e.bytes))", systemImage: "internaldrive", tint: Brand.dawn) }
            if plan?.textGuard.active == true { Chip(text: "Text kept readable", systemImage: "text.viewfinder", tint: Brand.good) }
        }
        .font(.callout)
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
