import AppKit
import CryptoKit
import ApplicationServices
import WebKit
import Network
import SystemConfiguration

// MARK: Options

struct Options {
    var port: UInt16 = 8045
    var width = 960, height = 640          // iPhone 4S landscape, in pixels
    var fps = 12
    var quality = 0.55
    var hiDPI = false
    var screen = false                     // second-monitor mode (virtual display + screen stream)
    var virtual = true                     // false: stream the main display instead
    var micDevice = "BlackHole"            // output device that receives the phone mic
    var city: String?                      // weather location (default: from the Mac's time zone)

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--port": port = UInt16(it.next() ?? "") ?? port
            case "--size":
                let wh = (it.next() ?? "").split(separator: "x").compactMap { Int($0) }
                if wh.count == 2 { width = wh[0]; height = wh[1] }
            case "--fps": fps = Int(it.next() ?? "") ?? fps
            case "--quality": quality = Double(it.next() ?? "") ?? quality
            case "--hidpi": hiDPI = true
            case "--screen": screen = true
            case "--mirror-main": screen = true; virtual = false
            case "--mic-device": micDevice = it.next() ?? micDevice
            case "--city": city = it.next()
            case "-h", "--help":
                print("""
                phonedeck — use an old iPhone as a second monitor + app launcher
                  --port N          HTTP port (default 8045)
                  --screen          also act as a second monitor (virtual display + stream)
                  --size WxH        virtual display size (default 960x640)
                  --hidpi           Retina mode (desktop looks like WxH points at 2x)
                  --fps N           max frames per second (default 12)
                  --quality Q       JPEG quality 0–1 (default 0.55)
                  --mirror-main     stream the main display instead of creating one
                  --mic-device NAME audio device for the PhoneCam mic (default BlackHole)
                  --city NAME       weather location (default: your time zone's city)
                """)
                exit(0)
            default: print("Unknown option \(a) (try --help)"); exit(2)
            }
        }
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let opts = Options(CommandLine.arguments)

// MARK: Access token (anyone on the Wi-Fi could otherwise drive the mouse)

func loadToken() -> String {
    let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".phonedeck")
    let file = dir.appendingPathComponent("token")
    if let t = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
        return t
    }
    let t = (0..<12).map { _ in String("abcdefghjkmnpqrstuvwxyz23456789".randomElement()!) }.joined()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

/// The Mac's Bonjour name ("Your-MacBook-Air.local"). Deck links use it instead of the IP address,
/// so home-screen bookmarks keep working when the Mac moves between networks (home Wi-Fi, a hotspot).
func localHostName() -> String {
    (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0 + ".local" } ?? lanAddress()
}

let token = loadToken()

// MARK: Display + capture

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var virtualDisplay: VirtualDisplay?
var displayID = CGMainDisplayID()
if opts.screen && opts.virtual {
    guard let vd = VirtualDisplay(name: "iPhone 4S (PhoneDeck)", width: UInt32(opts.width),
                                  height: UInt32(opts.height), hiDPI: opts.hiDPI) else {
        print("Could not create the virtual display (private CGVirtualDisplay API refused). Try --mirror-main.")
        exit(1)
    }
    virtualDisplay = vd
    displayID = vd.displayID
    print("Created virtual display #\(displayID) at \(opts.width)x\(opts.height)\(opts.hiDPI ? " HiDPI" : "")")
}
Input.displayID = displayID

let streamW = opts.virtual ? opts.width * (opts.hiDPI ? 2 : 1) : opts.width
let streamH = opts.virtual ? opts.height * (opts.hiDPI ? 2 : 1) : opts.height
// Never send more pixels than the phone has (960x640) — the A5 has to decode every frame.
let scale = min(1.0, min(960.0 / Double(streamW), 640.0 / Double(streamH)))
let outW = Int(Double(streamW) * scale), outH = Int(Double(streamH) * scale)

let capturer = Capturer(quality: opts.quality)
let server: HTTPServer
do { server = try HTTPServer(port: opts.port) } catch { print("Cannot listen on \(opts.port): \(error)"); exit(1) }
var viewers: [ObjectIdentifier: HTTPConnection] = [:]   // touched only on server.queue

capturer.onFrame = { jpeg in
    server.queue.async { for v in viewers.values { v.pushFrame(jpeg) } }
}

