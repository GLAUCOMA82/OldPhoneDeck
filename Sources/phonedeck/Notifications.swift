import AppKit
import ApplicationServices
import SQLite3

/// Mac notifications for the decks, from three sources:
///  1. Dock badges (WhatsApp "3", Mail "12"), read through Accessibility. No extra permission.
///  2. Notification Center history (title + body), read from usernoted's database.
///     macOS protects it: PhoneDeck needs Full Disk Access for this part.
///  3. Anything POSTed to /notify, for example a Claude Code hook when a task finishes.
final class Notifications {
    private let queue = DispatchQueue(label: "notifications")
    private var badges: [String: String] = [:]          // app path → badge label
    private var items: [[String: Any]] = []             // newest first
    private var seq = 0                                 // bumps on every new item
    private var lastRecord: Int64 = -1                  // highest usernoted rec_id seen
    private(set) var historyAccess = "unknown"          // "ok" | "denied" | "missing"
    private var timer: DispatchSourceTimer?

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 2)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    /// Respects the Command Center settings: notifications off, previews hidden, muted apps.
    func snapshot(limit: Int = 12) -> [String: Any] {
        let s = Layout.notificationSettings()
        return queue.sync {
            guard s.enabled else { return ["seq": seq, "items": [], "badges": [:], "access": historyAccess] }
            let shown = items.filter { !s.muted.contains($0["bundle"] as? String ?? "") }.prefix(limit).map { item -> [String: Any] in
                var i = item
                if !s.preview { i["body"] = ""; i["sub"] = "" }
                return i
            }
            return ["seq": seq, "items": Array(shown), "badges": s.badges ? badges : [:], "access": historyAccess]
        }
    }

    func push(app: String, title: String, body: String, bundle: String = "") {
        queue.async {
            let path = Notifications.appPath(bundle: bundle, name: app)
            self.add(["id": "push-\(Date().timeIntervalSince1970)", "app": app, "bundle": bundle, "path": path ?? "",
                      "title": title, "sub": "", "body": body, "at": Date().timeIntervalSince1970 * 1000])
        }
    }

    func clear() { queue.async { self.items = []; self.seq += 1 } }

    private func add(_ item: [String: Any]) {
        items.insert(item, at: 0)
        if items.count > 40 { items.removeLast(items.count - 40) }
        seq += 1
    }

    private func refresh() {
        badges = Notifications.dockBadges()
        readHistory()
    }

    // MARK: Dock badges (Accessibility)

    static func dockBadges() -> [String: String] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        var out: [String: String] = [:]
        for list in children(root) where string(list, kAXRoleAttribute) == "AXList" {
            for item in children(list) {
                guard let label = string(item, "AXStatusLabel"), !label.isEmpty else { continue }
                var url: CFTypeRef?
                if AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &url) == .success,
                   let u = url as? URL {
                    // Key by the path in our own app list (the Dock may report /System/Applications/…).
                    let name = (u.lastPathComponent as NSString).deletingPathExtension
                    out[appPath(bundle: "", name: name) ?? u.path] = label
                }
            }
        }
        return out
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return v as? [AXUIElement] ?? []
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    // MARK: Notification Center history (needs Full Disk Access)

    private static let databases = [NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2/db"]   // macOS 15+

    private func readHistory() {
        // Without Full Disk Access the open (or the first query) fails with "authorization denied".
        let path = Notifications.databases[0]
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            historyAccess = "denied"; sqlite3_close(db); return
        }
        defer { sqlite3_close(db) }
        let sql = "SELECT r.rec_id, a.identifier, r.data, r.delivered_date FROM record r JOIN app a ON a.app_id = r.app_id " +
                  "WHERE r.rec_id > ? ORDER BY r.rec_id DESC LIMIT 20"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("Notifications: \(String(cString: sqlite3_errmsg(db)))")
            historyAccess = "denied"; return   // unreadable file reports here, not at open
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, max(lastRecord, 0))
        historyAccess = "ok"
        var fresh: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rec = sqlite3_column_int64(stmt, 0)
            lastRecord = max(lastRecord, rec)
            let bundle = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let delivered = sqlite3_column_double(stmt, 3)
            guard let blob = sqlite3_column_blob(stmt, 2) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 2)))
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let req = plist["req"] as? [String: Any] else { continue }
            let path = Notifications.appPath(bundle: bundle, name: nil)
            let name = path.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? bundle
            fresh.append(["id": "nc-\(rec)", "app": name, "bundle": bundle, "path": path ?? "",
                          "title": req["titl"] as? String ?? "", "sub": req["subt"] as? String ?? "",
                          "body": req["body"] as? String ?? "",
                          "at": (delivered + 978_307_200) * 1000])   // Mac absolute time → Unix ms
        }
        if lastRecord < 0 { lastRecord = 0 }
        // On launch, load recent history quietly (oldest first so the newest ends on top).
        for item in fresh.reversed() { add(item) }
    }

    /// The app's path as it appears in Apps.list(), so the deck can show its icon.
    static func appPath(bundle: String, name: String?) -> String? {
        var url: URL?
        if !bundle.isEmpty { url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) }
        let all = Apps.list()
        if let url {
            let p = url.path
            if all.contains(where: { $0["path"] == p }) { return p }
            let n = (url.lastPathComponent as NSString).deletingPathExtension
            if let hit = all.first(where: { $0["name"] == n }) { return hit["path"] }
        }
        if let name, let hit = all.first(where: { $0["name"]?.caseInsensitiveCompare(name) == .orderedSame }) { return hit["path"] }
        return nil
    }
}
