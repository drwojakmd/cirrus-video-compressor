import SwiftUI
import AppKit
import CirrusCore

/// Cirrus palette ("Convergence"): high-altitude sky blues with a warm dawn
/// highlight used only for moments of arrival. Every colour adapts to dark mode.
enum Brand {
    /// Sky: the accent (buttons, selection, progress).
    static let accent = dynamic(light: (0.227, 0.416, 0.682), dark: (0.561, 0.714, 0.910))
    /// Dawn: arrival only (the convergence point, the "saved" figure).
    static let dawn = dynamic(light: (0.851, 0.557, 0.384), dark: (0.941, 0.698, 0.549))
    /// Altitude → sky, the icon's gradient.
    static let altitude = Color(red: 0.078, green: 0.161, blue: 0.302)
    static let sky = Color(red: 0.302, green: 0.490, blue: 0.722)
    static let haze = Color(red: 0.749, green: 0.827, blue: 0.918)
    static let dawnFixed = Color(red: 0.949, green: 0.761, blue: 0.627)
    static let gradient = LinearGradient(colors: [dynamic(light: (0.247, 0.447, 0.722), dark: (0.494, 0.651, 0.871)),
                                                  dynamic(light: (0.180, 0.341, 0.588), dark: (0.388, 0.553, 0.800))],
                                         startPoint: .top, endPoint: .bottom)
    static let skyGradient = LinearGradient(stops: [.init(color: altitude, location: 0), .init(color: sky, location: 0.5),
                                                    .init(color: haze, location: 0.82), .init(color: dawnFixed, location: 1)],
                                            startPoint: .top, endPoint: .bottom)
    static let good = Color(red: 0.20, green: 0.64, blue: 0.45)
    static let warn = Color.orange

    static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let c = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

/// The brand motif: cirrus streaks converging on one bright point.
/// `progress` 0…1 draws them toward the point; `drift` animates the idle state.
struct StreaksView: View {
    var progress: Double = 1
    var settled: Bool = false
    var drift: Bool = false
    var color: Color = .white
    var pointColor: Color? = nil
    var count = 6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !drift)) { tl in
            let t = drift ? tl.date.timeIntervalSinceReferenceDate : 0
            Canvas { ctx, size in
                let w = size.width, h = size.height
                let end = CGPoint(x: w * 0.94, y: h * 0.5)
                let p = max(0, min(1, progress))
                for i in 0..<count {
                    let f = count == 1 ? 0.5 : Double(i) / Double(count - 1)        // 0…1 across the bundle
                    let spread = settled ? 0.0 : 1.0
                    let y0 = h * (0.5 + (f - 0.5) * 0.86 * spread) + (drift ? sin(t * 0.35 + Double(i) * 1.3) * h * 0.025 : 0)
                    let centre = abs(f - 0.5) * 2                                      // 0 at the middle streak
                    var path = Path()
                    path.move(to: CGPoint(x: -w * 0.02, y: y0))
                    path.addCurve(to: CGPoint(x: end.x, y: end.y + (y0 - end.y) * 0.05),
                                  control1: CGPoint(x: w * 0.42, y: y0),
                                  control2: CGPoint(x: w * 0.66, y: end.y + (y0 - end.y) * 0.28))
                    let trimmed = path.trimmedPath(from: 0, to: p)
                    let lw = max(1, h * (0.045 - centre * 0.03))
                    let shading = GraphicsContext.Shading.linearGradient(
                        Gradient(colors: [color.opacity(0), color.opacity(0.55 - centre * 0.25), color.opacity(1 - centre * 0.45)]),
                        startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: end.x, y: 0))
                    ctx.stroke(trimmed, with: shading, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                }
                if p >= 0.999, let pc = pointColor {
                    let r = h * 0.07
                    ctx.fill(Path(ellipseIn: CGRect(x: end.x - r * 2.6, y: end.y - r * 2.6, width: r * 5.2, height: r * 5.2)), with: .color(pc.opacity(0.22)))
                    ctx.fill(Path(ellipseIn: CGRect(x: end.x - r, y: end.y - r, width: r * 2, height: r * 2)), with: .color(pc))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Progress as streaks converging toward the point, with a quiet track for what remains.
struct ConvergenceProgress: View {
    var fraction: Double
    var body: some View {
        ZStack {
            Capsule().fill(Brand.accent.opacity(0.08)).frame(height: 2).padding(.leading, 6)
            StreaksView(progress: fraction, color: Brand.accent, count: 5)
                .animation(.linear(duration: 0.25), value: fraction)
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

/// Rounded, softly outlined container used for every section of the detail pane.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

struct SectionLabel: View {
    var title: String
    var systemImage: String
    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }
}

struct Chip: View {
    var text: String
    var systemImage: String? = nil
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            if let s = systemImage { Image(systemName: s).imageScale(.small) }
            Text(text)
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 8).padding(.vertical, 3.5)
        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

/// Big number + caption, used in the result summary.
struct StatTile: View {
    var title: String
    var value: String
    var caption: String? = nil
    var tint: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(.secondary).kerning(0.4)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Selectable capsule for presets (target sizes, quality levels).
struct PillButton: View {
    var title: String
    var selected: Bool
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                .background(Capsule().fill(selected ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.secondary.opacity(hover ? 0.16 : 0.09))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

/// The primary call to action.
struct ProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 22).padding(.vertical, 10)
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(enabled ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.gray.opacity(0.35))))
            .shadow(color: Brand.accent.opacity(enabled ? 0.28 : 0), radius: configuration.isPressed ? 2 : 7, y: configuration.isPressed ? 1 : 3)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct InfoRow: View {
    var systemImage: String
    var text: String
    var tint: Color = .secondary
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint).frame(width: 16)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension QualityRating {
    var color: Color {
        switch self {
        case .excellent: return Brand.good
        case .veryGood: return Color(red: 0.35, green: 0.68, blue: 0.30)
        case .good: return .yellow
        case .fair: return .orange
        case .poor: return .red
        }
    }
}

extension Image {
    init(cgImage: CGImage) { self.init(decorative: cgImage, scale: 1) }
}
