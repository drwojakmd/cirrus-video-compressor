import SwiftUI

/// The empty state: a strip of sky with drifting cirrus streaks, and one clear action.
struct DropZoneView: View {
    @Environment(AppModel.self) private var model
    var isTargeted: Bool
    var browse: () -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 26) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Brand.skyGradient)
                StreaksView(progress: 1, settled: isTargeted, drift: !reduceMotion, color: .white, pointColor: isTargeted ? Brand.dawnFixed : .white)
                    .padding(.vertical, 26).padding(.leading, 0).padding(.trailing, 24)
                    .opacity(isTargeted ? 1 : 0.85)
                    .animation(.easeInOut(duration: 0.5), value: isTargeted)
            }
            .frame(maxWidth: 560).frame(height: 190)
            .shadow(color: Brand.altitude.opacity(0.25), radius: 18, y: 10)

            VStack(spacing: 8) {
                Text(isTargeted ? "Drop to add" : "Drop videos or folders")
                    .font(.system(size: 28, weight: .light))
                    .kerning(-0.3)
                Text("Folders are searched with all their subfolders. Cirrus’s own outputs are skipped.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Choose Videos…", action: browse)
                    .buttonStyle(ProminentButtonStyle())
                    .keyboardShortcut("o")
                PresetMenu(targets: nil, label: "Settings for new videos")
            }
            HStack(spacing: 22) {
                Feature(symbol: "wand.and.stars", text: "Analyses each video")
                Feature(symbol: "target", text: "Hits your file size")
                Feature(symbol: "text.viewfinder", text: "Keeps text readable")
                Feature(symbol: "eye", text: "Measures real quality")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(isTargeted ? Brand.accent : Color.secondary.opacity(hover ? 0.32 : 0.18),
                              style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 1, dash: isTargeted ? [] : [8, 7]))
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(isTargeted ? Brand.accent.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: browse)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }

    struct Feature: View {
        var symbol: String
        var text: String
        var body: some View {
            Label(text, systemImage: symbol).font(.callout).foregroundStyle(.secondary)
        }
    }
}
