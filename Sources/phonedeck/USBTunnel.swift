import Foundation

/// Carries the deck over the USB cable, for a phone that has no network path to the Mac
/// (the iPhone 4S without Wi-Fi: it has no Personal Hotspot, so it never offers a USB network).
///
/// A cable only lets the Mac open connections *to* the phone, through macOS's usbmuxd (the same
/// channel Finder and Xcode use). So the direction is reversed: the Mac keeps a few idle
/// connections open to the PhoneCam app (port 27045 on the phone). When the phone's web view or
/// camera link needs the Mac, PhoneCam takes one idle connection, sends two bytes naming the Mac
/// port it wants (big-endian), and from then on the connection is a plain byte pipe to that port
/// on localhost. Each used connection is replaced by a new idle one.
enum USBTunnel {
    static let phonePort: UInt16 = 27045
    private static let idleConnections = 6
    private static var allowedPorts: Set<UInt16> = []
    private static let lock = NSLock()
    private static var devices: [Int: Device] = [:]
    /// Set PHONEDECK_USB_DEBUG=1 to log every attach, detach and connection attempt.
    private static let debug = ProcessInfo.processInfo.environment["PHONEDECK_USB_DEBUG"] != nil

    private final class Device {
        let id: Int
        var attached = true      // guarded by USBTunnel.lock
        var up = false           // guarded by USBTunnel.lock
        let slots = DispatchSemaphore(value: USBTunnel.idleConnections)
        init(id: Int) { self.id = id }
    }

    /// `ports`: the localhost ports a phone may ask for (the deck's HTTP port and the camera/mic port).
    static func start(ports: [UInt16]) {
        allowedPorts = Set(ports)
        signal(SIGPIPE, SIG_IGN)
        Thread.detachNewThread { while true { watchDevices(); Thread.sleep(forTimeInterval: 3) } }
    }

    // MARK: Devices

    /// Follows usbmuxd's attach/detach events until its socket closes.
    private static func watchDevices() {
        guard let fd = muxSocket() else { return }
        defer {
            close(fd)
            lock.lock(); let all = Array(devices.values); devices.removeAll(); all.forEach { $0.attached = false }; lock.unlock()
        }
        guard send(fd, ["MessageType": "Listen"]) else { return }
        while let msg = receive(fd) {
            guard let id = msg["DeviceID"] as? Int else { continue }   // also skips the reply to Listen
            switch msg["MessageType"] as? String {
            case "Attached":
                guard (msg["Properties"] as? [String: Any])?["ConnectionType"] as? String == "USB" else { continue }
                let dev = Device(id: id)
                if debug { print("USB cable: device \(id) attached") }
                lock.lock(); devices[id]?.attached = false; devices[id] = dev; lock.unlock()
                Thread.detachNewThread { keepConnected(dev) }
            case "Detached":
                lock.lock(); let dev = devices.removeValue(forKey: id); dev?.attached = false; lock.unlock()
                if let dev { setUp(dev, false) }
                if debug { print("USB cable: device \(id) detached") }
            default: break
            }
        }
    }

    private static func isAttached(_ dev: Device) -> Bool { lock.lock(); defer { lock.unlock() }; return dev.attached }

    private static func setUp(_ dev: Device, _ up: Bool) {
        lock.lock(); let changed = dev.up != up; dev.up = up; lock.unlock()
        if changed { print(up ? "USB cable: deck link to the phone is up" : "USB cable: deck link to the phone is down") }
    }

    /// Keeps `idleConnections` idle connections open to PhoneCam on one phone, for as long as it is plugged in.
    private static func keepConnected(_ dev: Device) {
        while true {
            dev.slots.wait()
            guard isAttached(dev) else { dev.slots.signal(); return }
            guard let fd = connect(to: dev) else {
                // Not a phone running PhoneCam (or the app is closed): try again quietly.
                dev.slots.signal(); setUp(dev, false)
                Thread.sleep(forTimeInterval: 3); continue
            }
            setUp(dev, true)
            Thread.detachNewThread { serve(fd, dev) }
        }
    }

    private static func connect(to dev: Device) -> Int32? {
        guard let fd = muxSocket() else { return nil }
        // usbmuxd wants the port in network byte order, stored as a plain integer.
        guard send(fd, ["MessageType": "Connect", "DeviceID": dev.id, "PortNumber": Int(phonePort.bigEndian)]),
              let reply = receive(fd) else { close(fd); return nil }
        // 0 = connected; 3 = nothing is listening on the phone (PhoneCam closed, or a version without the relay).
        let result = reply["Number"] as? Int
        if debug { print("USB cable: connect to device \(dev.id) port \(phonePort) → \(result.map(String.init) ?? "no result")") }
        guard result == 0 else { close(fd); return nil }
        return fd
    }

    /// Waits for the phone to claim this connection, then pipes it to the Mac port it names.
    private static func serve(_ fd: Int32, _ dev: Device) {
        let head = readExactly(fd, 2)
        dev.slots.signal()   // no longer idle (claimed or dead): let a replacement open
        guard let head else { close(fd); return }
        let port = UInt16(head[0]) << 8 | UInt16(head[1])
        guard allowedPorts.contains(port), let local = localSocket(port: port) else { close(fd); return }
        pipe(fd, local)
    }

    // MARK: Sockets

    private static func pipe(_ a: Int32, _ b: Int32) {
        let done = DispatchGroup()
        for (from, to) in [(a, b), (b, a)] {
            done.enter()
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 32 * 1024)
                while true {
                    let n = read(from, &buf, buf.count)
                    if n <= 0 || !writeAll(to, buf, n) { break }
                }
                // Either side ending ends the pair; data already written is still delivered.
                shutdown(a, SHUT_RDWR); shutdown(b, SHUT_RDWR)
                done.leave()
            }
        }
        done.wait()
        close(a); close(b)
    }

    private static func noSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func muxSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        noSigPipe(fd)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, "/var/run/usbmuxd", capacity) }
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 { close(fd); return nil }
        return fd
    }

    private static func localSocket(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        noSigPipe(fd)
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 { close(fd); return nil }
        return fd
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8], _ count: Int) -> Bool {
        var off = 0
        while off < count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + off, count - off) }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: count), off = 0
        while off < count {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + off, count - off) }
            if n <= 0 { return nil }
            off += n
        }
        return buf
    }

    // MARK: usbmuxd messages (16-byte little-endian header: length, version 1, type 8 = plist, tag; then an XML plist)

    private static func send(_ fd: Int32, _ message: [String: Any]) -> Bool {
        var m = message
        m["ClientVersionString"] = "phonedeck"; m["ProgName"] = "phonedeck"; m["kLibUSBMuxVersion"] = 3
        guard let body = try? PropertyListSerialization.data(fromPropertyList: m, format: .xml, options: 0) else { return false }
        var bytes = [UInt8]()
        for v in [UInt32(16 + body.count), 1, 8, 1] { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
        bytes.append(contentsOf: body)
        return writeAll(fd, bytes, bytes.count)
    }

    private static func receive(_ fd: Int32) -> [String: Any]? {
        guard let head = readExactly(fd, 16) else { return nil }
        let length = Int(head[0]) | Int(head[1]) << 8 | Int(head[2]) << 16 | Int(head[3]) << 24
        guard length >= 16, length < 1 << 20, let body = readExactly(fd, length - 16) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: Data(body), format: nil)) as? [String: Any]
    }
}
