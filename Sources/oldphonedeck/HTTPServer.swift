import Foundation
import Network

/// Minimal HTTP/1.1 server (one request per connection) — enough for iOS 9 Safari.
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    /// Query string merged with an x-www-form-urlencoded body.
    var params: [String: String] {
        var p = query
        if headers["content-type"]?.hasPrefix("application/x-www-form-urlencoded") == true,
           let s = String(data: body, encoding: .utf8) {
            for (k, v) in HTTPRequest.parseForm(s) { p[k] = v }
        }
        return p
    }

    static func parseForm(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            if let k = kv.first { out[k] = kv.count > 1 ? kv[1] : "" }
        }
        return out
    }
}

/// Lifetime: each pending receive/send closure holds the connection strongly; streaming viewers are held by `viewers`.
final class HTTPConnection {
    private let conn: NWConnection
    private var buffer = Data()
    private let maxBody = 512 * 1024 * 1024
    private var sending = false
    var onClose: (() -> Void)?

    init(_ conn: NWConnection) { self.conn = conn }

    func start(queue: DispatchQueue, handler: @escaping (HTTPRequest, HTTPConnection) -> Void) {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.onClose?(); self?.onClose = nil
            default: break
            }
        }
        conn.start(queue: queue)
        receive(handler)
    }

    private func receive(_ handler: @escaping (HTTPRequest, HTTPConnection) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
            if let data { self.buffer.append(data) }
            if let req = self.parse() { handler(req, self); return }
            if done || error != nil || self.buffer.count > self.maxBody { self.conn.cancel(); return }
            self.receive(handler)
        }
    }

    private func parse() -> HTTPRequest? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.count - end.upperBound >= length else { return nil }
        let body = buffer.subdata(in: end.upperBound..<(end.upperBound + length))
        let target = String(parts[1])
        let comps = URLComponents(string: "http://h" + target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(method: String(parts[0]), path: comps?.path ?? target, query: query, headers: headers, body: body)
    }

    func respond(_ status: Int = 200, _ type: String = "text/plain; charset=utf-8", _ body: Data) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 500: "Error"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in self.conn.cancel() })
    }

    func respond(_ status: Int = 200, text: String) { respond(status, "text/plain; charset=utf-8", Data(text.utf8)) }

    func respondJSON(_ obj: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("null".utf8)
        respond(200, "application/json", data)
    }

    // MARK: MJPEG streaming (multipart/x-mixed-replace, supported by Safari since forever)

    func beginMJPEG() {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\n" +
            "Cache-Control: no-store\r\nConnection: close\r\n\r\n--frame\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
    }

    /// Sends a frame unless the previous one is still in flight (drop frames instead of building latency).
    func pushFrame(_ jpeg: Data) {
        guard !sending else { return }
        sending = true
        // Each part ends with the next boundary: browsers only paint a part once they see that boundary,
        // and a still desktop may not produce another frame for a long time.
        let part = Data("Content-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8) + jpeg + Data("\r\n--frame\r\n".utf8)
        conn.send(content: part, completion: .contentProcessed { error in
            self.sending = false
            if error != nil { self.conn.cancel() }
        })
    }
}

final class HTTPServer {
    private let listener: NWListener
    let queue: DispatchQueue

    init(port: UInt16, parameters: NWParameters = .tcp, queue: DispatchQueue = DispatchQueue(label: "http")) throws {
        self.queue = queue
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start(_ handler: @escaping (HTTPRequest, HTTPConnection) -> Void) {
        listener.newConnectionHandler = { [queue] nw in HTTPConnection(nw).start(queue: queue, handler: handler) }
        listener.stateUpdateHandler = { state in
            if case .failed(let e) = state { print("Server failed: \(e)"); exit(1) }
        }
        listener.start(queue: queue)
    }
}
