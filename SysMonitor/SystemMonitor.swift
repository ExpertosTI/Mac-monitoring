import Foundation
import Darwin
import IOKit.ps
import Metal

struct RunningProcess: Identifiable {
    let id: Int32
    let name: String
    let ramMB: Double
    let cpu: Double
}

class SystemMonitor: ObservableObject {
    // MARK: - Core metrics
    @Published var cpuUsage: Double = 0
    @Published var ramUsagePercent: Double = 0
    @Published var ramUsedGB: Double = 0
    @Published var ramTotalGB: Double = 0
    @Published var diskUsagePercent: Double = 0
    @Published var diskUsedGB: Double = 0
    @Published var diskTotalGB: Double = 0
    @Published var diskFreeGB: Double = 0

    // MARK: - Network
    @Published var networkDownSpeed: Double = 0
    @Published var networkUpSpeed: Double = 0
    @Published var networkInterface: String = "--"
    @Published var localIP: String = "--"

    // MARK: - Battery
    @Published var batteryPercent: Int = 100
    @Published var batteryCharging: Bool = false
    @Published var batteryConnected: Bool = true

    // MARK: - System info
    @Published var uptime: String = ""
    @Published var thermalState: ProcessInfo.ThermalState = .nominal

    // MARK: - GPU
    @Published var gpuUsedMB: Double = 0
    @Published var gpuTotalMB: Double = 0

    // MARK: - History (60 readings ≈ 2 min with default 2s interval)
    @Published var cpuHistory: [Double] = Array(repeating: 0, count: 60)
    @Published var ramHistory: [Double] = Array(repeating: 0, count: 60)

    // MARK: - Processes (populated on demand)
    @Published var topRamProcesses: [RunningProcess] = []
    @Published var topCpuProcesses: [RunningProcess] = []

    private var lastNetworkBytesIn: UInt64 = 0
    private var lastNetworkBytesOut: UInt64 = 0
    private var lastNetworkTime = Date()

    private lazy var metalDevice = MTLCreateSystemDefaultDevice()

    // MARK: - Main refresh (lightweight, runs on timer)

    func refresh() {
        cpuUsage = getCPUUsage()
        getRAMUsage()
        getDiskUsage()
        getNetworkSpeed()
        getNetworkInterface()
        getBattery()
        uptime = getUptime()
        thermalState = ProcessInfo.processInfo.thermalState

        cpuHistory.removeFirst(); cpuHistory.append(cpuUsage)
        ramHistory.removeFirst(); ramHistory.append(ramUsagePercent)
    }

    // MARK: - On-demand (popover open)

    func fetchTopProcesses() async {
        let all = await Task.detached(priority: .utility) { [weak self] in
            self?.readAllProcesses() ?? []
        }.value
        await MainActor.run {
            self.topRamProcesses = Array(all.sorted { $0.ramMB > $1.ramMB }.prefix(15))
            self.topCpuProcesses = Array(all.sorted { $0.cpu  > $1.cpu  }.prefix(15))
        }
    }

    func refreshGPU() {
        guard let dev = metalDevice else { return }
        gpuUsedMB  = Double(dev.currentAllocatedSize)       / 1_048_576
        gpuTotalMB = Double(dev.recommendedMaxWorkingSetSize) / 1_048_576
    }

    func killProcess(_ pid: Int32) -> Bool {
        if kill(pid, SIGTERM) == 0 { return true }
        return kill(pid, SIGKILL) == 0
    }

    // MARK: - CPU

