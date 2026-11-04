import Foundation
import IOKit

/// Data for the Activity Monitor card: CPU and GPU load with ~10 minutes of history, memory and
/// its pressure, swap, and the busiest processes. Sampled every 2 s, kept in memory only.
final class Activity {
    static let interval: TimeInterval = 2
    static let keep = 300                          // samples: 300 x 2 s = 10 minutes

    private let queue = DispatchQueue(label: "activity")
    private var timer: DispatchSourceTimer?
    private var lastTicks: [UInt32]?               // user, system, idle, nice (cumulative)
    private var cpu: [Double] = []                 // % of all cores, newest last
    private var gpu: [Double] = []                 // % device utilization, newest last (empty: no GPU stats)
    private var mem: [String: Any] = [:]
    private var top: [[String: Any]] = []
    private var askedAt = Date.distantPast         // the process list is read only while someone looks
    private var topBusy = false

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Activity.interval)
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    func snapshot() -> [String: Any] {
        queue.sync {
            askedAt = Date()
            var d: [String: Any] = [
                "interval": Activity.interval,
                "cpu": Int((cpu.last ?? 0).rounded()), "cpuHistory": cpu.map { Int($0.rounded()) },
                "cores": ProcessInfo.processInfo.activeProcessorCount,
                "mem": mem, "top": top,
            ]
            if let g = gpu.last { d["gpu"] = Int(g.rounded()); d["gpuHistory"] = gpu.map { Int($0.rounded()) } }
            return d
        }
    }

    private func sample() {
        if let ticks = Activity.cpuTicks() {
            if let last = lastTicks {
                let delta = zip(ticks, last).map { Double($0 &- $1) }   // counters wrap: unsigned subtraction
                let total = delta.reduce(0, +)
                if total > 0 { push(&cpu, (total - delta[2]) / total * 100) }
            }
            lastTicks = ticks
        }
        if let g = Activity.gpuUtilization() { push(&gpu, g) }
        mem = Activity.memory()
        if Date().timeIntervalSince(askedAt) < 15, !topBusy {
            topBusy = true
            DispatchQueue.global().async {
                let list = Activity.topProcesses()
                self.queue.async { self.top = list; self.topBusy = false }
            }
        } else if Date().timeIntervalSince(askedAt) >= 15 {
            top = []
        }
    }

    private func push(_ a: inout [Double], _ v: Double) {
        a.append(max(0, min(100, v)))
        if a.count > Activity.keep { a.removeFirst(a.count - Activity.keep) }
    }

    // MARK: CPU (all cores together)

    static func cpuTicks() -> [UInt32]? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return [t.0, t.1, t.2, t.3]
    }

    // MARK: GPU (IOAccelerator's PerformanceStatistics: readable without root on Apple Silicon)

    static func gpuUtilization() -> Double? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var best: Double?
        var entry = IOIteratorNext(iter)
        while entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let u = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                best = max(best ?? 0, u)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iter)
        }
        return best
    }

    // MARK: Memory, pressure, swap

    static func memory() -> [String: Any] {
        var d: [String: Any] = ["total": Double(ProcessInfo.processInfo.physicalMemory)]
        var page: Int = 0
        var size = MemoryLayout<Int>.size
        if sysctlbyname("hw.pagesize", &page, &size, nil, 0) != 0 || page == 0 { page = 16384 }
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            // Activity Monitor's "Memory Used": app memory + wired + compressed.
            let app = Double(vm.internal_page_count) - Double(vm.purgeable_count)
            d["used"] = (app + Double(vm.wire_count) + Double(vm.compressor_page_count)) * Double(page)
            d["compressed"] = Double(vm.compressor_page_count) * Double(page)
        }
        var level: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            d["pressure"] = level >= 4 ? "critical" : level >= 2 ? "warn" : "normal"
        }
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            d["swapUsed"] = Double(swap.xsu_used)
            d["swapTotal"] = Double(swap.xsu_total)
        }
        return d
    }

    // MARK: Busiest processes (ps: % of one core, so it can pass 100)

    static func topProcesses() -> [[String: Any]] {
        guard let data = Stats.run("/bin/ps", ["-Aceo", "pcpu,comm", "-r"], timeout: 3),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [[String: Any]] = []
        for line in text.split(separator: "\n").dropFirst() {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard let sp = s.firstIndex(of: " "), let pct = Double(s[..<sp]) else { continue }
            let name = s[sp...].trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name == "ps" { continue }
            out.append(["name": name, "cpu": pct])
            if out.count == 3 { break }
        }
        return out
    }
}
