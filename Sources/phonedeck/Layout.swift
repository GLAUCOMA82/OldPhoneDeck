import Foundation

/// The Command Center's layout: pages, widgets and settings for every deck, stored on the Mac
/// so the 4S, the iPhone 17 and the iPad all follow it. The structure is owned by the web code
/// (deck.js); the server only stores it, versions it, and reads the notification settings.
enum Layout {
    static let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".phonedeck/layout.json")
    private static let lock = NSLock()
    private static var cache: (data: Data, json: [String: Any])?

    /// Changes whenever the layout is saved; decks poll it and re-render.
    static var version: Double {
        let date = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        return (date?.timeIntervalSince1970 ?? 0) * 1000
    }

    static func load() -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c.data }
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        cache = (data, json)
        return data
    }

    static func save(_ data: Data) throws {
        guard data.count < 512 * 1024,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["devices"] is [String: Any] else {
            throw NSError(domain: "Layout", code: 1, userInfo: [NSLocalizedDescriptionKey: "not a PhoneDeck layout"])
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        lock.lock(); defer { lock.unlock() }
        try data.write(to: file, options: .atomic)
        cache = (data, json)
    }

    private static var json: [String: Any] {
        _ = load()
        lock.lock(); defer { lock.unlock() }
        return cache?.json ?? [:]
    }

    struct NotificationSettings { var enabled = true, preview = true, badges = true, muted: Set<String> = [] }

    static func notificationSettings() -> NotificationSettings {
        var s = NotificationSettings()
        guard let n = json["notifications"] as? [String: Any] else { return s }
        s.enabled = n["enabled"] as? Bool ?? true
        s.preview = n["preview"] as? Bool ?? true
        s.badges = n["badges"] as? Bool ?? true
        s.muted = Set(n["muted"] as? [String] ?? [])
        return s
    }

    /// The name of page `index` on a deck ("classic", "phone", "tablet"), for the menu bar.
    static func pageName(device: String, index: Int) -> String? {
        let pages = ((json["devices"] as? [String: Any])?[device] as? [String: Any])?["pages"] as? [[String: Any]] ?? []
        return pages.indices.contains(index) ? pages[index]["name"] as? String : nil
    }

    /// Shortcut names the layout attaches to pages ("turn on this Focus when the page opens").
    /// Only these may be run from a deck.
    static func pageShortcuts() -> Set<String> {
        var names = Set<String>()
        for case let device as [String: Any] in (json["devices"] as? [String: Any] ?? [:]).values {
            for case let page as [String: Any] in device["pages"] as? [Any] ?? [] {
                if let s = page["shortcut"] as? String, !s.isEmpty { names.insert(s) }
            }
        }
        return names
    }
}
