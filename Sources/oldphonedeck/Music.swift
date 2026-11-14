import AppKit

/// Now playing + transport controls for Spotify and Apple Music, via AppleScript.
/// (The private MediaRemote framework would cover every player, but recent macOS
/// restricts it to Apple-entitled apps; AppleScript works for the two players that matter here.)
/// Any other player (a browser, Podcasts…) is controlled with the Mac's media keys instead.
final class Music {
    private let queue = DispatchQueue(label: "music")   // AppleScript calls run here, one at a time
    private let lock = NSLock()                          // guards current/art for readers on other queues
    private var current: [String: Any] = [:]
    private var artID = ""
    private var art: Data?
    private var timer: DispatchSourceTimer?

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    func snapshot() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return current }
    func artwork() -> Data? { lock.lock(); defer { lock.unlock() }; return art }
    private func set(_ update: () -> Void) { lock.lock(); update(); lock.unlock() }

    /// One script per player, run only while that player is open: a script that names Spotify
    /// doesn't even compile on a Mac without Spotify installed, which used to hide Apple Music too.
    private static let players: [(bundle: String, script: String)] = [
        ("com.spotify.client", """
        tell application "Spotify"
          set t to current track
          return "Spotify" & tab & (player state as text) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & ((duration of t) / 1000) & tab & player position & tab & (artwork url of t) & tab & (id of t)
        end tell
        """),
        ("com.apple.Music", """
        tell application "Music"
          set t to current track
          return "Music" & tab & (player state as text) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & (duration of t) & tab & player position & tab & "" & tab & (persistent ID of t)
        end tell
        """),
    ]

    /// Prefers whichever app is actually playing; if neither is, shows the paused one.
    private func refresh() {
        let found = Music.players
            .filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundle).isEmpty }
            .compactMap { Music.osascript($0.script)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.components(separatedBy: "\t") }
            .filter { $0.count >= 9 }
        guard let f = found.first(where: { $0[1] == "playing" }) ?? found.first else { set { current = [:] }; return }
        let num = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        let id = f[8]
        var info: [String: Any] = ["app": f[0], "playing": f[1] == "playing", "title": f[2], "artist": f[3], "album": f[4],
                                   "duration": num(f[5]), "position": num(f[6]), "id": id]
        let newTrack = id != artID
        if newTrack { artID = id; set { art = nil } }
        set { info["hasArt"] = art != nil; current = info }
        if newTrack { fetchArtwork(app: f[0], url: f[7], id: id) }
    }

    private func fetchArtwork(app: String, url: String, id: String) {
        if app == "Spotify", let u = URL(string: url) {
            URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
                guard let self, let data else { return }
                self.queue.async { if self.artID == id { self.set { self.art = data; self.current["hasArt"] = true } } }
            }.resume()
        } else if app == "Music" {
            // Apple Music only hands out artwork as raw data; write it to a file and read it back.
            let file = NSTemporaryDirectory() + "oldphonedeck-art"
            let script = """
            tell application "Music" to set d to raw data of artwork 1 of current track
            set f to open for access (POSIX file "\(file)") with write permission
            set eof f to 0
            write d to f
            close access f
            """
            if Music.osascript(script) != nil, let data = FileManager.default.contents(atPath: file), !data.isEmpty {
                set { art = data; current["hasArt"] = true }
            }
        }
    }

    /// cmd: playpause | next | previous | volumeup | volumedown. Playback goes to the app shown on the deck,
    /// or, when neither Spotify nor Music is playing anything, to whatever player the media keys reach.
    func control(_ cmd: String) {
        queue.async {
            if cmd == "volumeup" || cmd == "volumedown" {
                let step = cmd == "volumeup" ? "+ 6" : "- 6"
                _ = Music.osascript("set volume output volume ((output volume of (get volume settings)) \(step))")
                return
            }
            let verb = ["playpause": "playpause", "next": "next track", "previous": "previous track"][cmd]
            guard let verb else { return }
            guard let app = self.snapshot()["app"] as? String else {
                DispatchQueue.main.async { MediaKey.press(cmd) }
                return
            }
            _ = Music.osascript("tell application \"\(app)\" to \(verb)")
            Thread.sleep(forTimeInterval: 0.25)   // let the player switch tracks before re-reading
            self.refresh()
        }
    }

    func openPlayer() {
        let app = (snapshot()["app"] as? String) ?? "Music"
        _ = Music.osascript("tell application \"\(app)\" to activate")
    }

    static func osascript(_ source: String) -> String? {
        // Time out: the first call can sit behind macOS's "allow to control Spotify?" prompt.
        guard let data = Stats.run("/usr/bin/osascript", ["-e", source], timeout: 5) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The Mac's play/pause, next and previous keys, which macOS sends to whichever app is playing.
/// Posting them needs the Accessibility permission OldPhoneDeck already asks for.
enum MediaKey {
    static func press(_ cmd: String) {
        let codes: [String: Int] = ["playpause": 16, "next": 17, "previous": 18]   // NX_KEYTYPE_PLAY, _NEXT, _PREVIOUS
        guard let code = codes[cmd] else { return }
        for down in [true, false] {
            let state = down ? 0xa : 0xb
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           subtype: 8, data1: (code << 16) | (state << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
