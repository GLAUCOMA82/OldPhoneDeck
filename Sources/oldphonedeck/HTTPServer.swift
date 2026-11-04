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

/// What a request may do is decided from its head alone (see Access.check), before any body is read.
typealias HTTPGate = (_ method: String, _ path: String, _ query: [String: String], _ contentLength: Int,
                      _ secure: Bool, _ loopback: Bool) -> (Int, String)?

/// Lifetime: each pending receive/send closure holds the connection strongly; streaming viewers are held by `viewers`.
final class HTTPConnection {
    private let conn: NWConnection
    private let secure: Bool
    private let loopback: Bool
    private var buffer = Data()
    private let maxHead = 16 << 10
    private var head: (method: String, path: String, query: [String: String], headers: [String: String], bodyStart: Int, length: Int)?
    private var sending = false
    var onClose: (() -> Void)?

    init(_ conn: NWConnection, secure: Bool) {
        self.conn = conn
        self.secure = secure
        loopback = Access.isLoopback(conn.endpoint)
    }

    func start(queue: DispatchQueue, gate: @escaping HTTPGate, handler: @escaping (HTTPRequest, HTTPConnection) -> Void) {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.onClose?(); self?.onClose = nil
            default: break
            }
        }
        conn.start(queue: queue)
        receive(gate, handler)
    }

    private func receive(_ gate: @escaping HTTPGate, _ handler: @escaping (HTTPRequest, HTTPConnection) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
            if let data { self.buffer.append(data) }
            if self.head == nil {
                switch self.parseHead() {
                case .incomplete:
                    if self.buffer.count > self.maxHead { return self.respond(431, text: "request head too large") }
                case .invalid:
                    return self.respond(400, text: "bad request")
                case .done(let h):
                    if let (status, text) = gate(h.method, h.path, h.query, h.length, self.secure, self.loopback) {
                        return self.respond(status, text: text)
                    }
                    self.head = h
                }
            }
            if let h = self.head, self.buffer.count - h.bodyStart >= h.length {
                let start = self.buffer.startIndex + h.bodyStart
                let body = self.buffer.subdata(in: start..<(start + h.length))
                return handler(HTTPRequest(method: h.method, path: h.path, query: h.query, headers: h.headers, body: body), self)
            }
            if done || error != nil { self.conn.cancel(); return }
            self.receive(gate, handler)
        }
    }

    private enum HeadResult {
        case incomplete, invalid
        case done((method: String, path: String, query: [String: String], headers: [String: String], bodyStart: Int, length: Int))
    }

    private func parseHead() -> HeadResult {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard end.lowerBound - buffer.startIndex <= maxHead,
              let text = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = text.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { return .invalid }   // only Content-Length bodies
        let length: Int
        if let cl = headers["content-length"] {
            guard let n = Int(cl), n >= 0 else { return .invalid }
            length = n
        } else { length = 0 }
        let target = String(parts[1])
        let comps = URLComponents(string: "http://h" + target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .done((String(parts[0]), comps?.path ?? target, query, headers, end.upperBound - buffer.startIndex, length))
    }

    func respond(_ status: Int = 200, _ type: String = "text/plain; charset=utf-8", _ body: Data) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 409: "Conflict", 413: "Payload Too Large",
                      431: "Request Header Fields Too Large", 500: "Error"][status] ?? "OK"
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
    private let secure: Bool
    let queue: DispatchQueue

    init(port: UInt16, parameters: NWParameters = .tcp, secure: Bool = false, queue: DispatchQueue = DispatchQueue(label: "http")) throws {
        self.queue = queue
        self.secure = secure
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start(gate: @escaping HTTPGate, _ handler: @escaping (HTTPRequest, HTTPConnection) -> Void) {
        listener.newConnectionHandler = { [queue, secure] nw in
            guard Access.admits(nw.endpoint) else { return nw.cancel() }
            HTTPConnection(nw, secure: secure).start(queue: queue, gate: gate, handler: handler)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let e) = state { print("Server failed: \(e)"); exit(1) }
        }
        listener.start(queue: queue)
    }
}
