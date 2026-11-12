import Foundation
import CirrusCore

/// Ready-made versions offered under "Add Version".
enum QuickAdd: String, CaseIterable, Identifiable {
    case email, discord, whatsapp, webSet, everyFormat
    var id: String { rawValue }

    var title: String {
        switch self {
        case .email: return "Fit for email (18 MB, fits Gmail and Outlook)"
        case .discord: return "Fit for Discord (10 MB)"
        case .whatsapp: return "Fit for WhatsApp (16 MB)"
        case .webSet: return "Web set: 1080p, 720p and 480p"
        case .everyFormat: return "One of each format: AV1, HEVC and H.264"
        }
    }
    var symbol: String {
        switch self {
        case .email: return "envelope"
        case .discord: return "bubble.left.and.bubble.right"
        case .whatsapp: return "message"
        case .webSet: return "rectangle.stack"
        case .everyFormat: return "square.stack.3d.up"
        }
    }
    var limit: Int64? {
        switch self {
        case .email: return 18_000_000
        case .discord: return 10_000_000
        case .whatsapp: return 16_000_000
        default: return nil
        }
    }
    var purpose: String? {
        switch self {
        case .email: return "Email"
        case .discord: return "Discord"
        case .whatsapp: return "WhatsApp"
        default: return nil
        }
    }
}

@MainActor
extension QueueItem {
    /// Settings a quick add would create, or why it can't (already small enough, too long to fit).
    func quickAdd(_ q: QuickAdd, engine: CompressionEngine?) -> (settings: [CompressionSettings], problem: String?) {
        guard let engine, let source else { return ([], "Waiting for the video to be analysed") }
        let media = source.media
        let base = settings
        let short = media.displaySize.shortSide
        let mac = engine.caps.systemDecodesAV1
        switch q {
        case .email, .discord, .whatsapp:
            let limit = q.limit!
            if media.fileSize <= limit { return ([], "Already under \(Fmt.bytes(limit))") }
            // a size limit for sharing: H.264 plays on every phone, PC and chat app;
            // the largest resolution that fits without a "very tight" warning wins.
            var s = base
            FormatChoice.h264.apply(to: &s, macDecodesAV1: mac)
            s.goal = .targetSize(bytes: limit)   // the engine re-encodes if a result comes out over
            s.minimumSavings = 0
            let ladder: [OutputResolution] = [.fhd1080, .hd720, .sd480].filter { ($0.box?.shortSide ?? 0) <= short }
            var fallback: CompressionSettings?
            for r in (ladder.isEmpty ? [.original] : ladder) {
                let c = s.with { $0.resolution = r }
                guard let plan = try? engine.plan(source, settings: c) else { continue }
                if plan.warnings.isEmpty { return ([c], nil) }
                if fallback == nil || !plan.warnings.contains(where: { $0.contains("very tight") }) { fallback = c }
            }
            if let f = fallback { return ([f], nil) }
            return ([], "\(Fmt.duration(media.duration)) is too long to fit in \(Fmt.bytes(limit)) and still be watchable")
        case .webSet:
            let list = [OutputResolution.fhd1080, .hd720, .sd480].filter { ($0.box?.shortSide ?? 0) <= short }.map { r in base.with { $0.resolution = r } }
            let fresh = list.filter { c in !versions.contains { sameOutput($0.settings, c) } }
            return fresh.isEmpty ? ([], short < 480 ? "The video is smaller than 480p" : "Already in the list") : (fresh, nil)
        case .everyFormat:
            let list = [FormatChoice.av1, .hevc, .h264].map { f in base.with { f.apply(to: &$0, macDecodesAV1: mac) } }
            let fresh = list.filter { c in !versions.contains { sameOutput($0.settings, c) } }
            return fresh.isEmpty ? ([], "Already in the list") : (fresh, nil)
        }
    }

    /// Two settings that would make the same file, e.g. "1080p" and "Original size" on a 1080p video.
    func sameOutput(_ a: CompressionSettings, _ b: CompressionSettings) -> Bool {
        func norm(_ s: CompressionSettings) -> CompressionSettings {
            var s = s
            if let short = source?.media.displaySize.shortSide, let box = s.resolution.box, box.shortSide >= short { s.resolution = .original }
            return s
        }
        return norm(a) == norm(b)
    }

