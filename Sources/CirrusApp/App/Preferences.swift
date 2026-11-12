import Foundation
import UserNotifications
import CirrusCore

/// Named, reusable settings.
struct Preset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var settings: CompressionSettings
    var builtIn = false
    /// A set of versions to make of each video (nil = one version, `settings`).
    var versions: [CompressionSettings]?

    static let builtIns: [Preset] = {
        var lecture = CompressionSettings()
        lecture.resolution = .fhd1080; lecture.goal = .quality(.balanced); lecture.textGuard = .on; lecture.previewableOnThisMac = true
        var youtube = CompressionSettings()
        youtube.goal = .quality(.high); youtube.previewableOnThisMac = false; youtube.textGuard = .automatic
        var smallest = CompressionSettings()
        smallest.goal = .quality(.aggressive); smallest.previewableOnThisMac = false
        var share = CompressionSettings()
        share.resolution = .fhd1080; share.priority = .appleDevices; share.goal = .quality(.balanced)
        return [
            Preset(id: UUID(uuidString: "6C1B7B52-0000-4000-8000-000000000001")!, name: "Lecture archive", settings: lecture, builtIn: true),
            Preset(id: UUID(uuidString: "6C1B7B52-0000-4000-8000-000000000002")!, name: "YouTube upload", settings: youtube, builtIn: true),
            Preset(id: UUID(uuidString: "6C1B7B52-0000-4000-8000-000000000003")!, name: "Smallest possible", settings: smallest, builtIn: true),
            Preset(id: UUID(uuidString: "6C1B7B52-0000-4000-8000-000000000004")!, name: "Share with Apple devices", settings: share, builtIn: true),
        ]
    }()

    /// One line describing what the preset does.
    var subtitle: String {
        if let v = versions, v.count > 1 {
            return "\(v.count) versions: " + v.map { $0.versionLabel(macDecodesAV1: false) }.joined(separator: " / ")
        }
        var parts: [String] = []
        parts.append(settings.resolution == .original ? "Original size" : settings.resolution.label)
        switch settings.goal {
        case .quality(let l): parts.append(l.label)
        case .targetSize(let b): parts.append("≤ \(Fmt.bytes(b))")
        }
        if settings.textGuard == .on { parts.append("text kept readable") }
        parts.append(settings.priority == .smallestFile ? (settings.previewableOnThisMac ? "Finder-previewable" : "smallest format") : settings.priority.rawValue)
        return parts.joined(separator: " · ")
    }
}

/// Remembered between launches (UserDefaults, JSON-encoded).
struct Preferences: Codable {
    enum OutputMode: String, Codable {
        case sameAsSource, folder
        /// Compressed copies replace the originals, which go to the Trash.
        case replaceOriginals
    }

    var settings = CompressionSettings()
    var outputMode: OutputMode = .sameAsSource
    var outputFolder: URL?
    var notifyWhenDone = true
    var showAdvanced = false
    var presets: [Preset] = []
    var selectedPresetID: UUID?
    /// Space saved by every compression so far (shown in the sidebar).
    var totalSavedBytes: Int64 = 0
    /// With several versions of a video, put them in a "<name> versions" folder.
    var versionsInOwnFolder = false

    var allPresets: [Preset] { Preset.builtIns + presets }

    private static let key = "CirrusPreferences.v1"

    init() {}
    enum CodingKeys: String, CodingKey { case settings, outputMode, outputFolder, notifyWhenDone, showAdvanced, presets, selectedPresetID, totalSavedBytes, versionsInOwnFolder }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        settings = (try? c.decode(CompressionSettings.self, forKey: .settings)) ?? CompressionSettings()
        outputMode = (try? c.decode(OutputMode.self, forKey: .outputMode)) ?? .sameAsSource
        outputFolder = try? c.decode(URL.self, forKey: .outputFolder)
        notifyWhenDone = (try? c.decode(Bool.self, forKey: .notifyWhenDone)) ?? true
        showAdvanced = (try? c.decode(Bool.self, forKey: .showAdvanced)) ?? false
        presets = (try? c.decode([Preset].self, forKey: .presets)) ?? []
        selectedPresetID = try? c.decode(UUID.self, forKey: .selectedPresetID)
        totalSavedBytes = (try? c.decode(Int64.self, forKey: .totalSavedBytes)) ?? 0
        versionsInOwnFolder = (try? c.decode(Bool.self, forKey: .versionsInOwnFolder)) ?? false
    }

    static func load() -> Preferences {
        guard let d = UserDefaults.standard.data(forKey: key), let p = try? JSONDecoder().decode(Preferences.self, from: d) else { return Preferences() }
        return p
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

/// The queue as it was, so a batch survives quitting, a crash or a restart.
struct SavedQueue: Codable {
    struct Entry: Codable { var url: URL; var settings: CompressionSettings; var pending: Bool }
    var entries: [Entry]
    var outputMode: Preferences.OutputMode

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cirrus Video Compressor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Queue.json")
    }
    static func load() -> SavedQueue? {
        guard let d = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SavedQueue.self, from: d)
    }
    func save() { if let d = try? JSONEncoder().encode(self) { try? d.write(to: Self.fileURL, options: .atomic) } }
    static func clear() { try? FileManager.default.removeItem(at: fileURL) }
}

enum Notifier {
    /// Notifications need a real app bundle (not available under `swift run`).
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func notify(_ r: CompressionResult) {
        post(title: "Compression finished",
             body: "\(r.outputURL.lastPathComponent): \(Fmt.bytes(r.outputBytes)), \(Int((r.reduction * 100).rounded()))% smaller")
    }
    static func post(title: String, body: String) {
        guard available else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
