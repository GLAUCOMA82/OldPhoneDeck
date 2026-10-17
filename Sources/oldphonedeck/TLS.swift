import Foundation
import Network
import Security

/// A private certificate authority + server certificate so modern iPhones can open phonedeck
/// over HTTPS (Safari only allows camera/mic/speech on secure pages).
/// The CA is created once; trust it on the iPhone and every later server cert is accepted.
/// The server cert is re-issued automatically when the Mac's LAN address changes.
enum LocalTLS {
    static let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".oldphonedeck/tls")
    static var caDER: URL { dir.appendingPathComponent("oldphonedeck-ca.cer") }
    private static let p12Password = "oldphonedeck"

    /// Returns a TLS identity for `ip`, creating the CA and/or server cert as needed.
    static func identity(for ip: String) -> sec_identity_t? {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !exists("ca.key") || !exists("ca.pem") { try makeCA() }
            let stamp = (try? String(contentsOf: dir.appendingPathComponent("server.ip"), encoding: .utf8)) ?? ""
            if !exists("server.p12") || stamp != ip { try makeServerCert(ip: ip) }
            return try loadIdentity()
        } catch {
            print("⚠️  HTTPS disabled: \(error.localizedDescription)")
            return nil
        }
    }

    private static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    private static func openssl(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.currentDirectoryURL = dir
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "oldphonedeck.tls", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "openssl \(args.first ?? ""): \(msg)"])
        }
    }

    private static func makeCA() throws {
        // Self-signed via an explicit extfile: LibreSSL's "-extensions v3_ca" depends on the system openssl.cnf.
        try "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n"
            .write(to: dir.appendingPathComponent("ca.ext"), atomically: true, encoding: .utf8)
        try openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.csr",
                     "-subj", "/CN=OldPhoneDeck CA"])
        try openssl(["x509", "-req", "-in", "ca.csr", "-signkey", "ca.key", "-sha256", "-days", "3650",
                     "-extfile", "ca.ext", "-out", "ca.pem"])
        try openssl(["x509", "-in", "ca.pem", "-outform", "der", "-out", "oldphonedeck-ca.cer"])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.appendingPathComponent("ca.key").path)
    }

    private static func makeServerCert(ip: String) throws {
        // iOS requires: SAN entries, serverAuth EKU, and at most 825 days of validity.
        let ext = """
        basicConstraints=CA:FALSE
        keyUsage=digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        subjectAltName=IP:\(ip),IP:127.0.0.1,DNS:localhost
        """
        try ext.write(to: dir.appendingPathComponent("server.ext"), atomically: true, encoding: .utf8)
        try openssl(["req", "-newkey", "rsa:2048", "-nodes", "-keyout", "server.key", "-out", "server.csr",
                     "-subj", "/CN=\(ip)"])
        try openssl(["x509", "-req", "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial",
                     "-days", "800", "-sha256", "-extfile", "server.ext", "-out", "server.pem"])
        try openssl(["pkcs12", "-export", "-inkey", "server.key", "-in", "server.pem", "-certfile", "ca.pem",
                     "-out", "server.p12", "-passout", "pass:\(p12Password)"])
        try ip.write(to: dir.appendingPathComponent("server.ip"), atomically: true, encoding: .utf8)
    }

    private static func loadIdentity() throws -> sec_identity_t {
        let data = try Data(contentsOf: dir.appendingPathComponent("server.p12"))
        var items: CFArray?
        var opts: [String: Any] = [kSecImportExportPassphrase as String: p12Password]
        if #available(macOS 15.0, *) { opts[kSecImportToMemoryOnly as String] = true }   // don't touch the login keychain
        let status = SecPKCS12Import(data as CFData, opts as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let ref = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: "oldphonedeck.tls", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not load server identity (\(status))"])
        }
        let identity = ref as! SecIdentity
        guard let sec = sec_identity_create(identity) else {
            throw NSError(domain: "oldphonedeck.tls", code: -1, userInfo: [NSLocalizedDescriptionKey: "sec_identity_create failed"])
        }
        return sec
    }

    static func parameters(_ identity: sec_identity_t, websocket: Bool = false) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        let params = NWParameters(tls: tls)
        if websocket {
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            ws.maximumMessageSize = 8 << 20
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        }
        return params
    }
}
