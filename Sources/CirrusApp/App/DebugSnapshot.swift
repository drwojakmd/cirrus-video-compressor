import AppKit
import SwiftUI
import CirrusCore

/// Developer aid: `CIRRUS_SNAPSHOT=/path/prefix` makes the app render its own main
/// window to PNG files (no Screen Recording permission needed, since it draws
/// its own views). `CIRRUS_OPEN=/path/video` adds a video at launch.
/// `CIRRUS_SNAPSHOT_DELAYS=3,20` sets the capture times in seconds.
enum DebugSnapshot {
    @MainActor static func scheduleIfRequested(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if let open = env["CIRRUS_OPEN"] { model.add(urls: open.split(separator: ",").map { URL(fileURLWithPath: String($0)) }) }
        if env["CIRRUS_AUTOCOMPRESS"] != nil {
            // wait for analysis, then press "Compress" through the model, like the button does
            Task { @MainActor in
                while model.selected?.source == nil { try? await Task.sleep(nanoseconds: 300_000_000) }
                if let item = model.selected, let adds = env["CIRRUS_ADD_VERSIONS"] {
                    for q in adds.split(separator: ",").compactMap({ QuickAdd(rawValue: String($0)) }) {
                        for s in item.quickAdd(q, engine: model.engine).settings { model.addVersion(to: item, settings: s, purpose: q.purpose) }
                    }
                }
                model.compressSelected()
            }
        }
        if let out = env["CIRRUS_RENDER_DETAIL"] { renderDetail(model: model, to: out, after: Double(env["CIRRUS_SNAPSHOT_DELAYS"] ?? "10") ?? 10) }
        guard let prefix = env["CIRRUS_SNAPSHOT"] else { return }
        let delays = (env["CIRRUS_SNAPSHOT_DELAYS"] ?? "4").split(separator: ",").compactMap { Double($0) }
        for (i, d) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                guard let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                      let view = win.contentView?.superview ?? win.contentView else { return }
                // Render the layer tree (captures layer-backed SwiftUI content that cacheDisplay misses).
                let scale = win.backingScaleFactor
                let size = view.bounds.size
                if let layer = view.layer,
                   let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                       bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
                    ctx.setFillColor(NSColor.windowBackgroundColor.cgColor); ctx.fill(CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
                    ctx.scaleBy(x: scale, y: scale)
                    if !view.isFlipped { } 
                    layer.render(in: ctx)
                    if let img = ctx.makeImage() {
                        let rep = NSBitmapImageRep(cgImage: img)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(i).png"))
                    }
                }
                if env["CIRRUS_SNAPSHOT_COMPRESS"] != nil, i == 0 { model.compressSelected() }
                if i == delays.count - 1 && env["CIRRUS_SNAPSHOT_QUIT"] != nil { NSApp.terminate(nil) }
            }
        }
    }

    /// Offscreen SwiftUI render of the selected item's detail pane (layout review).
    @MainActor static func renderDetail(model: AppModel, to path: String, after delay: Double) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            // if a job is running, wait for it to finish so the result card is rendered
            while model.selected?.isActive == true { try? await Task.sleep(nanoseconds: 500_000_000) }
            guard let item = model.selected else { NSApp.terminate(nil); return }
            // CIRRUS_ADD_VERSIONS=webSet,email: apply ready-made versions first
            if let adds = ProcessInfo.processInfo.environment["CIRRUS_ADD_VERSIONS"], ProcessInfo.processInfo.environment["CIRRUS_AUTOCOMPRESS"] == nil {
                for q in adds.split(separator: ",").compactMap({ QuickAdd(rawValue: String($0)) }) {
                    for s in item.quickAdd(q, engine: model.engine).settings { model.addVersion(to: item, settings: s, purpose: q.purpose) }
                }
                if let sel = ProcessInfo.processInfo.environment["CIRRUS_SELECT_VERSION"], let i = Int(sel), i < item.versions.count {
                    item.selectedVersionID = item.versions[i].id
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let view = ItemDetailContent(item: item, compare: .constant(nil))
                .environment(model).frame(width: 940).background(Color(nsColor: .windowBackgroundColor))
            let r = ImageRenderer(content: view); r.scale = 2
            if let img = r.cgImage {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
}
