import Foundation

/// YouTube in Chrome or Safari on the Mac: lists YouTube tabs, mirrors the playing video
/// (title, progress, a small live frame) and controls it (play/pause, seek, volume, next).
/// Listing tabs needs only the Automation prompt; reading/controlling the video also needs the
/// browser's "Allow JavaScript from Apple Events" setting (Chrome: View › Developer;
/// Safari: Settings › Advanced › Show features for web developers, then Develop menu).
final class YouTube {
    private let queue = DispatchQueue(label: "youtube")
    private var cache: (at: Date, frame: Bool, value: [String: Any])?
    private(set) var frame: Data?
    private var selected: String?            // "browser:window:tab" the user picked on a deck

    struct Tab { let browser: String, window: Int, tab: Int, url: String, title: String
        var key: String { "\(browser):\(window):\(tab)" } }

    func snapshot(withFrame: Bool) -> [String: Any] {
        queue.sync {
            if let c = cache, Date().timeIntervalSince(c.at) < 1.5, c.frame || !withFrame { return c.value }
            let v = refresh(withFrame: withFrame)
            cache = (Date(), withFrame, v)
            return v
        }
    }

    func select(_ key: String) { queue.sync { selected = key; cache = nil } }

    func control(_ cmd: String, value: Double?) -> Bool {
        queue.sync {
            guard let tab = currentTab(tabs()) else { return false }
            let js: String
            switch cmd {
            case "playpause": js = "(function(){var v=document.querySelector('video');if(!v)return'';v.paused?v.play():v.pause();return'ok'})()"
            case "back": js = "(function(){var v=document.querySelector('video');if(v)v.currentTime=Math.max(0,v.currentTime-10);return'ok'})()"
            case "forward": js = "(function(){var v=document.querySelector('video');if(v)v.currentTime=v.currentTime+10;return'ok'})()"
            case "next": js = "(function(){var b=document.querySelector('.ytp-next-button');if(b)b.click();return'ok'})()"
            case "volume":
                let vol = max(0, min(1, value ?? 0.5))
                js = "(function(){var v=document.querySelector('video');if(v){v.muted=false;v.volume=\(vol)}return'ok'})()"
            case "mute": js = "(function(){var v=document.querySelector('video');if(v)v.muted=!v.muted;return'ok'})()"
            case "show": return activate(tab)
            default: return false
            }
            cache = nil
            return run(js, in: tab).ok
        }
    }

    // MARK: internals

