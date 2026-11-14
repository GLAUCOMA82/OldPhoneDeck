import AppKit
import Vision

/// Handwritten notes from the Notes widget: Apple Pencil ink arrives as a PNG (black ink on white),
/// macOS's Vision framework reads the handwriting, and the result becomes an Apple Notes note:
/// recognized text (first line = title) with the original handwriting attached.
enum Ink {
    static let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures/PhoneDeck/Notes")

    /// Text lines in reading order (top to bottom, then left to right).
    static func recognize(_ png: Data) -> [String] {
        guard let image = NSImage(data: png), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        let obs = (request.results ?? []).compactMap { o -> (y: CGFloat, x: CGFloat, h: CGFloat, s: String)? in
            guard let s = o.topCandidates(1).first?.string else { return nil }
            return (o.boundingBox.midY, o.boundingBox.minX, o.boundingBox.height, s)
        }
        // Group observations whose vertical centres are close into one line.
        var lines: [[(y: CGFloat, x: CGFloat, h: CGFloat, s: String)]] = []
        for o in obs.sorted(by: { $0.y > $1.y }) {
            if let last = lines.last?.first, abs(last.y - o.y) < max(last.h, o.h) * 0.5 { lines[lines.count - 1].append(o) }
            else { lines.append([o]) }
        }
        return lines.map { $0.sorted { $0.x < $1.x }.map(\.s).joined(separator: " ") }
    }

    /// Recognizes, saves the drawing, creates the note. Returns the recognized text (empty if none).
    static func save(_ png: Data) -> (ok: Bool, text: String) {
        let lines = recognize(png)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent("note-\(stamp).png")
        try? png.write(to: file)

        let title = lines.first ?? "Handwritten note"
        func html(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var body = "<div><h1>\(html(title))</h1></div>"
        for l in lines.dropFirst() { body += "<div>\(html(l))</div>" }
        if lines.isEmpty { body += "<div>(no text recognized)</div>" }
        body += "<div><br></div>"
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        // Create the note, then attach the handwriting image (attachment is best-effort; the text note stands on its own).
        let script = """
            tell application "Notes"
              set n to make new note with properties {body:"\(esc(body))"}
              try
                make new attachment at end of attachments of n with data (POSIX file "\(esc(file.path))")
              end try
            end tell
            """
        let r = YouTube.osascript(script, timeout: 25)
        if !r.ok { print("Notes: \(r.error.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return (r.ok, lines.joined(separator: "\n"))
    }
}
