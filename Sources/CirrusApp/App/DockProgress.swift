import AppKit

/// A slim progress bar across the bottom of the Dock icon while a batch runs.
@MainActor
final class DockProgress {
    static let shared = DockProgress()
    private var view: DockView?
    private var last: Double = -1

    func set(_ fraction: Double?) {
        let tile = NSApp.dockTile
        guard let f = fraction else {
            tile.contentView = nil; view = nil; last = -1; tile.display(); return
        }
        if view == nil {
            let v = DockView(frame: NSRect(origin: .zero, size: tile.size)); view = v; tile.contentView = v
        }
        let clamped = min(1, max(0, f))
        guard abs(clamped - last) >= 0.004 else { return }      // redraw at most ~250 times per batch
        last = clamped
        view?.fraction = clamped
        tile.display()
    }

    final class DockView: NSView {
        var fraction: Double = 0
        override func draw(_ dirty: NSRect) {
            NSApp.applicationIconImage?.draw(in: bounds)
            let inset = bounds.width * 0.14
            let track = NSRect(x: inset, y: bounds.height * 0.12, width: bounds.width - inset * 2, height: bounds.height * 0.085)
            let r = track.height / 2
            NSColor(white: 0, alpha: 0.45).setFill(); NSBezierPath(roundedRect: track, xRadius: r, yRadius: r).fill()
            var fill = track.insetBy(dx: 2, dy: 2); fill.size.width = max(fill.height, fill.width * fraction)
            NSColor(srgbRed: 0.949, green: 0.761, blue: 0.627, alpha: 1).setFill()
            NSBezierPath(roundedRect: fill, xRadius: fill.height / 2, yRadius: fill.height / 2).fill()
        }
    }
}
