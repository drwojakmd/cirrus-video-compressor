import SwiftUI
import AppKit
import CirrusCore

/// Choose a preset. `targets` nil = settings for videos added from now on;
/// otherwise the preset is applied to those videos too.
struct PresetMenu: View {
    @Environment(AppModel.self) private var model
    var targets: [QueueItem]?
    var label: String = "Preset"
    var saveFrom: CompressionSettings? = nil

    var body: some View {
        Menu {
            Section(targets == nil ? "Settings for new videos" : "Apply a preset") {
                ForEach(model.prefs.allPresets) { p in
                    Button {
                        if let t = targets { model.apply(p, to: t) }
                        else { model.prefs.settings = p.settings; model.prefs.selectedPresetID = p.id; model.prefs.save() }
                    } label: {
                        Text(p.name) + Text("  \(p.subtitle)").foregroundColor(.secondary)
                    }
                }
            }
            Divider()
            Button("Save Current Settings as Preset…") { promptSave() }
            if let t = targets?.first, t.hasVersions {
                Button("Save These \(t.versions.count) Versions as a Set…") { promptSave(versions: t.versions.map(\.settings)) }
            }
            if !model.prefs.presets.isEmpty {
                Menu("Delete Preset") {
                    ForEach(model.prefs.presets) { p in Button(p.name, role: .destructive) { model.deletePreset(p) } }
                }
            }
        } label: {
            Label(currentName.map { "\(label): \($0)" } ?? label, systemImage: "slider.horizontal.3")
        }
        .fixedSize()
        .help("Presets are named combinations of settings, e.g. one for lectures and one for YouTube uploads.")
    }

    var currentName: String? {
        guard let id = model.prefs.selectedPresetID, let p = model.prefs.allPresets.first(where: { $0.id == id }) else { return nil }
        let current = targets?.first?.settings ?? model.prefs.settings
        var a = current; a.advanced.profile = nil
        return a == p.settings ? p.name : nil
    }

    func promptSave(versions: [CompressionSettings]? = nil) {
        let alert = NSAlert()
        alert.messageText = versions == nil ? "Save settings as a preset" : "Save \(versions!.count) versions as a set"
        alert.informativeText = "Give these settings a name, like “Lecture archive” or “Client delivery”."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Preset name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.savePreset(named: name, from: versions?.first ?? saveFrom ?? targets?.first?.settings ?? model.prefs.settings, versions: versions)
    }
}
