import Foundation

/// Now playing + transport controls for Spotify and Apple Music, via AppleScript.
/// (The private MediaRemote framework would cover every player, but recent macOS
/// restricts it to Apple-entitled apps; AppleScript works for the two players that matter here.)
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

    /// Prefers whichever app is actually playing; if neither is, shows the paused one.
    private static let nowPlayingScript = """
    set out to ""
    if application "Spotify" is running then
      tell application "Spotify"
        try
          set t to current track
          set out to "Spotify" & tab & (player state as text) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & ((duration of t) / 1000) & tab & player position & tab & (artwork url of t) & tab & (id of t)
        end try
      end tell
    end if
    if application "Music" is running then
      tell application "Music"
        try
          if player state is playing or out is "" then
            set t to current track
            set out to "Music" & tab & (player state as text) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & (duration of t) & tab & player position & tab & "" & tab & (persistent ID of t)
          end if
        end try
      end tell
    end if
    return out
    """

    private func refresh() {
        guard let raw = Music.osascript(Music.nowPlayingScript)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { set { current = [:] }; return }
        let f = raw.components(separatedBy: "\t")
        guard f.count >= 9 else { set { current = [:] }; return }
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

    /// cmd: playpause | next | previous. Goes to the app shown on the deck.
    func control(_ cmd: String) {
        queue.async {
            let app = (self.current["app"] as? String) ?? "Spotify"
            let verb = ["playpause": "playpause", "next": "next track", "previous": "previous track"][cmd]
            guard let verb else { return }
            _ = Music.osascript("tell application \"\(app)\" to \(verb)")
            Thread.sleep(forTimeInterval: 0.25)   // let the player switch tracks before re-reading
            self.refresh()
        }
    }

    func openPlayer() {
        let app = (snapshot()["app"] as? String) ?? "Spotify"
        _ = Music.osascript("tell application \"\(app)\" to activate")
    }

    static func osascript(_ source: String) -> String? {
        // Time out: the first call can sit behind macOS's "allow to control Spotify?" prompt.
        guard let data = Stats.run("/usr/bin/osascript", ["-e", source], timeout: 5) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
