import Darwin
import Foundation

struct CPUReading {
    var total: Double = 0        // 0...1
    var user: Double = 0
    var system: Double = 0
    var perCore: [Double] = []
}

struct MemoryReading {
    var appMemory: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cachedFiles: UInt64 = 0
    var used: UInt64 = 0
    var total: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0

    /// Roughly what Activity Monitor's pressure graph tracks.
    var pressure: Double {
        guard total > 0 else { return 0 }
        return Double(wired + compressed) / Double(total)
    }

    var usedFraction: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total)
    }
}

struct ProcessReading {
    var pid: Int32
    var cpu: Double        // percent of one core, as reported by ps
    var residentBytes: UInt64
    var command: String
}

/// The heaviest processes by CPU and, separately, by resident memory.
struct TopProcesses {
    var byCPU: [ProcessReading] = []
    var byMemory: [ProcessReading] = []
}

/// Samples host-wide CPU and memory counters via Mach APIs.
final class SystemSampler {

    // MARK: CPU

    private var previousTicks: [UInt32] = []

    func sampleCPU() -> CPUReading? {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size))
        }

        let ticks = UnsafeBufferPointer(start: info, count: Int(infoCount))
            .map { UInt32(bitPattern: $0) }

        defer { previousTicks = ticks }
        guard previousTicks.count == ticks.count else { return nil }  // first sample: no delta yet

        let stride = Int(CPU_STATE_MAX)
        var perCore: [Double] = []
        var busySum = 0.0, userSum = 0.0, systemSum = 0.0, totalSum = 0.0

        for core in 0..<Int(coreCount) {
            let base = core * stride
            func delta(_ state: Int32) -> Double {
                let i = base + Int(state)
                guard i < ticks.count else { return 0 }
                return Double(ticks[i] &- previousTicks[i])
            }
            let user = delta(CPU_STATE_USER) + delta(CPU_STATE_NICE)
            let sys = delta(CPU_STATE_SYSTEM)
            let idle = delta(CPU_STATE_IDLE)
            let total = user + sys + idle
            perCore.append(total > 0 ? (user + sys) / total : 0)
            busySum += user + sys
            userSum += user
            systemSum += sys
            totalSum += total
        }

        guard totalSum > 0 else { return nil }
        return CPUReading(
            total: busySum / totalSum,
            user: userSum / totalSum,
            system: systemSum / totalSum,
            perCore: perCore)
    }

    // MARK: Memory

    func sampleMemory() -> MemoryReading {
        var reading = MemoryReading()
        reading.total = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            reading.appMemory = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            reading.wired = UInt64(stats.wire_count) * page
            reading.compressed = UInt64(stats.compressor_page_count) * page
            reading.cachedFiles = UInt64(stats.external_page_count) * page
            reading.used = reading.appMemory + reading.wired + reading.compressed
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            reading.swapUsed = swap.xsu_used
            reading.swapTotal = swap.xsu_total
        }

        return reading
    }

    // MARK: Processes

    /// Shells out to `ps`. Only call this while the panel is visible — it is far more
    /// expensive than the Mach counters above.
    func sampleTopProcesses(limit: Int = 5) -> TopProcesses {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pid=,pcpu=,rss=,comm=", "-r"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return TopProcesses()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return TopProcesses() }
        var rows: [ProcessReading] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4,
                  let pid = Int32(fields[0]),
                  let cpu = Double(fields[1]),
                  let rssKB = UInt64(fields[2])
            else { continue }
            rows.append(ProcessReading(
                pid: pid,
                cpu: cpu,
                residentBytes: rssKB * 1024,
                command: String(fields[3]).trimmingCharacters(in: .whitespaces)))
        }
        // ps -r already sorts by CPU; memory needs its own ordering.
        return TopProcesses(
            byCPU: Array(rows.prefix(limit)),
            byMemory: Array(rows.sorted { $0.residentBytes > $1.residentBytes }.prefix(limit)))
    }
}
