import AppKit
import ApplicationServices

// MARK: Options

struct Options {
    var port: UInt16 = 8045                // http = port, https = port+2, secure WebSocket = port+3
    var micDevice = "BlackHole"            // output device that receives a modern iPhone's mic

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--port": port = UInt16(it.next() ?? "") ?? port
            case "--mic-device": micDevice = it.next() ?? micDevice
            case "-h", "--help":
                print("""
                oldphonedeck: turn an old iPhone into a Stream Deck-style control panel for your Mac
                  --port N          HTTP port (default 8045; HTTPS uses N+2, WebSocket N+3)
                  --mic-device NAME audio device that receives the phone's mic (default BlackHole)
                """)
                exit(0)
            default: print("Unknown option \(a) (try --help)"); exit(2)
            }
        }
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let opts = Options(CommandLine.arguments)
let configDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".oldphonedeck")

// MARK: Access token (anyone on the Wi-Fi could otherwise open apps on your Mac)

func loadToken() -> String {
    let file = configDir.appendingPathComponent("token")
    if let t = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
        return t
    }
    let t = (0..<12).map { _ in String("abcdefghjkmnpqrstuvwxyz23456789".randomElement()!) }.joined()
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    try? t.write(to: file, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return t
}

func lanAddress() -> String {
    var addr = "localhost"
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return addr }
    defer { freeifaddrs(ifaddr) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let i = p.pointee
        guard i.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: i.ifa_name)
        guard name.hasPrefix("en") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(i.ifa_addr, socklen_t(i.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        addr = String(cString: host)
        if name == "en0" { break }
    }
    return addr
}

let token = loadToken()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// MARK: Services

let server: HTTPServer
do { server = try HTTPServer(port: opts.port) } catch { print("Cannot listen on \(opts.port): \(error)"); exit(1) }

// Camera + mic from a modern iPhone (browser, over the secure WebSocket).
var cameraViewers: [ObjectIdentifier: HTTPConnection] = [:]   // touched only on server.queue
let phoneMedia = PhoneMediaServer(token: token, audio: AudioOut(deviceMatch: opts.micDevice))
phoneMedia.onFrame = { jpeg in
    server.queue.async { for v in cameraViewers.values { v.pushFrame(jpeg) } }
}

let stats = Stats()
stats.start()
let music = Music()
music.start()

// MARK: Routes

let webRoot = Bundle.module.url(forResource: "web", withExtension: nil)!