    // MARK: what sets versions apart

    enum Aspect: CaseIterable { case format, goal, resolution, textGuard, audio }

    func aspect(_ a: Aspect, of s: CompressionSettings, mac: Bool) -> String {
        switch a {
        case .format: return FormatChoice.of(s, macDecodesAV1: mac).title
        case .goal:
            switch s.goal {
            case .quality(let l): return l.label.replacingOccurrences(of: " Quality", with: "")
            case .targetSize(let b): return "Under \(Fmt.bytes(b))"
            }
        case .resolution:
            if s.resolution == .original { return "Original size" }
            return s.resolution.label.replacingOccurrences(of: "4K (2160p)", with: "4K")
        case .textGuard:
            switch s.textGuard { case .on: return "Text guard on"; case .off: return "Text guard off"; case .automatic: return "Text guard auto" }
        case .audio: return "Audio: \(s.audio.rawValue)"
        }
    }

    /// The parts of a version's settings that differ between versions (all of format,
    /// goal and resolution when there's only one).
    func differences(_ v: OutputVersion, mac: Bool) -> (distinct: [String], shared: [String]) {
        var distinct: [String] = [], shared: [String] = []
        for a in Aspect.allCases {
            let mine = aspect(a, of: v.settings, mac: mac)
            let varies = Set(versions.map { aspect(a, of: $0.settings, mac: mac) }).count > 1
            if varies { distinct.append(mine) }
            else if [.format, .goal, .resolution].contains(a) { shared.append(mine) }
        }
        if distinct.isEmpty { return (shared, []) }
        return (distinct, shared)
    }

    // MARK: warnings

    struct VersionWarning: Identifiable {
        var id: OutputVersion.ID { version.id }
        var version: OutputVersion
        var text: String
    }

    /// Versions that are pointless: the same as another, or bigger than another with no better picture.
    func versionWarnings(engine: CompressionEngine?) -> [VersionWarning] {
        guard versions.count > 1 else { return [] }
        let mac = engine?.caps.systemDecodesAV1 ?? false
        var out: [VersionWarning] = []
        let editable = versions.filter(\.isEditable)
        for (j, b) in versions.enumerated() where b.isEditable {
            if let a = versions[..<j].first(where: { sameOutput($0.settings, b.settings) }) {
                out.append(.init(version: b, text: "\(letter(b)) is the same as \(letter(a)), so it would make an identical file."))
                continue
            }
            guard case .quality(let lb) = b.settings.goal, let eb = estimate(for: b.settings, engine: engine) else { continue }
            for a in editable where a.id != b.id {
                guard case .quality(let la) = a.settings.goal, let ea = estimate(for: a.settings, engine: engine) else { continue }
                let notSharper = eb.outputSize.pixels <= ea.outputSize.pixels
                let notBetter = lb.rawValue >= la.rawValue
                let noTextEdge = !(b.settings.textGuard == .on && a.settings.textGuard != .on)
                let noPlaybackEdge = !(eb.previewable && !ea.previewable)
                if notSharper && notBetter && noTextEdge && noPlaybackEdge && Double(eb.bytes) > Double(ea.bytes) * 1.08 {
                    out.append(.init(version: b, text: "\(letter(b)) (\(b.settings.versionLabel(macDecodesAV1: mac))) would be about \(Fmt.bytes(eb.bytes)): bigger than \(letter(a)) (\(a.settings.versionLabel(macDecodesAV1: mac)), about \(Fmt.bytes(ea.bytes))), and \(letter(a)) looks the same or better."))
                    break
                }
            }
        }
        return out
    }

    /// Estimated total size and time of the versions still to make (nil while measuring).
    func pendingTotals(engine: CompressionEngine?) -> (bytes: Int64, seconds: Double)? {
        var b: Int64 = 0, t = 0.0
        for v in pendingVersions {
            guard let e = estimate(for: v.settings, engine: engine) else { return nil }
            b += e.bytes; t += e.seconds
        }
        return (b, t)
    }
}
