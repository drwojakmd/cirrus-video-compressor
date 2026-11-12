import SwiftUI
import CirrusCore

struct PreferencesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Output") {
                Picker("Save compressed videos", selection: $model.prefs.outputMode) {
                    Text("Next to the original").tag(Preferences.OutputMode.sameAsSource)
                    Text(model.prefs.outputFolder.map { "In \($0.lastPathComponent)" } ?? "In a chosen folder").tag(Preferences.OutputMode.folder)
                    Text("In place of the original (original to Trash)").tag(Preferences.OutputMode.replaceOriginals)
                }
                if model.prefs.outputMode == .replaceOriginals {
                    ExplanationView(explanation: Explain.replaceOriginals)
                }
                if model.prefs.outputMode == .folder {
                    Button("Choose Folder…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                        if p.runModal() == .OK { model.prefs.outputFolder = p.url }
                    }
                }
                Toggle("Notify me when a video finishes", isOn: $model.prefs.notifyWhenDone)
            }
            Section("Engine") {
                if let e = model.engine {
                    LabeledContent("FFmpeg", value: e.caps.version.replacingOccurrences(of: "ffmpeg version ", with: ""))
                    LabeledContent("Encoders", value: EncoderID.allCases.filter { EncoderRegistry.encoder($0).isAvailable(e.caps) }.map(\.rawValue).joined(separator: ", "))
                    LabeledContent("Quality metric", value: e.caps.hasVMAF ? "VMAF available" : "VMAF not available")
                    LabeledContent("Location", value: e.tools.ffmpeg.deletingLastPathComponent().path)
                } else {
                    Text("Starting…").foregroundStyle(.secondary)
                }
                Button("Show Engine Log") { model.revealLog() }
            }
            Section("Defaults") {
                Button("Reset All Settings to Defaults") { model.prefs.settings = CompressionSettings() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 480)
        .onChange(of: model.prefs.outputMode) { model.prefs.save() }
        .onChange(of: model.prefs.notifyWhenDone) { model.prefs.save() }
        .onChange(of: model.prefs.outputFolder) { model.prefs.save() }
    }
}
