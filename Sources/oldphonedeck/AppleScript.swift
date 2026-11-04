import Foundation

/// AppleScript run inside this process with NSAppleScript, instead of a new /usr/bin/osascript per call
/// (a process launch costs ~80 ms; an in-process Apple Event to Chrome a few ms).
/// All scripts run on one dedicated thread, one at a time, compiled once and cached by source.
/// Two lanes: `urgent` work (a volume change under the finger) goes ahead of queued reads.
/// NSAppleScript cannot be killed like a process: only scripts that bound their own Apple Events
/// (`with timeout of N seconds`) belong here. The caller still stops waiting after `timeout`.
/// The signed app needs the com.apple.security.automation.apple-events entitlement (hardened runtime).
enum AppleScript {
    private final class Job {
        let source: String
        var result: String?
        var error: Int?
        let done = DispatchSemaphore(value: 0)
        init(_ source: String) { self.source = source }
    }

    private static let lock = NSCondition()
    private static var urgent: [Job] = []
    private static var normal: [Job] = []
    private static var cache: [String: NSAppleScript] = [:]   // touched only on the worker thread

    private static let worker: Thread = {
        let t = Thread { loop() }
        t.name = "applescript"
        t.qualityOfService = .userInitiated
        t.start()
        return t
    }()

    /// Output of the script as text ("" when it returns nothing), or nil when it failed or did not
    /// answer within `timeout` seconds.
    static func run(_ source: String, timeout: TimeInterval = 5, urgent isUrgent: Bool = false) -> String? {
        runDetailed(source, timeout: timeout, urgent: isUrgent).0
    }

    /// Like `run`, plus the AppleScript error number when it failed (-1743: no Automation permission).
    static func runDetailed(_ source: String, timeout: TimeInterval = 5, urgent isUrgent: Bool = false) -> (String?, Int?) {
        _ = worker
        let job = Job(source)
        lock.lock()
        if isUrgent { urgent.append(job) } else { normal.append(job) }
        lock.signal()
        lock.unlock()
        guard job.done.wait(timeout: .now() + timeout) == .success else {
            log("timeout after \(timeout) s")
            return (nil, nil)
        }
        return (job.result, job.error)
    }

    private static func loop() {
        while true {
            lock.lock()
            while urgent.isEmpty && normal.isEmpty { lock.wait() }
            let job = urgent.isEmpty ? normal.removeFirst() : urgent.removeFirst()
            lock.unlock()
            autoreleasepool { job.result = execute(job.source, &job.error) }
            job.done.signal()
        }
    }

    private static func execute(_ source: String, _ errorNumber: inout Int?) -> String? {
        let script: NSAppleScript
        if let s = cache[source] {
            script = s
        } else {
            guard let s = NSAppleScript(source: source) else { return nil }
            var err: NSDictionary?
            guard s.compileAndReturnError(&err) else { log("compile: \(err?[NSAppleScript.errorMessage] ?? "?")"); return nil }
            if cache.count >= 300 { cache.removeAll() }   // volume scripts differ only by value: bounded anyway
            cache[source] = s
            script = s
        }
        var err: NSDictionary?
        let out = script.executeAndReturnError(&err)
        if let err {
            errorNumber = err[NSAppleScript.errorNumber] as? Int
            log("error \(err[NSAppleScript.errorNumber] ?? "?"): \(err[NSAppleScript.errorMessage] ?? "?")")
            return nil
        }
        return out.stringValue ?? ""
    }

    /// At most one line every 10 s in the log, so a broken permission does not flood it.
    private static var lastLog = Date.distantPast
    private static let logLock = NSLock()
    static func log(_ msg: String) {
        logLock.lock(); defer { logLock.unlock() }
        guard Date().timeIntervalSince(lastLog) > 10 else { return }
        lastLog = Date()
        print("AppleScript: \(msg)")
    }
}
