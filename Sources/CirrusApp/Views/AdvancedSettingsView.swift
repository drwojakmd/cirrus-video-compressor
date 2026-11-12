import SwiftUI
import CirrusCore

/// Expert controls. Every one defaults to "Automatic"; most users never open this.
struct AdvancedSettingsView: View {
    @Binding var settings: CompressionSettings
    var caps: FFmpegCapabilities?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text("Encoder").gridColumnAlignment(.trailing)
                Picker("", selection: $settings.advanced.encoder) {
                    Text("Automatic").tag(EncoderID?.none)
                    Divider()
                    ForEach(EncoderID.allCases) { e in
                        let ok = caps.map { EncoderRegistry.encoder(e).isAvailable($0) } ?? true
                        Text("\(e.codec.rawValue) — \(e.rawValue)\(ok ? "" : " (unavailable)")").tag(EncoderID?.some(e))
                    }
                }.labelsHidden().fixedSize()
            }
            GridRow {
                Text("Encoding speed")
                Picker("", selection: $settings.advanced.speed) {
                    Text("Automatic").tag(EncoderSpeed?.none)
                    ForEach(EncoderSpeed.allCases) { Text($0.label).tag(EncoderSpeed?.some($0)) }
                }.labelsHidden().fixedSize()
            }
            GridRow {
                Text("Quality value")
                HStack {
                    Toggle("Manual", isOn: Binding(get: { settings.advanced.qualityValue != nil },
                                                   set: { settings.advanced.qualityValue = $0 ? 32 : nil })).toggleStyle(.checkbox)
                    if let v = settings.advanced.qualityValue {
                        TextField("", value: Binding(get: { v }, set: { settings.advanced.qualityValue = $0 }), format: .number)
                            .frame(width: 56).textFieldStyle(.roundedBorder)
                        Text("CRF for software encoders (lower = better), 1–100 for VideoToolbox (higher = better). Only used in quality mode.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            GridRow {
                Text("Frame rate")
                Picker("", selection: $settings.advanced.frameRateCap) {
                    Text("Same as source").tag(Double?.none)
                    ForEach([60.0, 50, 30, 25, 24], id: \.self) { Text("At most \(Int($0)) fps").tag(Double?.some($0)) }
                }.labelsHidden().fixedSize()
            }
            GridRow {
                Text("Keyframe interval")
                Picker("", selection: $settings.advanced.keyframeSeconds) {
                    Text("Automatic (10 s)").tag(Double?.none)
                    ForEach([1.0, 2, 5, 10, 20], id: \.self) { Text("\(Int($0)) s").tag(Double?.some($0)) }
                }.labelsHidden().fixedSize()
            }
            GridRow {
                Text("Bit depth")
                Picker("", selection: $settings.advanced.tenBit) {
                    ForEach(TenBitMode.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().fixedSize()
            }
            GridRow {
                Text("Film grain synthesis")
                Picker("", selection: $settings.advanced.filmGrain) {
                    Text("Automatic").tag(Bool?.none); Text("On").tag(Bool?.some(true)); Text("Off").tag(Bool?.some(false))
                }.labelsHidden().fixedSize()
            }
            GridRow {
                Text("Audio codec")
                Picker("", selection: $settings.advanced.audioCodec) {
                    ForEach(AudioCodecChoice.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().fixedSize()
            }
            GridRow {
                Text("Audio bitrate")
                Picker("", selection: $settings.advanced.audioBitrateKbps) {
                    Text("Automatic").tag(Int?.none)
                    ForEach([64, 96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag(Int?.some($0)) }
                }.labelsHidden().fixedSize()
            }
            GridRow {
                Text("Hardware acceleration")
                Toggle("Prefer the Apple media engine (fast, larger files)", isOn: $settings.advanced.preferHardware).toggleStyle(.checkbox)
            }
            GridRow {
                Text("Resolution")
                Toggle("Allow a lower resolution when it measurably looks better at the target size", isOn: $settings.advanced.allowLowerResolution).toggleStyle(.checkbox)
            }
            GridRow {
                Text("Quality check")
                Toggle("Measure VMAF of the finished video", isOn: $settings.measureQuality).toggleStyle(.checkbox)
            }
            GridRow {
                Text("Encoder parameters")
                TextField("e.g. enable-qm=1:qm-min=0", text: $settings.advanced.extraEncoderParams)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)).frame(maxWidth: 320)
            }
        }
        .font(.callout)
        HStack {
            Spacer()
            Button("Reset Advanced to Automatic") { settings.advanced = AdvancedSettings() }.buttonStyle(.link)
        }
    }
}