let routes: (HTTPRequest, HTTPConnection) -> Void = { req, conn in
    // Public: the page shell (so a home-screen bookmark loads) and the local CA as an iOS profile.
    if req.path == "/oldphonedeck.mobileconfig" {
        guard let der = try? Data(contentsOf: LocalTLS.caDER) else { return conn.respond(404, text: "no certificate yet") }
        let cert: [String: Any] = [
            "PayloadType": "com.apple.security.root", "PayloadVersion": 1,
            "PayloadIdentifier": "com.oldphonedeck.ca.cert", "PayloadUUID": "6F1C2A4E-2B7D-4C5A-9E1F-50A1C0DEC0A1",
            "PayloadDisplayName": "OldPhoneDeck CA", "PayloadCertificateFileName": "oldphonedeck-ca.cer", "PayloadContent": der,
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration", "PayloadVersion": 1,
            "PayloadIdentifier": "com.oldphonedeck.ca", "PayloadUUID": "3B8E9D10-7C2F-4E61-A5B3-50A1C0DEC0A2",
            "PayloadDisplayName": "OldPhoneDeck", "PayloadOrganization": "OldPhoneDeck",
            "PayloadDescription": "Lets this iPhone open OldPhoneDeck on your Mac over HTTPS (needed for camera, mic and voice).",
            "PayloadContent": [cert],
        ]
        let data = (try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)) ?? Data()
        return conn.respond(200, "application/x-apple-aspen-config", data)
    }
    if req.path == "/" || req.path == "/index.html" {
        let html = (try? Data(contentsOf: webRoot.appendingPathComponent("index.html"))) ?? Data()
        return conn.respond(200, "text/html; charset=utf-8", html)
    }
    guard req.query["k"] == token else { return conn.respond(403, text: "bad token") }
    let p = req.params

    switch (req.method, req.path) {
    case ("GET", "/info"):
        conn.respondJSON(["camera": phoneMedia.isLive])
    case ("GET", "/stats"):
        var snap = stats.snapshot()
        snap["music"] = music.snapshot()
        conn.respondJSON(snap)
    case ("POST", "/speedtest"):
        stats.runSpeedTest()
        conn.respond(text: "ok")
    case ("POST", "/media"):
        let cmd = p["cmd"] ?? ""
        if cmd == "open" { DispatchQueue.global().async { music.openPlayer() } } else { music.control(cmd) }
        conn.respond(text: "ok")
    case ("GET", "/artwork"):
        guard let art = music.artwork() else { return conn.respond(404, text: "no artwork") }
        conn.respond(200, "image/jpeg", art)
    case ("GET", "/launcher"):
        let selected: Any = Launcher.selected() ?? NSNull()
        conn.respondJSON(["selected": selected, "all": Apps.list()])
    case ("POST", "/launcher"):
        // Body: paths=<path>\n<path>\n… in display order.
        let paths = (p["paths"] ?? "").split(separator: "\n").map(String.init)
        do { conn.respondJSON(["saved": try Launcher.save(paths)]) }
        catch { conn.respond(500, text: error.localizedDescription) }
    case ("GET", "/icon"):
        let path = p["path"] ?? ""
        guard Apps.isKnown(path) else { return conn.respond(404, text: "unknown app") }
        DispatchQueue.main.async {
            let png = Apps.icon(path) ?? Data()
            server.queue.async { conn.respond(200, "image/png", png) }
        }
    case ("POST", "/launch"):
        let path = p["path"] ?? ""
        guard Apps.isKnown(path) else { return conn.respond(404, text: "unknown app") }
        DispatchQueue.main.async { Apps.launch(path) }
        conn.respond(text: "ok")
    case ("POST", "/claude"):
        let text = (p["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async {
            if text.isEmpty { Claude.focus() } else { Claude.ask(text, autoSend: p["send"] == "1") }
        }
        conn.respond(text: "ok")
    case ("GET", "/camera.mjpg"):
        let id = ObjectIdentifier(conn)
        conn.onClose = { server.queue.async { cameraViewers[id] = nil } }
        cameraViewers[id] = conn
        conn.beginMJPEG()
        if let last = phoneMedia.latestFrame { conn.pushFrame(last) }
    case ("GET", "/camera.jpg"):
        conn.respond(200, "image/jpeg", phoneMedia.latestFrame ?? Data())
    default:
        conn.respond(404, text: "not found")
    }
}
server.start(routes)

// HTTPS + secure WebSocket for modern iPhones (Safari needs a secure page for camera, mic and speech).
let lanIP = lanAddress()
var httpsServer: HTTPServer?
if let identity = LocalTLS.identity(for: lanIP) {
    do {
        let s = try HTTPServer(port: opts.port + 2, parameters: LocalTLS.parameters(identity), queue: server.queue)
        s.start(routes)
        httpsServer = s
        try phoneMedia.startWebSocket(port: opts.port + 3, identity: identity)
    } catch { print("⚠️  HTTPS failed to start: \(error)") }
}

// MARK: Permissions + start

if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
    print("⚠️  Grant Accessibility permission (System Settings → Privacy & Security → Accessibility) so Take note can press Return in Claude.")
}

print("""

OldPhoneDeck is running. On the phone (same Wi-Fi), open Safari and go to:

    http://\(lanIP):\(opts.port)/#k=\(token)

Then tap Share → Add to Home Screen. Hold any key to choose your apps.

Modern iPhone (voice, camera, mic): once, open http://\(lanIP):\(opts.port)/oldphonedeck.mobileconfig,
install it, enable it in Settings → General → About → Certificate Trust Settings,
then use https://\(lanIP):\(opts.port + 2)/#k=\(token)
Camera for OBS (Media Source): http://localhost:\(opts.port)/camera.mjpg?k=\(token)
Ctrl-C to quit.

""")

signal(SIGINT) { _ in exit(0) }
app.run()
