import AppKit
import SQLite3

/// WhatsApp for Mac: recent chats and messages from its local database (read-only), and replies.
/// A reply to a chat with a known phone number goes through WhatsApp's own send link and is sent;
/// for groups and contacts without a number there is no safe way to target the chat, so the reply
/// is copied and WhatsApp is opened instead (never risk sending to the wrong chat).
final class WhatsApp {
    static let bundleID = "net.whatsapp.WhatsApp"
    private let dir = NSHomeDirectory() + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"
    private let queue = DispatchQueue(label: "whatsapp")
    private(set) var access = "unknown"   // ok | denied | missing
    private var cache: (at: Date, limit: Int, value: [[String: Any]])?

    private static let epoch = 978_307_200.0   // Mac absolute time → Unix
    /// SQLite returns whole-second dates as INTEGER and others as REAL.
    private static func num(_ v: Any?) -> Double { (v as? Double) ?? Double(v as? Int ?? 0) }
    private static func ms(_ v: Any?) -> Double { (num(v) + epoch) * 1000 }
    /// Preview text for a message; WhatsApp sometimes stores encoded data instead of text.
    static func preview(_ text: String?, type: Int) -> String {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return label(type) }
        let encoded = t.count > 30 && !t.contains(" ") && t.range(of: "^[A-Za-z0-9+/=_-]+$", options: .regularExpression) != nil
        return encoded ? label(type) : t
    }

    // MARK: reading

    private func open() -> OpaquePointer? {
        let path = dir + "/ChatStorage.sqlite"
        guard FileManager.default.fileExists(atPath: path) || access == "unknown" else { access = "missing"; return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            print("WhatsApp: open failed: \(String(cString: sqlite3_errmsg(db)))")
            access = "denied"; sqlite3_close(db); return nil
        }
        // contacts database maps WhatsApp's hidden "@lid" ids to phone numbers when it knows them
        sqlite3_exec(db, "ATTACH 'file:\(dir)/ContactsV2.sqlite?mode=ro' AS ct", nil, nil, nil)
        return db
    }

    private func rows(_ db: OpaquePointer, _ sql: String, _ bind: [Any] = []) -> [[Any?]]? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("WhatsApp: \(String(cString: sqlite3_errmsg(db)))")
            access = "denied"; return nil
        }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in bind.enumerated() {
            if let n = v as? Int { sqlite3_bind_int64(stmt, Int32(i + 1), Int64(n)) }
        }
        var out: [[Any?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var r: [Any?] = []
            for c in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: r.append(Int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT: r.append(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: r.append(String(cString: sqlite3_column_text(stmt, c)))
                default: r.append(nil)
                }
            }
            out.append(r)
        }
        access = "ok"
        return out
    }

    func chats(limit: Int) -> [String: Any] {
        queue.sync {
            if let c = cache, Date().timeIntervalSince(c.at) < 2, c.limit >= limit { return ["access": access, "chats": Array(c.value.prefix(limit))] }
            guard let db = open() else { return ["access": access, "chats": []] }
            defer { sqlite3_close(db) }
            let sql = """
                SELECT c.Z_PK, c.ZPARTNERNAME, c.ZCONTACTJID, c.ZLASTMESSAGETEXT, c.ZLASTMESSAGEDATE, c.ZUNREADCOUNT, c.ZSESSIONTYPE,
                       (SELECT a.ZPHONENUMBER FROM ct.ZWAADDRESSBOOKCONTACT a WHERE a.ZLID = c.ZCONTACTJID OR a.ZLID || '@lid' = c.ZCONTACTJID LIMIT 1),
                       (SELECT m.ZISFROMME FROM ZWAMESSAGE m WHERE m.Z_PK = c.ZLASTMESSAGE),
                       (SELECT m.ZTEXT FROM ZWAMESSAGE m WHERE m.Z_PK = c.ZLASTMESSAGE),
                       (SELECT m.ZMESSAGETYPE FROM ZWAMESSAGE m WHERE m.Z_PK = c.ZLASTMESSAGE)
                FROM ZWACHATSESSION c
                WHERE IFNULL(c.ZHIDDEN,0) = 0 AND IFNULL(c.ZREMOVED,0) = 0 AND IFNULL(c.ZARCHIVED,0) = 0
                  AND c.ZLASTMESSAGEDATE IS NOT NULL AND c.ZCONTACTJID NOT LIKE '%@status' AND c.ZCONTACTJID NOT LIKE '%@broadcast'
                ORDER BY c.ZLASTMESSAGEDATE DESC LIMIT ?
                """
            let fixed = (rows(db, sql, [max(limit, 12)]) ?? []).map { r -> [String: Any] in
                let jid = r[2] as? String ?? ""
                return ["id": r[0] as? Int ?? 0, "name": r[1] as? String ?? "WhatsApp", "group": jid.hasSuffix("@g.us"),
                        "text": WhatsApp.preview((r[9] as? String) ?? (r[3] as? String), type: r[10] as? Int ?? 0), "at": WhatsApp.ms(r[4]),
                        "unread": max(0, r[5] as? Int ?? 0), "fromMe": (r[8] as? Int ?? 0) == 1,
                        "canSend": WhatsApp.phone(jid: jid, mapped: r[7] as? String) != nil]
            }
            cache = (Date(), max(limit, 12), fixed)
            return ["access": access, "chats": Array(fixed.prefix(limit))]
        }
    }

    func messages(chat: Int, limit: Int = 30) -> [String: Any] {
        queue.sync {
            guard let db = open() else { return ["access": access, "messages": []] }
            defer { sqlite3_close(db) }
            let info = rows(db, "SELECT ZPARTNERNAME, ZCONTACTJID FROM ZWACHATSESSION WHERE Z_PK = ?", [chat])?.first
            let sql = """
                SELECT m.ZISFROMME, m.ZTEXT, m.ZMESSAGEDATE, m.ZPUSHNAME, m.ZMESSAGETYPE,
                       (SELECT g.ZCONTACTNAME FROM ZWAGROUPMEMBER g WHERE g.Z_PK = m.ZGROUPMEMBER)
                FROM ZWAMESSAGE m WHERE m.ZCHATSESSION = ? AND m.ZMESSAGETYPE NOT IN (6, 10, 59, 66)   -- system rows (group events, security notices)
                ORDER BY m.ZMESSAGEDATE DESC LIMIT ?
                """
            let msgs = (rows(db, sql, [chat, limit]) ?? []).reversed().map { r -> [String: Any] in
                let type = r[4] as? Int ?? 0
                let text = WhatsApp.preview(r[1] as? String, type: type)
                return ["me": (r[0] as? Int ?? 0) == 1, "text": text, "media": type != 0,
                        "at": WhatsApp.ms(r[2]),
                        "from": (r[5] as? String) ?? (r[3] as? String) ?? ""]
            }
            let jid = info?[1] as? String ?? ""
            return ["access": access, "name": info?[0] as? String ?? "", "group": jid.hasSuffix("@g.us"),
                    "canSend": WhatsApp.phone(jid: jid, mapped: phoneFor(db, jid)) != nil, "messages": msgs]
        }
    }

    private func phoneFor(_ db: OpaquePointer, _ jid: String) -> String? {
        guard jid.hasSuffix("@lid") else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ZPHONENUMBER FROM ct.ZWAADDRESSBOOKCONTACT WHERE ZLID = ?1 OR ZLID || '@lid' = ?1 LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, jid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_text(stmt, 0).map { String(cString: $0) } : nil
    }

    /// Digits for WhatsApp's send link, or nil (groups, unknown hidden ids).
    static func phone(jid: String, mapped: String?) -> String? {
        if jid.hasSuffix("@s.whatsapp.net") { return String(jid.prefix { $0 != "@" }) }
        if jid.hasSuffix("@lid"), let m = mapped {
            let digits = m.filter(\.isNumber)
            return digits.count >= 6 ? digits : nil
        }
        return nil
    }

    static func label(_ type: Int) -> String {
        switch type {
        case 1: return "Photo"
        case 2: return "Video"
        case 3: return "Voice message"
        case 4: return "Contact"
        case 5: return "Location"
        case 7: return "Link"
        case 8: return "Document"
        case 11: return "GIF"
        case 14, 15: return "Sticker"
        default: return "Message"
        }
    }

    // MARK: replying

    /// "sent" (via WhatsApp's send link + Return), "copied" (WhatsApp opened, reply on the clipboard) or "failed".
    func reply(chat: Int, text: String) -> String {
        let (jid, phone): (String, String?) = queue.sync {
            guard let db = open() else { return ("", nil) }
            defer { sqlite3_close(db) }
            let j = rows(db, "SELECT ZCONTACTJID FROM ZWACHATSESSION WHERE Z_PK = ?", [chat])?.first?.first as? String ?? ""
            return (j, WhatsApp.phone(jid: j, mapped: phoneFor(db, j)))
        }
        guard !jid.isEmpty else { return "failed" }
        if let phone {
            var c = URLComponents(); c.scheme = "whatsapp"; c.host = "send"
            c.queryItems = [URLQueryItem(name: "phone", value: phone), URLQueryItem(name: "text", value: text)]
            guard let url = c.url else { return "failed" }
            DispatchQueue.main.sync { _ = NSWorkspace.shared.open(url) }
            // Press Return once WhatsApp shows the chat with the reply in its message field.
            Thread.sleep(forTimeInterval: 1.6)
            let front = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
            guard front == WhatsApp.bundleID else { return "copied" }
            DispatchQueue.main.sync { Input.key("return") }
            cache = nil
            return "sent"
        }
        DispatchQueue.main.sync {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: WhatsApp.bundleID) {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        return "copied"
    }
}
