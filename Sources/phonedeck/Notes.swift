import Foundation

/// "Take a note" from the Claude widget: a new note in Apple Notes (first line becomes the title).
/// The first use asks to let PhoneDeck control Notes.
enum AppleNotes {
    static func add(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func html(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let body = lines.enumerated().map { i, l in i == 0 ? "<div><h1>\(html(l))</h1></div>" : "<div>\(html(l))</div>" }.joined()
        let escaped = body.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Notes\" to make new note with properties {body:\"\(escaped)\"}"
        return YouTube.osascript(script, timeout: 20).ok
    }
}