    private func refresh(withFrame: Bool) -> [String: Any] {
        let all = tabs()
        let list = all.map { ["key": $0.key, "browser": $0.browser, "title": cleanTitle($0.title), "id": videoID($0.url)] }
        guard let tab = currentTab(all) else { frame = nil; return ["tabs": list, "status": all.isEmpty ? "none" : "idle"] }
        var state: [String: Any] = ["tabs": list, "key": tab.key, "browser": tab.browser, "title": cleanTitle(tab.title), "id": videoID(tab.url)]
        let frameJS = withFrame ? """
            try{var c=document.createElement('canvas');c.width=384;c.height=Math.round(384*(v.videoHeight||9)/(v.videoWidth||16));
            c.getContext('2d').drawImage(v,0,0,c.width,c.height);o.frame=c.toDataURL('image/jpeg',.62)}catch(e){}
            """ : ""
        let js = """
            (function(){var v=document.querySelector('video');if(!v)return'{}';
            var ch=document.querySelector('#owner #channel-name a, ytd-channel-name a');
            var o={paused:v.paused,t:v.currentTime,d:v.duration||0,vol:v.volume,muted:v.muted,channel:ch?ch.textContent.trim():''};
            \(frameJS)return JSON.stringify(o)})()
            """
        let r = run(js, in: tab)
        if !r.ok {
            state["status"] = r.error.contains("JavaScript") || r.error.contains("Apple Events") || r.error.contains("Apple-Events") ? "needs-js" : "error"
            return state
        }
        if let data = r.output.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in o where k != "frame" { state[k] = v }
            if let f = o["frame"] as? String, let comma = f.firstIndex(of: ",") {
                frame = Data(base64Encoded: String(f[f.index(after: comma)...]))
                state["frame"] = frame != nil
            }
        }
        state["status"] = "ok"
        return state
    }

    /// The tab the user picked, else the first one (a playing tab is found by the deck switching to it).
    private func currentTab(_ all: [Tab]) -> Tab? {
        if let s = selected, let t = all.first(where: { $0.key == s }) { return t }
        if all.count > 1, let playing = all.first(where: { run("(function(){var v=document.querySelector('video');return v&&!v.paused?'1':''})()", in: $0).output == "1" }) {
            return playing
        }
        return all.first
    }

    private func tabs() -> [Tab] {
        var out: [Tab] = []
        for (browser, app, urlProp, titleProp) in [("chrome", "Google Chrome", "URL", "title"), ("safari", "Safari", "URL", "name")] {
            let script = """
                if application "\(app)" is running then
                  set out to ""
                  set sep to ASCII character 9
                  set nl to ASCII character 10
                  tell application "\(app)"
                    set wi to 0
                    repeat with w in windows
                      set wi to wi + 1
                      set ti to 0
                      repeat with t in tabs of w
                        set ti to ti + 1
                        set u to \(urlProp) of t
                        if u contains "youtube.com" and u does not contain "accounts.google" then
                          set out to out & wi & sep & ti & sep & u & sep & (\(titleProp) of t) & nl
                        end if
                      end repeat
                    end repeat
                  end tell
                  return out
                end if
                return ""
                """
            let r = YouTube.osascript(script)
            guard r.ok else { print("YouTube: \(app) tab list failed: \(r.error.trimmingCharacters(in: .whitespacesAndNewlines))"); continue }
            for line in r.output.split(separator: "\n") {
                let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                if f.count == 4, let w = Int(f[0]), let t = Int(f[1]) { out.append(Tab(browser: browser, window: w, tab: t, url: f[2], title: f[3])) }
            }
        }
        return out
    }

    private func run(_ js: String, in tab: Tab) -> (ok: Bool, output: String, error: String) {
        let escaped = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        let script = tab.browser == "chrome"
            ? "tell application \"Google Chrome\" to execute tab \(tab.tab) of window \(tab.window) javascript \"\(escaped)\""
            : "tell application \"Safari\" to do JavaScript \"\(escaped)\" in tab \(tab.tab) of window \(tab.window)"
        return YouTube.osascript(script)
    }

    private func activate(_ tab: Tab) -> Bool {
        let script = tab.browser == "chrome"
            ? "tell application \"Google Chrome\" to set active tab index of window \(tab.window) to \(tab.tab)\ntell application \"Google Chrome\" to set index of window \(tab.window) to 1\ntell application \"Google Chrome\" to activate"
            : "tell application \"Safari\" to set current tab of window \(tab.window) to tab \(tab.tab) of window \(tab.window)\ntell application \"Safari\" to set index of window \(tab.window) to 1\ntell application \"Safari\" to activate"
        return YouTube.osascript(script).ok
    }

    private func videoID(_ url: String) -> String {
        if let c = URLComponents(string: url) {
            if let v = c.queryItems?.first(where: { $0.name == "v" })?.value { return v }
            if c.path.hasPrefix("/shorts/") { return String(c.path.dropFirst(8)) }
        }
        return ""
    }

    private func cleanTitle(_ t: String) -> String {
        var s = t.replacingOccurrences(of: " - YouTube Music", with: "").replacingOccurrences(of: " - YouTube", with: "")
        if let r = s.range(of: "^\\(\\d+\\) ", options: .regularExpression) { s.removeSubrange(r) }   // "(3) Title" unread count
        return s
    }

    /// osascript with stdout and stderr, so a disabled "Allow JavaScript from Apple Events" can be reported.
    static func osascript(_ source: String, timeout: TimeInterval = 5) -> (ok: Bool, output: String, error: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return (false, "", error.localizedDescription) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let output = (String(data: o, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (p.terminationStatus == 0, output, String(data: e, encoding: .utf8) ?? "")
    }
}