    private func getCPUUsage() -> Double {
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &numCPUs, &cpuInfo, &numCPUInfo)
        guard result == KERN_SUCCESS, let info = cpuInfo else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        var total: UInt64 = 0; var idle: UInt64 = 0
        for i in 0..<Int(numCPUs) {
            let o = Int(CPU_STATE_MAX) * i
            total += UInt64(info[o + Int(CPU_STATE_USER)])
            total += UInt64(info[o + Int(CPU_STATE_SYSTEM)])
            total += UInt64(info[o + Int(CPU_STATE_IDLE)])
            total += UInt64(info[o + Int(CPU_STATE_NICE)])
            idle  += UInt64(info[o + Int(CPU_STATE_IDLE)])
        }
        return total > 0 ? min(Double(total - idle) / Double(total) * 100, 100) : 0
    }

    // MARK: - RAM

    private func getRAMUsage() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return }
        let pg = Double(vm_kernel_page_size)
        let tot = Double(ProcessInfo.processInfo.physicalMemory)
        let used = max(Double(stats.active_count + stats.wire_count + stats.compressor_page_count
                              - stats.speculative_count) * pg, 0)
        ramTotalGB     = tot  / 1_073_741_824
        ramUsedGB      = used / 1_073_741_824
        ramUsagePercent = min(ramUsedGB / ramTotalGB * 100, 100)
    }

    // MARK: - Disk

    private func getDiskUsage() {
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
                  .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let t = v.volumeTotalCapacity, let a = v.volumeAvailableCapacityForImportantUsage else { return }
        let td = Double(t), ad = Double(a)
        diskTotalGB = td / 1_073_741_824; diskFreeGB = ad / 1_073_741_824
        diskUsedGB = diskTotalGB - diskFreeGB
        diskUsagePercent = td > 0 ? (td - ad) / td * 100 : 0
    }

    // MARK: - Network speed

    private func getNetworkSpeed() {
        let (bytesIn, bytesOut) = currentNetworkBytes()
        let now = Date(); let elapsed = now.timeIntervalSince(lastNetworkTime)
        if elapsed > 0 && lastNetworkBytesIn > 0 {
            networkDownSpeed = Double(bytesIn  >= lastNetworkBytesIn  ? bytesIn  - lastNetworkBytesIn  : 0) / elapsed
            networkUpSpeed   = Double(bytesOut >= lastNetworkBytesOut ? bytesOut - lastNetworkBytesOut : 0) / elapsed
        }
        lastNetworkBytesIn = bytesIn; lastNetworkBytesOut = bytesOut; lastNetworkTime = now
    }

    private func currentNetworkBytes() -> (UInt64, UInt64) {
        var totalIn: UInt64 = 0; var totalOut: UInt64 = 0
        var ifap: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifap) == 0, let first = ifap else { return (0, 0) }
        defer { freeifaddrs(ifap) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let a = cur {
            let f = Int32(a.pointee.ifa_flags)
            if (f & IFF_LOOPBACK) == 0 && (f & IFF_UP) != 0,
               a.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               let raw = a.pointee.ifa_data {
                let s = raw.assumingMemoryBound(to: if_data.self)
                totalIn += UInt64(s.pointee.ifi_ibytes); totalOut += UInt64(s.pointee.ifi_obytes)
            }
            cur = a.pointee.ifa_next
        }
        return (totalIn, totalOut)
    }

    // MARK: - Network interface + IP

    private func getNetworkInterface() {
        var ifap: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifap) == 0, let first = ifap else { return }
        defer { freeifaddrs(ifap) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let a = cur {
            let f = Int32(a.pointee.ifa_flags)
            if (f & IFF_LOOPBACK) == 0 && (f & IFF_UP) != 0 && (f & IFF_RUNNING) != 0,
               a.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
               let sa = a.pointee.ifa_addr {
                networkInterface = String(cString: a.pointee.ifa_name)
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var addr = sin.pointee.sin_addr
                    inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                }
                localIP = String(cString: buf)
                return
            }
            cur = a.pointee.ifa_next
        }
        networkInterface = "--"; localIP = "--"
    }

    // MARK: - Battery

    private func getBattery() {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef],
              !list.isEmpty,
              let info = IOPSGetPowerSourceDescription(snap, list[0])?.takeUnretainedValue() as? [String: Any]
        else { batteryConnected = true; return }
        batteryPercent   = info[kIOPSCurrentCapacityKey] as? Int ?? 100
        batteryConnected = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        batteryCharging  = info[kIOPSIsChargingKey] as? Bool ?? false
    }

    // MARK: - Uptime

    private func getUptime() -> String {
        var boottime = timeval(); var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        sysctl(&mib, 2, &boottime, &size, nil, 0)
        let elapsed = Int(Date().timeIntervalSince1970) - Int(boottime.tv_sec)
        let d = elapsed / 86400; let h = (elapsed % 86400) / 3600; let m = (elapsed % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    // MARK: - Process list

    private func readAllProcesses() -> [RunningProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axco", "pid,pcpu,rss,comm"]
        let out = Pipe(); task.standardOutput = out; task.standardError = Pipe()
        do { try task.run(); task.waitUntilExit() } catch { return [] }
        guard let txt = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return [] }
        return txt.components(separatedBy: "\n").dropFirst().compactMap { parsePSLine($0) }
    }

    private func parsePSLine(_ line: String) -> RunningProcess? {
        let p = line.split(separator: " ", omittingEmptySubsequences: true)
        guard p.count >= 4, let pid = Int32(p[0]), let cpu = Double(p[1]), let rss = Double(p[2]) else { return nil }
        let name = p[3...].joined(separator: " ")
        return name.isEmpty ? nil : RunningProcess(id: pid, name: name, ramMB: rss / 1024, cpu: cpu)
    }
}
