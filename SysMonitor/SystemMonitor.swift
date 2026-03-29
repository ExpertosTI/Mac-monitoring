import Foundation
import Darwin

struct RunningProcess: Identifiable {
    let id: Int32    // PID
    let name: String
    let ramMB: Double
    let cpu: Double
}

class SystemMonitor: ObservableObject {
    // MARK: - Published metrics
    @Published var cpuUsage: Double = 0
    @Published var ramUsagePercent: Double = 0
    @Published var ramUsedGB: Double = 0
    @Published var ramTotalGB: Double = 0
    @Published var diskUsagePercent: Double = 0
    @Published var diskUsedGB: Double = 0
    @Published var diskTotalGB: Double = 0
    @Published var diskFreeGB: Double = 0
    @Published var networkDownSpeed: Double = 0
    @Published var networkUpSpeed: Double = 0
    @Published var topRamProcesses: [RunningProcess] = []

    private var lastNetworkBytesIn: UInt64 = 0
    private var lastNetworkBytesOut: UInt64 = 0
    private var lastNetworkTime = Date()

    // MARK: - Periodic refresh (lightweight, always-on)

    func refresh() {
        cpuUsage = getCPUUsage()
        getRAMUsage()
        getDiskUsage()
        getNetworkSpeed()
        // Process list is NOT fetched here — only on demand from the popover
    }

    // MARK: - Process list (only called when popover is visible)

    func fetchTopProcesses() async {
        let processes = await Task.detached(priority: .utility) { [weak self] in
            self?.readTopProcesses() ?? []
        }.value
        await MainActor.run { self.topRamProcesses = processes }
    }

    private func readTopProcesses() -> [RunningProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        // pid, %cpu, rss (KB), command name (no path, no args)
        task.arguments = ["-axco", "pid,pcpu,rss,comm"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError  = errPipe

        do {
            try task.run()
            task.waitUntilExit()
        } catch { return [] }

        guard let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                                  encoding: .utf8) else { return [] }

        return output
            .components(separatedBy: "\n")
            .dropFirst()               // skip header
            .compactMap { parsePSLine($0) }
            .sorted { $0.ramMB > $1.ramMB }
            .prefix(8)
            .map { $0 }
    }

    private func parsePSLine(_ line: String) -> RunningProcess? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4,
              let pid  = Int32(parts[0]),
              let cpu  = Double(parts[1]),
              let rssKB = Double(parts[2]) else { return nil }
        let name = parts[3...].joined(separator: " ")
        guard !name.isEmpty else { return nil }
        return RunningProcess(id: pid, name: name, ramMB: rssKB / 1024, cpu: cpu)
    }

    // MARK: - CPU

    private func getCPUUsage() -> Double {
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
            &numCPUs, &cpuInfo, &numCPUInfo
        )
        guard result == KERN_SUCCESS, let info = cpuInfo else { return 0 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        var totalTicks: UInt64 = 0
        var idleTicks: UInt64 = 0
        for i in 0..<Int(numCPUs) {
            let o = Int(CPU_STATE_MAX) * i
            totalTicks += UInt64(info[o + Int(CPU_STATE_USER)])
            totalTicks += UInt64(info[o + Int(CPU_STATE_SYSTEM)])
            totalTicks += UInt64(info[o + Int(CPU_STATE_IDLE)])
            totalTicks += UInt64(info[o + Int(CPU_STATE_NICE)])
            idleTicks  += UInt64(info[o + Int(CPU_STATE_IDLE)])
        }
        let busy = totalTicks - idleTicks
        return totalTicks > 0 ? min(Double(busy) / Double(totalTicks) * 100, 100) : 0
    }

    // MARK: - RAM

    private func getRAMUsage() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let pageSize    = Double(vm_kernel_page_size)
        let total       = Double(ProcessInfo.processInfo.physicalMemory)
        let active      = Double(stats.active_count) * pageSize
        let wired       = Double(stats.wire_count) * pageSize
        let compressed  = Double(stats.compressor_page_count) * pageSize
        let speculative = Double(stats.speculative_count) * pageSize
        let used        = max(active + wired + compressed - speculative, 0)

        ramTotalGB      = total / 1_073_741_824
        ramUsedGB       = used  / 1_073_741_824
        ramUsagePercent = min((ramUsedGB / ramTotalGB) * 100, 100)
    }

    // MARK: - Disk

    private func getDiskUsage() {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [
                  .volumeTotalCapacityKey,
                  .volumeAvailableCapacityForImportantUsageKey]),
              let total     = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return }

        let t = Double(total), a = Double(available)
        diskTotalGB      = t / 1_073_741_824
        diskFreeGB       = a / 1_073_741_824
        diskUsedGB       = diskTotalGB - diskFreeGB
        diskUsagePercent = t > 0 ? ((t - a) / t) * 100 : 0
    }

    // MARK: - Network

    private func getNetworkSpeed() {
        let (bytesIn, bytesOut) = currentNetworkBytes()
        let now     = Date()
        let elapsed = now.timeIntervalSince(lastNetworkTime)

        if elapsed > 0 && lastNetworkBytesIn > 0 {
            let dIn  = bytesIn  >= lastNetworkBytesIn  ? bytesIn  - lastNetworkBytesIn  : 0
            let dOut = bytesOut >= lastNetworkBytesOut ? bytesOut - lastNetworkBytesOut : 0
            networkDownSpeed = Double(dIn)  / elapsed
            networkUpSpeed   = Double(dOut) / elapsed
        }
        lastNetworkBytesIn  = bytesIn
        lastNetworkBytesOut = bytesOut
        lastNetworkTime     = now
    }

    private func currentNetworkBytes() -> (UInt64, UInt64) {
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var ifap: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifap) == 0, let first = ifap else { return (0, 0) }
        defer { freeifaddrs(ifap) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let addr = current {
            let flags = Int32(addr.pointee.ifa_flags)
            if (flags & IFF_LOOPBACK) == 0 && (flags & IFF_UP) != 0,
               addr.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               let raw = addr.pointee.ifa_data {
                let stats = raw.assumingMemoryBound(to: if_data.self)
                totalIn  += UInt64(stats.pointee.ifi_ibytes)
                totalOut += UInt64(stats.pointee.ifi_obytes)
            }
            current = addr.pointee.ifa_next
        }
        return (totalIn, totalOut)
    }
}
