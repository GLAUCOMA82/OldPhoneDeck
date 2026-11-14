import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio
import Darwin

/// Mac performance, volume, brightness and quick toggles for the iPad dashboard.
enum MacControls {

    // MARK: Performance

    private static var lastTicks: (busy: UInt64, total: UInt64)?

    /// CPU % since the previous call, memory used % (app + wired + compressed), disk used %.
    static func performance() -> [String: Double] {
        var out: [String: Double] = [:]
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        if withUnsafeMutablePointer(to: &load, { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) } }) == KERN_SUCCESS {
            let t = load.cpu_ticks
            let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)        // user + system + nice
            let total = busy + UInt64(t.2)                             // + idle
            if let last = lastTicks, total > last.total {
                out["cpu"] = Double(busy - last.busy) / Double(total - last.total) * 100
            }
            lastTicks = (busy, total)
        }
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        if withUnsafeMutablePointer(to: &vm, { $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount) } }) == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let used = (Double(vm.internal_page_count) - Double(vm.purgeable_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
            out["mem"] = min(100, used / Double(ProcessInfo.processInfo.physicalMemory) * 100)
        }
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
           let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage, total > 0 {
            out["disk"] = (1 - Double(free) / Double(total)) * 100
        }
        return out
    }

    // MARK: Volume + Mac microphone (CoreAudio)

    private static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr ? id : nil
    }

    private static func volumeAddress(input: Bool) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func volume(input: Bool = false) -> Double? {
        guard let dev = defaultDevice(input: input) else { return nil }
        var addr = volumeAddress(input: input)
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? Double(v) : nil
    }

    static func setVolume(_ value: Double, input: Bool = false) {
        guard let dev = defaultDevice(input: input) else { return }
        var addr = volumeAddress(input: input)
        var v = Float32(max(0, min(1, value)))
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    private static var micVolumeBeforeMute: Double?
    static var micMuted: Bool { (volume(input: true) ?? 1) < 0.01 }
    static func toggleMicMute() {
        if micMuted { setVolume(micVolumeBeforeMute ?? 0.75, input: true); micVolumeBeforeMute = nil }
        else { micVolumeBeforeMute = volume(input: true); setVolume(0, input: true) }
    }

    // MARK: Brightness
    // Built-in screen: private DisplayServices. External monitor: DDC/CI over Apple Silicon's
    // IOAVService (the approach used by tools like m1ddc / MonitorControl), VCP code 0x10.

    private typealias DSGet = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias DSSet = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias AVCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias AVWrite = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static let brightnessFile = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".phonedeck/brightness")

    private static var builtInDisplay: CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// 0–1, or nil when it can't be read (external monitors can't be read reliably; we remember the last value set).
    static func brightness() -> Double? {
        if let id = builtInDisplay, let ds, let sym = dlsym(ds, "DisplayServicesGetBrightness") {
            var b: Float = 0
            if unsafeBitCast(sym, to: DSGet.self)(id, &b) == 0 { return Double(b) }
        }
        if let s = try? String(contentsOf: brightnessFile, encoding: .utf8), let v = Double(s) { return v }
        return externalAVService() != nil ? 0.5 : nil
    }

    static func setBrightness(_ value: Double) {
        let v = max(0, min(1, value))
        if let id = builtInDisplay, let ds, let sym = dlsym(ds, "DisplayServicesSetBrightness") {
            _ = unsafeBitCast(sym, to: DSSet.self)(id, Float(v))
        }
        if ddcWrite(vcp: 0x10, value: UInt16(v * 100)) {
            try? String(v).write(to: brightnessFile, atomically: true, encoding: .utf8)
        }
    }

    /// Sends one DDC/CI "set VCP feature" command to the external monitor. False when there is no monitor or the write fails.
    @discardableResult
    private static func ddcWrite(vcp: UInt8, value: UInt16, repeats: Int = 1) -> Bool {
        guard let service = externalAVService(), let iokit, let sym = dlsym(iokit, "IOAVServiceWriteI2C") else { return false }
        let write = unsafeBitCast(sym, to: AVWrite.self)
        var data: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        data[5] = 0x6E ^ 0x51 ^ data[0] ^ data[1] ^ data[2] ^ data[3] ^ data[4]   // DDC checksum
        var ok = false
        for i in 0..<repeats {
            if i > 0 { usleep(50_000) }
            if data.withUnsafeMutableBytes({ write(service, 0x37, 0x51, $0.baseAddress!, 6) }) == KERN_SUCCESS { ok = true }
        }
        if !ok { cachedService = nil }   // the monitor may have been replugged; look it up again next time
        return ok
    }

    // MARK: Monitor input
    // DDC/CI VCP code 0x60. The values are the ones the MSI MD271UL lists in its capabilities string
    // (60(11 12 0F 10)); it has one DisplayPort socket, so "DisplayPort 2" (0x10) is its USB-C input.
    // Other monitors may use different values, often 0x1B for USB-C.

    static let monitorInputs: [String: UInt16] = ["hdmi1": 0x11, "hdmi2": 0x12, "dp": 0x0F, "usbc": 0x10]

    /// Switches the external monitor to `name` (a key of `monitorInputs`). False when the name is unknown or no monitor took the command.
    static func setMonitorInput(_ name: String) -> Bool {
        guard let code = monitorInputs[name] else { return false }
        return ddcWrite(vcp: 0x60, value: code, repeats: 2)
    }

    private static var cachedService: CFTypeRef?
    private static func externalAVService() -> CFTypeRef? {
        if let cachedService { return cachedService }
        guard let iokit, let sym = dlsym(iokit, "IOAVServiceCreateWithService") else { return nil }
        let create = unsafeBitCast(sym, to: AVCreate.self)
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if loc == "External", let svc = create(kCFAllocatorDefault, s)?.takeRetainedValue() {
                cachedService = svc
                return svc
            }
        }
        return nil
    }

    // MARK: Toggles

    static var darkMode: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String == "Dark"
    }
    static func toggleDarkMode() {
        _ = Music.osascript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
    }

    private static var caffeinate: Process?
    static var keepAwake: Bool { caffeinate?.isRunning == true }
    static func toggleKeepAwake() {
        if let p = caffeinate, p.isRunning { p.terminate(); caffeinate = nil; return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-d", "-i"]
        try? p.run()
        caffeinate = p
    }

    /// Window tiling (macOS 15+): clicks the frontmost app's Window menu → "Fill", or
    /// Window → Move & Resize → "Left & Right" (arranges the two frontmost windows side by side).
    /// UI scripting needs Accessibility permission for PhoneDeck. Returns nil on success, else a reason.
    static func tile(_ kind: String) -> String? {
        guard AXIsProcessTrusted() else { return "accessibility" }
        let item: String
        switch kind {
        case "fill":
            item = "click menu item \"Fill\" of menu 1 of menu bar item \"Window\" of menu bar 1"
        case "leftright":
            item = "click menu item \"Left & Right\" of menu 1 of menu item \"Move & Resize\" of menu 1 of menu bar item \"Window\" of menu bar 1"
        default:
            return "unknown"
        }
        let script = """
        tell application "System Events"
          set p to first application process whose frontmost is true
          tell p to \(item)
        end tell
        """
        return Music.osascript(script) == nil ? "menu" : nil
    }

    /// macOS has no public API to switch Focus; run the user's shortcut instead.
    static let focusShortcut = "PhoneDeck Focus"
    static func runFocusShortcut() -> Bool {
        Stats.run("/usr/bin/shortcuts", ["run", focusShortcut], timeout: 10) != nil
    }

    static func snapshot() -> [String: Any] {
        var s: [String: Any] = ["perf": performance(), "dark": darkMode, "awake": keepAwake, "micMuted": micMuted]
        if let v = volume() { s["volume"] = v }
        if let b = brightness() { s["brightness"] = b }
        return s
    }
}
