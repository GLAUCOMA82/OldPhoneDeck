import Foundation
import Network

/// Who may connect and what a request may do, decided before its body is read.
///
/// Two tokens, both in ~/.oldphonedeck:
///   token       full access. Refused on plain HTTP unless the request comes from this Mac (OBS on localhost).
///   token-http  for old iPhones that can only use plain HTTP: it opens only `Access.plainHTTPRoutes`
///               (apps, playback, stats). Whoever sniffs it off the Wi-Fi gets that much and no more.
enum Access {

    // MARK: Source addresses

    /// A network in CIDR form, IPv4 or IPv6 (IPv4-mapped IPv6 addresses are compared as IPv4).
    struct CIDR: CustomStringConvertible {
        let bytes: [UInt8]
        let prefix: Int
        let description: String

        init?(_ s: String) {
            let parts = s.split(separator: "/", maxSplits: 1).map(String.init)
            guard let addr = parts.first, let raw = Access.rawAddress(addr) else { return nil }
            let max = raw.count * 8
            let p = parts.count == 2 ? Int(parts[1]) : max
            guard let p, p >= 0, p <= max else { return nil }
            bytes = raw; prefix = p; description = s
        }

        func contains(_ ip: [UInt8]) -> Bool {
            guard ip.count == bytes.count else { return false }
            var left = prefix
            for i in 0..<bytes.count where left > 0 {
                let bits = min(8, left)
                let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
                if ip[i] & mask != bytes[i] & mask { return false }
                left -= bits
            }
            return true
        }
    }

    /// Accepted unless config.json says otherwise: this Mac and private LAN ranges.
    static let defaultAllow = ["127.0.0.0/8", "::1/128", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                               "fe80::/10", "fc00::/7"]
    /// Always refused unless listed literally in config.json "allow": Tailscale and other CGNAT tailnets.
    /// (fd7a:115c:a1e0::/48 is Tailscale's IPv6 range, which sits inside the ULA block fc00::/7.)
    static let defaultDeny = ["100.64.0.0/10", "fd7a:115c:a1e0::/48"]
    private static let loopback = [CIDR("127.0.0.0/8")!, CIDR("::1/128")!]

    struct Rules {
        let allow: [CIDR]
        let deny: [CIDR]
    }

    /// ~/.oldphonedeck/config.json: {"allow": ["192.168.1.0/24", ...]} replaces the default allow list.
    /// Loopback is always allowed. A deny range is overridden only by an allow entry that sits inside it.
    /// Missing file or no "allow" key = defaults. Read once, at start.
    static let rules: Rules = makeRules(readConfig()["allow"], log: true)

    private static func readConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: configDir.appendingPathComponent("config.json")) else { return [:] }
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("Warning: config.json is not a JSON object: using the default sources")
            return [:]
        }
        return d
    }

    /// `allowValue`: config.json's "allow" (nil = defaults). Entries that are not a CIDR are skipped.
    static func makeRules(_ allowValue: Any?, log: Bool = false) -> Rules {
        var allow = defaultAllow.compactMap(CIDR.init)
        if let list = allowValue as? [String] {
            let parsed = list.map { ($0, CIDR($0)) }
            if log { for (s, c) in parsed where c == nil { print("config.json: ignored \"\(s)\" (not a CIDR)") } }
            allow = parsed.compactMap { $0.1 }
            if log { print("Access: allowed sources from config.json: \(allow.map(\.description).joined(separator: ", "))") }
        } else if allowValue != nil, log {
            print("Warning: config.json \"allow\" is not a list of networks: using the default sources")
        }
        let deny = defaultDeny.compactMap(CIDR.init).filter { d in
            !allow.contains { a in a.bytes.count == d.bytes.count && a.prefix >= d.prefix && d.contains(a.bytes) }
        }
        return Rules(allow: allow, deny: deny)
    }

    /// Whether `ip` gets in under `r` (loopback always does).
    static func admits(_ ip: [UInt8], under r: Rules) -> Bool {
        if loopback.contains(where: { $0.contains(ip) }) { return true }
        return !r.deny.contains { $0.contains(ip) } && r.allow.contains { $0.contains(ip) }
    }

    static func rawAddress(_ s: String) -> [UInt8]? {
        if let v4 = IPv4Address(s) { return [UInt8](v4.rawValue) }
        if let v6 = IPv6Address(s) { return v6.asIPv4.map { [UInt8]($0.rawValue) } ?? [UInt8](v6.rawValue) }
        return nil
    }

    static func rawAddress(_ endpoint: NWEndpoint) -> [UInt8]? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return [UInt8](a.rawValue)
        case .ipv6(let a): return a.asIPv4.map { [UInt8]($0.rawValue) } ?? [UInt8](a.rawValue)
        default: return nil
        }
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard let ip = rawAddress(endpoint) else { return false }
        return loopback.contains { $0.contains(ip) }
    }

    private static var rejected = Set<String>()
    private static let lock = NSLock()

    /// Call from every listener's newConnectionHandler; on false, cancel the connection without starting it.
    static func admits(_ endpoint: NWEndpoint) -> Bool {
        guard let ip = rawAddress(endpoint) else { return false }
        let ok = admits(ip, under: rules)
        if !ok {
            var key = "\(endpoint)"
            if case .hostPort(let host, _) = endpoint { key = "\(host)" }   // the address without the port
            lock.lock(); let first = rejected.insert(key).inserted; lock.unlock()
            if first { print("Access: refused connections from \(key) (not an allowed source; see config.json)") }
        }
        return ok
    }

    // MARK: Tokens

    static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }

    // MARK: Routes

    /// Served without a token: the page shell and the CA profile.
    static func isPublic(_ path: String) -> Bool {
        ["/", "/index.html", "/oldphonedeck.mobileconfig"].contains(path)
    }

    /// The only routes the plain-HTTP token opens. Everything else (Take note and Claude, the phone camera,
    /// editing the launcher) needs the full token, which only travels over HTTPS or loopback.
    /// /launch and /media stay here: the old iPhone needs them, and the worst a sniffed token can do with them
    /// is open one of the apps in /Applications or skip a song.
    static let plainHTTPRoutes: Set<String> = [
        "GET /info", "GET /stats", "GET /artwork", "GET /icon", "GET /launcher",
        "POST /launch", "POST /media", "POST /speedtest",
    ]

    static let httpsRequired = "HTTPS required: on this Mac this action only works from the https:// page (port +2)."

    /// Body limit: nothing the page sends comes close to 64 KB.
    static func maxBody(_ method: String, _ path: String) -> Int { 64 << 10 }

    /// nil = go ahead and read the body; otherwise the status and text to answer with, body unread.
    static func check(method: String, path: String, query: [String: String], contentLength: Int,
                      secure: Bool, loopback: Bool, token: String, httpToken: String) -> (Int, String)? {
        if !isPublic(path) {
            let k = query["k"] ?? ""
            if equal(k, token) {
                if !secure && !loopback { return (403, httpsRequired) }
            } else if equal(k, httpToken) {
                if !plainHTTPRoutes.contains("\(method) \(path)") { return (403, httpsRequired) }
            } else {
                return (403, "bad token")
            }
        }
        if contentLength > maxBody(method, path) { return (413, "body too large") }
        return nil
    }
}
