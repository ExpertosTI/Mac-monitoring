import WidgetKit
import SwiftUI
import Darwin
import IOKit.ps

// MARK: - Timeline Entry

struct SystemEntry: TimelineEntry {
    let date: Date
    let cpu: Double
    let ram: Double
    let ramUsedGB: Double
    let ramTotalGB: Double
    let disk: Double
    let diskUsedGB: Double
    let diskTotalGB: Double
    let battery: Int
    let batteryConnected: Bool
    let networkDown: Double
    let networkUp: Double

    static var placeholder: SystemEntry {
        SystemEntry(date: .now, cpu: 45, ram: 72, ramUsedGB: 11.5, ramTotalGB: 16,
                    disk: 83, diskUsedGB: 189, diskTotalGB: 228,
                    battery: 82, batteryConnected: true, networkDown: 28_000, networkUp: 1_950_000)
    }
}

// MARK: - Provider

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SystemEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (SystemEntry) -> Void) {
        completion(context.isPreview ? .placeholder : readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SystemEntry>) -> Void) {
        let entry = readEntry()
        let next  = Calendar.current.date(byAdding: .minute, value: 2, to: entry.date)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func readEntry() -> SystemEntry {
        let cpu  = readCPU()
        let (ramPct, ramUsed, ramTotal) = readRAM()
        let (diskPct, diskUsed, diskTotal) = readDisk()
        let (bat, conn) = readBattery()
        return SystemEntry(date: .now, cpu: cpu, ram: ramPct, ramUsedGB: ramUsed, ramTotalGB: ramTotal,
                           disk: diskPct, diskUsedGB: diskUsed, diskTotalGB: diskTotal,
                           battery: bat, batteryConnected: conn, networkDown: 0, networkUp: 0)
    }

    // Quick system reads (no state, single snapshot)
    private func readCPU() -> Double {
        var info: processor_info_array_t?
        var numInfo: mach_msg_type_number_t = 0; var numCPUs: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &info, &numInfo) == KERN_SUCCESS,
              let i = info else { return 0 }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: i),
                              vm_size_t(numInfo) * vm_size_t(MemoryLayout<integer_t>.size)) }
        var t: UInt64 = 0; var idle: UInt64 = 0
        for n in 0..<Int(numCPUs) {
            let o = Int(CPU_STATE_MAX) * n
            t += UInt64(i[o+Int(CPU_STATE_USER)]+i[o+Int(CPU_STATE_SYSTEM)]+i[o+Int(CPU_STATE_IDLE)]+i[o+Int(CPU_STATE_NICE)])
            idle += UInt64(i[o+Int(CPU_STATE_IDLE)])
        }
        return t > 0 ? min(Double(t-idle)/Double(t)*100, 100) : 0
    }

    private func readRAM() -> (Double, Double, Double) {
        var s = vm_statistics64()
        var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size/MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &s) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) }
        }
        let pg = Double(vm_kernel_page_size)
        let tot = Double(ProcessInfo.processInfo.physicalMemory)
        let used = max(Double(s.active_count+s.wire_count+s.compressor_page_count-s.speculative_count)*pg, 0)
        let totGB = tot/1_073_741_824; let usedGB = used/1_073_741_824
        return (min(usedGB/totGB*100, 100), usedGB, totGB)
    }

    private func readDisk() -> (Double, Double, Double) {
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let t = v.volumeTotalCapacity, let a = v.volumeAvailableCapacityForImportantUsage else { return (0,0,0) }
        let td = Double(t)/1_073_741_824; let ad = Double(a)/1_073_741_824
        return (t > 0 ? (Double(t)-Double(a))/Double(t)*100 : 0, td-ad, td)
    }

    private func readBattery() -> (Int, Bool) {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef], !list.isEmpty,
              let info = IOPSGetPowerSourceDescription(snap, list[0])?.takeUnretainedValue() as? [String: Any]
        else { return (100, true) }
        return (info[kIOPSCurrentCapacityKey] as? Int ?? 100,
                (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
    }
}

// MARK: - Widget Views

struct SmallWidgetView: View {
    let entry: SystemEntry

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "waveform.path.ecg").foregroundStyle(.blue.gradient)
                Text("SysMonitor").font(.caption.weight(.bold))
                Spacer()
            }
            Divider()
            HStack(spacing: 8) {
                MiniRing(value: entry.cpu,  color: ringColor(entry.cpu),  label: "CPU")
                MiniRing(value: entry.ram,  color: ringColor(entry.ram),  label: "RAM")
                MiniRing(value: entry.disk, color: ringColor(entry.disk), label: "Disco")
            }
            HStack(spacing: 4) {
                Image(systemName: entry.batteryConnected ? "bolt.fill" : "battery.75")
                    .font(.caption2).foregroundColor(entry.batteryConnected ? .green : .primary)
                Text("\(entry.battery)%").font(.system(size: 9, design: .monospaced))
                Spacer()
                Text(Date(), style: .time).font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
        .padding(12)
        .containerBackground(.regularMaterial, for: .widget)
    }
}

struct MediumWidgetView: View {
    let entry: SystemEntry

    var body: some View {
        HStack(spacing: 12) {
            // Left: rings
            VStack(spacing: 6) {
                Text("SysMonitor").font(.caption.weight(.bold))
                HStack(spacing: 8) {
                    MiniRing(value: entry.cpu,  color: ringColor(entry.cpu),  label: "CPU")
                    MiniRing(value: entry.ram,  color: ringColor(entry.ram),  label: "RAM")
                    MiniRing(value: entry.disk, color: ringColor(entry.disk), label: "Disco")
                }
            }
            Divider()
            // Right: detail
            VStack(alignment: .leading, spacing: 6) {
                DetailStatRow(icon: "cpu",          label: "CPU",   value: "\(Int(entry.cpu))%",
                              color: ringColor(entry.cpu))
                DetailStatRow(icon: "memorychip",   label: "RAM",   value: String(format: "%.1f/%.0f GB", entry.ramUsedGB, entry.ramTotalGB),
                              color: ringColor(entry.ram))
                DetailStatRow(icon: "internaldrive",label: "Disco", value: String(format: "%.0f/%.0f GB", entry.diskUsedGB, entry.diskTotalGB),
                              color: ringColor(entry.disk))
                DetailStatRow(icon: entry.batteryConnected ? "bolt.fill" : "battery.75",
                              label: "Bat",  value: "\(entry.battery)%",
                              color: entry.batteryConnected ? .green : .primary)
            }
        }
        .padding(14)
        .containerBackground(.regularMaterial, for: .widget)
    }
}

struct MiniRing: View {
    let value: Double; let color: Color; let label: String
    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(color.opacity(0.2), lineWidth: 5)
                Circle().trim(from: 0, to: CGFloat(value)/100)
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(value))").font(.system(size: 9, weight: .bold, design: .monospaced))
            }
            .frame(width: 44, height: 44)
            Text(label).font(.system(size: 8)).foregroundColor(.secondary)
        }
    }
}

struct DetailStatRow: View {
    let icon: String; let label: String; let value: String; let color: Color
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(color).frame(width: 14)
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(color)
        }
    }
}

private func ringColor(_ v: Double) -> Color { v < 50 ? .green : v < 80 ? .orange : .red }

// MARK: - Widget

@main
struct SysMonitorWidgetBundle: Widget {
    let kind = "SysMonitorWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            if #available(macOS 14.0, *) {
                Group {
                    SmallWidgetView(entry: entry)
                }
            } else {
                SmallWidgetView(entry: entry)
            }
        }
        .configurationDisplayName("SysMonitor")
        .description("CPU, RAM y Disco en tiempo real")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