// PhoneCam (native iOS app) streams camera + mic to port+1.
var cameraViewers: [ObjectIdentifier: HTTPConnection] = [:]   // touched only on server.queue
let phoneMedia: PhoneMediaServer
do {
    phoneMedia = try PhoneMediaServer(port: opts.port + 1, token: token, micDevice: opts.micDevice)
} catch { print("Cannot listen on \(opts.port + 1): \(error)"); exit(1) }
phoneMedia.onFrame = { jpeg in
    server.queue.async { for v in cameraViewers.values { v.pushFrame(jpeg) } }
}
phoneMedia.start()

let stats = Stats()
stats.start()
let music = Music()
music.start()
let weather = Weather(city: opts.city)
weather.start()
let agenda = Agenda()
agenda.start()
let notifications = Notifications()
notifications.start()
let youtube = YouTube()
let whatsapp = WhatsApp()
var clients: [String: [String: Any]] = [:]   // deck kind → last seen, page; touched only on server.queue

// MARK: Routes

let webRoot = Bundle.module.url(forResource: "web", withExtension: nil)!

let routes: (HTTPRequest, HTTPConnection) -> Void = { req, conn in
    // Static shell is public so the home-screen bookmark loads; everything else needs the token.
    // Public: the iPhone downloads this once and trusts it, so HTTPS (camera/mic/speech) works.
    // The same CA wrapped as a configuration profile: iOS reliably offers to install this (a bare .cer is hit-and-miss).
    if req.path == "/phonedeck.mobileconfig" || req.path == "/phonedeck-ca.cer" {
        guard let der = LocalTLS.caCertificate() else {
            // A page, not a broken download: iOS would only say "Invalid Profile".
            let page = "<meta name=viewport content='width=device-width'><body style='font:17px -apple-system;padding:24px'>"
                + "<h3>PhoneDeck couldn't create its certificate</h3><p>PhoneDeck's log on your Mac (menu bar icon › Show Log) says why.</p>"
            return conn.respond(500, "text/html; charset=utf-8", Data(page.utf8))
        }
        if req.path == "/phonedeck-ca.cer" { return conn.respond(200, "application/x-x509-ca-cert", der) }
        // UUIDs from the certificate itself, so every Mac's CA gets its own profile.
        let hash = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
        func uuid(_ salt: Int) -> String {
            let h = String(hash.dropFirst(salt * 32).prefix(32))
            return [0, 8, 12, 16, 20].enumerated().map { i, start in
                let len = [8, 4, 4, 4, 12][i]
                return String(h.dropFirst(start).prefix(len))
            }.joined(separator: "-")
        }
        let cert: [String: Any] = [
            "PayloadType": "com.apple.security.root", "PayloadVersion": 1,
            "PayloadIdentifier": "com.phonedeck.ca.cert", "PayloadUUID": uuid(0),
            "PayloadDisplayName": "PhoneDeck CA", "PayloadCertificateFileName": "phonedeck-ca.cer", "PayloadContent": der,
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration", "PayloadVersion": 1,
            "PayloadIdentifier": "com.phonedeck.ca", "PayloadUUID": uuid(1),
            "PayloadDisplayName": "PhoneDeck", "PayloadOrganization": "PhoneDeck",
            "PayloadDescription": "Lets this iPhone open PhoneDeck on your Mac over HTTPS (needed for camera, mic and voice).",
            "PayloadContent": [cert],
        ]
        let data = (try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)) ?? Data()
        return conn.respond(200, "application/x-apple-aspen-config", data)
    }
    // One deck page for every device (it picks the 4S, iPhone or iPad profile itself), the shared
    // renderer, and the Mac's Command Center. None of these contain data; the API below needs the token.
    let statics: [String: (String, String)] = [
        "/": ("index.html", "text/html; charset=utf-8"), "/index.html": ("index.html", "text/html; charset=utf-8"),
        "/ipad": ("index.html", "text/html; charset=utf-8"), "/studio": ("studio.html", "text/html; charset=utf-8"),
        "/deck.js": ("deck.js", "application/javascript; charset=utf-8"), "/deck.css": ("deck.css", "text/css; charset=utf-8"),
        "/favicon.png": ("favicon.png", "image/png"), "/apple-touch-icon.png": ("apple-touch-icon.png", "image/png"),
        "/apple-touch-icon-precomposed.png": ("apple-touch-icon.png", "image/png"), "/icon.svg": ("icon.svg", "image/svg+xml"),
    ]
    if let (file, type) = statics[req.path] {
        let data = (try? Data(contentsOf: webRoot.appendingPathComponent(file))) ?? Data()
        return conn.respond(200, type, data)
    }
    if req.path == "/concepts" {   // static iPad layout mockups (sample data)
        let html = (try? Data(contentsOf: webRoot.appendingPathComponent("concepts.html"))) ?? Data()
        return conn.respond(200, "text/html; charset=utf-8", html)
    }
    guard req.query["k"] == token else { return conn.respond(403, text: "bad token") }
    let p = req.params

    switch (req.method, req.path) {
    case ("GET", "/info"):
        conn.respondJSON(["width": outW, "height": outH, "fps": opts.fps, "screen": opts.screen, "camera": phoneMedia.isLive, "mic": phoneMedia.micStatus,
                          "lan": lanAddress(), "host": localHostName(), "port": Int(opts.port)])
    case ("GET", "/mic.wav"):   // the last 10 s of the PhoneCam mic, to check what the phone is sending
        conn.respond(200, "audio/wav", phoneMedia.recentMicWAV)
    case ("GET", "/stream"):
        let id = ObjectIdentifier(conn)
        conn.onClose = { server.queue.async { viewers[id] = nil } }
        viewers[id] = conn
        conn.beginMJPEG()
        if let last = capturer.latest { conn.pushFrame(last) }
    case ("GET", "/camera.mjpg"):
        let id = ObjectIdentifier(conn)
        conn.onClose = { server.queue.async { cameraViewers[id] = nil } }
        cameraViewers[id] = conn
        conn.beginMJPEG()
        if let last = phoneMedia.latestFrame { conn.pushFrame(last) }
    case ("GET", "/camera.jpg"):
        conn.respond(200, "image/jpeg", phoneMedia.latestFrame ?? Data())
    case ("GET", "/frame.jpg"):
        conn.respond(200, "image/jpeg", capturer.latest ?? Data())
    case ("POST", "/input"):
        DispatchQueue.main.async { Input.handle(p) }
        conn.respond(text: "ok")
    case ("POST", "/type"):
        DispatchQueue.main.async {
            if let k = p["key"] { Input.key(k) }
            if let s = p["text"] { Input.type(s) }
        }
        conn.respond(text: "ok")
    case ("GET", "/stats"):
        var snap = stats.snapshot()
        snap["music"] = music.snapshot()
        snap["layout"] = Layout.version
        snap["notes"] = notifications.snapshot()
        snap["dark"] = MacControls.darkMode
        if let dev = p["dev"], ["classic", "phone", "tablet"].contains(dev) {
            clients[dev] = ["at": Date().timeIntervalSince1970 * 1000, "page": Int(p["page"] ?? "") ?? 0,
                            "w": Int(p["w"] ?? "") ?? 0, "h": Int(p["h"] ?? "") ?? 0]
        }
        if p["full"] == "1" {   // widgets beyond the basics (weather, calendar, Mac controls)
            snap["controls"] = MacControls.snapshot()
            snap["weather"] = weather.snapshot()
            snap["agenda"] = agenda.snapshot()
        }
        conn.respondJSON(snap)
    case ("GET", "/projects"):
        DispatchQueue.global().async {
            let list = Projects.list()
            server.queue.async { conn.respondJSON(list) }
        }
    case ("POST", "/project"):
        let path = p["path"] ?? ""
        DispatchQueue.main.async {
            let ok = Projects.open(path)
            server.queue.async { conn.respondJSON(["ok": ok]) }
        }
    case ("POST", "/note"):
        let text = (p["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return conn.respond(400, text: "empty note") }
        DispatchQueue.global().async {
            let ok = AppleNotes.add(text)
            server.queue.async { conn.respondJSON(["ok": ok]) }
        }
    case ("POST", "/note/ink"):
        // Notes widget: PNG of the handwriting, base64 in "image"
        guard let b64 = p["image"], let png = Data(base64Encoded: b64.replacingOccurrences(of: " ", with: "+")), png.count > 100 else {
            return conn.respond(400, text: "no image")
        }
        DispatchQueue.global().async {
            let r = Ink.save(png)
            server.queue.async { conn.respondJSON(["ok": r.ok, "text": r.text]) }
        }
    case ("GET", "/whatsapp/chats"):
        let limit = min(30, Int(p["limit"] ?? "") ?? 8)
        DispatchQueue.global().async {
            let r = whatsapp.chats(limit: limit)
            server.queue.async { conn.respondJSON(r) }
        }
    case ("GET", "/whatsapp/messages"):
        let chat = Int(p["chat"] ?? "") ?? 0
        DispatchQueue.global().async {
            let r = whatsapp.messages(chat: chat)
            server.queue.async { conn.respondJSON(r) }
        }
    case ("POST", "/whatsapp/reply"):
        let chat = Int(p["chat"] ?? "") ?? 0, text = (p["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard chat > 0, !text.isEmpty else { return conn.respond(400, text: "chat and text needed") }
        DispatchQueue.global().async {
            let r = whatsapp.reply(chat: chat, text: text)
            server.queue.async { conn.respondJSON(["ok": r != "failed", "result": r]) }
        }
    case ("GET", "/youtube"):
        let withFrame = p["frame"] == "1"
        DispatchQueue.global().async {
            let snap = youtube.snapshot(withFrame: withFrame)
            server.queue.async { conn.respondJSON(snap) }
        }
    case ("GET", "/youtube/frame.jpg"):
        guard let f = youtube.frame else { return conn.respond(404, text: "no frame") }
        conn.respond(200, "image/jpeg", f)
    case ("POST", "/youtube"):
        let cmd = p["cmd"] ?? "", value = Double(p["value"] ?? "")
        DispatchQueue.global().async {
            if cmd == "select" { youtube.select(p["key"] ?? ""); server.queue.async { conn.respondJSON(["ok": true]) }; return }
            let ok = youtube.control(cmd, value: value)
            server.queue.async { conn.respondJSON(["ok": ok]) }
        }
    case ("POST", "/clientlog"):
        print("Device error [\(p["dev"] ?? "?")] \(p["msg"] ?? "") at \(p["at"] ?? "") · \(p["ua"] ?? "")")
        conn.respondJSON(["ok": true])
    case ("GET", "/nettest"):
        // Self-test for macOS Local Network privacy: an outgoing connection to the router.
        let host = p["host"] ?? "192.168.0.1"
        let c = NWConnection(host: NWEndpoint.Host(host), port: 80, using: .tcp)
        var answered = false
        func answer(_ s: String) { if !answered { answered = true; c.cancel(); conn.respondJSON(["host": host, "result": s]) } }
        c.stateUpdateHandler = { st in
            server.queue.async {
                switch st {
                case .ready: answer("connected")
                case .waiting(let e): answer("waiting: \(e)")
                case .failed(let e): answer("failed: \(e)")
                default: break
                }
            }
        }
        c.start(queue: .global())
        server.queue.asyncAfter(deadline: .now() + 4) { answer("timeout") }
    case ("GET", "/layout"):
        conn.respond(200, "application/json", Layout.load() ?? Data("null".utf8))
    case ("POST", "/layout"):
        do { try Layout.save(req.body); conn.respondJSON(["ok": true, "version": Layout.version]) }
        catch { conn.respond(400, text: error.localizedDescription) }
    case ("GET", "/clients"):
        conn.respondJSON(clients)
    case ("POST", "/notify"):
        // For scripts and hooks, e.g. Claude Code:  curl -d "app=Claude&title=Task done" "http://localhost:8045/notify?k=TOKEN"
        notifications.push(app: p["app"] ?? "Mac", title: p["title"] ?? "", body: p["body"] ?? "", bundle: p["bundle"] ?? "")
        conn.respondJSON(["ok": true])
    case ("POST", "/notifications/clear"):
        notifications.clear()
        conn.respondJSON(["ok": true])
    case ("GET", "/shortcuts"):
        DispatchQueue.global().async {
            let names = String(data: Stats.run("/usr/bin/shortcuts", ["list"], timeout: 8) ?? Data(), encoding: .utf8)?
                .split(separator: "\n").map(String.init) ?? []
            server.queue.async { conn.respondJSON(names) }
        }
    case ("POST", "/shortcut"):
        // Pages can turn on a Focus (or run any shortcut) when they open; only names saved in the layout run.
        let name = p["name"] ?? ""
        guard Layout.pageShortcuts().contains(name) else { return conn.respond(403, text: "shortcut not in layout") }
        DispatchQueue.global().async {
            let ok = Stats.run("/usr/bin/shortcuts", ["run", name], timeout: 15) != nil
            server.queue.async { conn.respondJSON(["ok": ok]) }
        }
    case ("POST", "/settings-pane"):
        // Opens the System Settings page the Command Center's setup checklist points at.
        let panes = ["fda": "Privacy_AllFiles", "accessibility": "Privacy_Accessibility", "automation": "Privacy_Automation"]
        guard let pane = panes[p["pane"] ?? ""],
              let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return conn.respond(400, text: "unknown pane") }
        DispatchQueue.main.async { NSWorkspace.shared.open(u) }
        conn.respondJSON(["ok": true, "access": notifications.historyAccess, "accessibility": AXIsProcessTrusted()])
    case ("GET", "/permissions"):
        conn.respondJSON(["notifications": notifications.historyAccess, "accessibility": AXIsProcessTrusted()])
    case ("GET", "/bluetooth"):
        DispatchQueue.global().async {   // system_profiler takes about a second
            let bt = Stats.bluetooth()
            server.queue.async { conn.respondJSON(bt) }
        }
    case ("POST", "/control"):
        let value = Double(p["value"] ?? "") ?? 0
        switch p["cmd"] ?? "" {
        case "volume": MacControls.setVolume(value)
        case "brightness": DispatchQueue.global().async { MacControls.setBrightness(value) }
        case "dark": DispatchQueue.global().async { MacControls.toggleDarkMode() }
        case "awake": MacControls.toggleKeepAwake()
        case "micmute": MacControls.toggleMicMute()
        case "sleepdisplay": DispatchQueue.global().async { _ = Stats.run("/usr/bin/pmset", ["displaysleepnow"], timeout: 5) }
        case "screenshot":   // interactive selection on the Mac, saved to the clipboard
            DispatchQueue.global().async { _ = Stats.run("/usr/sbin/screencapture", ["-i", "-c"], timeout: 120) }
        case "leftright", "fill":
            let kind = p["cmd"] ?? ""
            DispatchQueue.global().async {
                let err = MacControls.tile(kind)
                server.queue.async { conn.respondJSON(["ok": err == nil, "error": err ?? ""]) }
            }
            return
        case "input":
            let input = p["input"] ?? ""
            DispatchQueue.global().async {
                let ok = MacControls.setMonitorInput(input)
                server.queue.async { conn.respondJSON(["ok": ok]) }
            }
            return
        case "focus":
            DispatchQueue.global().async {
                let ok = MacControls.runFocusShortcut()
                server.queue.async { conn.respondJSON(["ok": ok, "shortcut": MacControls.focusShortcut]) }
            }
            return
        default: return conn.respond(400, text: "unknown control")
        }
        conn.respondJSON(["ok": true])
    case ("POST", "/media"):
        let cmd = p["cmd"] ?? ""
        if cmd == "open" { DispatchQueue.global().async { music.openPlayer() } } else { music.control(cmd) }
        conn.respond(text: "ok")
    case ("GET", "/artwork"):
        guard let art = music.artwork() else { return conn.respond(404, text: "no artwork") }
        conn.respond(200, "image/jpeg", art)
    case ("POST", "/speedtest"):
        stats.runSpeedTest()
        conn.respond(text: "ok")
    case ("GET", "/apps"):
        conn.respondJSON(Apps.list())
    case ("GET", "/launcher"):
        let selected: Any = Launcher.selected() ?? NSNull()
        conn.respondJSON(["selected": selected, "all": Apps.list()])
    case ("POST", "/launcher"):
        // Body: paths=<path>\n<path>\n… in display order.
        let paths = (p["paths"] ?? "").split(separator: "\n").map(String.init)
        do { conn.respondJSON(["saved": try Launcher.save(paths)]) }
        catch { conn.respond(500, text: error.localizedDescription) }
    case ("POST", "/claude"):
        let text = (p["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async {
            if p["mode"] == "reply", !text.isEmpty { Claude.reply(text) }
            else if p["new"] == "1" { Claude.newChat() }
            else if text.isEmpty { Claude.focus() }
            else { Claude.ask(text, autoSend: p["send"] == "1") }
        }
        conn.respond(text: "ok")
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
    case ("POST", "/upload"):
        do {
            let url = try Uploads.save(req.body, suggestedName: p["name"] ?? "")
            print("Saved upload: \(url.path)")
            conn.respondJSON(["saved": url.lastPathComponent])
        } catch {
            conn.respond(500, text: error.localizedDescription)
        }
    case ("GET", "/Hey Claude.shortcut"):
        // Optional signed "Hey Claude" shortcut for modern iPhones: put it in ~/.phonedeck to offer it here.
        let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".phonedeck/Hey Claude.shortcut")
        guard let data = try? Data(contentsOf: file) else { return conn.respond(404, text: "shortcut not built") }
        conn.respond(200, "application/octet-stream", data)
    default:
        conn.respond(404, text: "not found")
    }
}
server.advertise(name: "PhoneDeck on \(Host.current().localizedName ?? "Mac")", type: "_phonedeck._tcp")
server.start(routes)
// The iPhone 4S over a USB cable, with no Wi-Fi (see USBTunnel.swift): deck on the HTTP port, camera/mic on port + 1.
USBTunnel.start(ports: [opts.port, opts.port + 1])

// HTTPS + secure WebSocket for modern iPhones (Safari needs a secure page for camera, mic and speech).
let lanIP = lanAddress()
var httpsServer: HTTPServer?
if let identity = LocalTLS.identity(for: lanIP, host: localHostName()) {
    do {
        let s = try HTTPServer(port: opts.port + 2, parameters: LocalTLS.parameters(identity), queue: server.queue)
        s.start(routes)
        httpsServer = s
        try phoneMedia.startWebSocket(port: opts.port + 3, identity: identity)
    } catch { print("⚠️  HTTPS failed to start: \(error)") }
}

// MARK: Permissions + start

// Announce the deck on the local network (Bonjour). Besides making PhoneDeck discoverable, this is what makes
// macOS ask for — and list PhoneDeck under — Privacy & Security › Local Network, which phones need to reach it.
let bonjour = NWBrowser(for: .bonjour(type: "_phonedeck._tcp", domain: nil), using: .tcp)
bonjour.start(queue: .main)

if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
    print("⚠️  Grant Accessibility permission (System Settings → Privacy & Security → Accessibility) so Ask Claude can press Return to send.")
}

if opts.screen { Task {
    do {
        try await capturer.start(displayID: displayID, width: outW, height: outH, fps: opts.fps)
        print("Streaming \(outW)x\(outH) @ up to \(opts.fps) fps")
    } catch {
        print("⚠️  Screen capture failed: \(error.localizedDescription)")
        print("   Grant Screen Recording permission to your terminal (Privacy & Security → Screen & System Audio Recording), then rerun.")
    }
} }

let url = "http://\(localHostName()):\(opts.port)/#k=\(token)"
print("""

PhoneDeck is running. On the iPhone 4S (same Wi-Fi), open Safari and go to:

    \(url)

Then tap Share → Add to Home Screen for a full-screen app.
Design the decks in the Command Center: menu bar icon → Command Center (or http://localhost:\(opts.port)/studio#k=\(token))
Webcam for OBS (Media Source, uncheck Local File): http://localhost:\(opts.port)/camera.mjpg?k=\(token)

Modern iPhone (camera, mic, voice): one-time, open http://\(localHostName()):\(opts.port)/phonedeck.mobileconfig, install it and trust it,
then use https://\(localHostName()):\(opts.port + 2)/#k=\(token)
(If a device can't find \(localHostName()), use the address \(lanAddress()) instead.)
Ctrl-C to quit.

""")

// MARK: Mac app (menu bar extra, app menus, Command Center, Connect a Device; see MacApp.swift)

app.delegate = AppDelegate.shared
MainMenu.install()
let menuBar = MenuBar()

// First run (no layout saved yet): open the Command Center so the decks can be set up.
if Layout.load() == nil && Bundle.main.bundlePath.hasSuffix(".app") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { CommandCenter.shared.show() } }

signal(SIGINT) { _ in exit(0) }
app.run()
