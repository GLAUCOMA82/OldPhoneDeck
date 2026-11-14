import AppKit

/// Claude Code projects for the deck's project keys: the folders Claude Code has been used in
/// (~/.claude.json) plus git repositories in the usual places. A key opens Terminal in that folder
/// running `claude`.
enum Projects {
    private static let home = NSHomeDirectory()

    static func list() -> [[String: String]] {
        var seen = Set<String>(), out: [[String: String]] = []
        func add(_ path: String, recent: Bool) {
            let p = (path as NSString).standardizingPath
            var isDir: ObjCBool = false
            guard !p.contains("/scratch-workspaces/"), p != home, seen.insert(p).inserted,
                  FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return }
            out.append(["path": p, "name": (p as NSString).lastPathComponent, "recent": recent ? "1" : "0"])
        }
        // 1. Folders Claude Code already knows (most relevant first)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: home + "/.claude.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = json["projects"] as? [String: Any] {
            for path in projects.keys.sorted() { add(path, recent: true) }
        }
        // 2. Git repositories up to two levels below the usual project folders
        let roots = ["Developer", "Projects", "projects", "code", "Code", "src", "GitHub", "Documents/GitHub", "Desktop", "Documents"]
        let fm = FileManager.default
        for root in roots.map({ home + "/" + $0 }) {
            for a in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !a.hasPrefix(".") {
                let pa = root + "/" + a
                if fm.fileExists(atPath: pa + "/.git") || fm.fileExists(atPath: pa + "/CLAUDE.md") { add(pa, recent: false); continue }
                for b in ((try? fm.contentsOfDirectory(atPath: pa)) ?? []).prefix(60) where !b.hasPrefix(".") {
                    let pb = pa + "/" + b
                    if fm.fileExists(atPath: pb + "/.git") || fm.fileExists(atPath: pb + "/CLAUDE.md") { add(pb, recent: false) }
                }
            }
        }
        return out
    }

    /// Opens Terminal in the folder with Claude Code running. A .command file needs no Automation permission.
    static func open(_ path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        var isDir: ObjCBool = false
        // Only real folders inside the home folder (keys are created from list(), but the path comes from the network).
        guard p.hasPrefix(home + "/"), FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return false }
        let quoted = "'" + p.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/zsh -l\ncd \(quoted) || exit 1\nclear\nexec claude\n"
        let file = URL(fileURLWithPath: home + "/.phonedeck/open-claude-code.command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: cfg)
            return true
        }
        return NSWorkspace.shared.open(file)
    }
}
