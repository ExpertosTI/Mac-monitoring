import SwiftUI

// MARK: - Tab enum

enum AppTab: String, CaseIterable {
    case overview  = "Resumen"
    case processes = "Procesos"
    case settings  = "Ajustes"
    var icon: String {
        switch self {
        case .overview:  return "chart.bar.fill"
        case .processes: return "list.bullet"
        case .settings:  return "gearshape.fill"
        }
    }
}

// MARK: - Root

struct DetailView: View {
    @ObservedObject var monitor: SystemMonitor
    @StateObject private var prefs = Preferences.shared
    @State private var selectedTab: AppTab = .overview

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider()
            Group {
                switch selectedTab {
                case .overview:  OverviewTab(monitor: monitor)
                case .processes: ProcessesView(monitor: monitor)
                case .settings:  SettingsView(monitor: monitor, prefs: prefs)
                }
            }
        }
        .frame(width: 340)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(.blue.gradient).font(.title3)
            Text("SysMonitor").font(.headline)
            Spacer()
            Label(monitor.uptime, systemImage: "clock")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selectedTab = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon).font(.system(size: 13))
                        Text(tab.rawValue).font(.system(size: 9))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.secondary.opacity(0.05))
    }
}

// MARK: - Overview Tab

struct OverviewTab: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                ringRow
                sparklines
                Divider()
                batteryAndThermal
                Divider()
                networkSection
                if monitor.gpuTotalMB > 0 {
                    Divider()
                    gpuSection
                }
                Spacer(minLength: 8)
            }
            .padding(14)
        }
        .onAppear { monitor.refreshGPU() }
    }

    // MARK: Rings

    private var ringRow: some View {
        HStack(spacing: 8) {
            RingCard(icon: "cpu",          title: "CPU",   value: monitor.cpuUsage,
                     detail: String(format: "%.1f%%", monitor.cpuUsage))
            RingCard(icon: "memorychip",   title: "RAM",   value: monitor.ramUsagePercent,
                     detail: String(format: "%.1f/%.0fGB", monitor.ramUsedGB, monitor.ramTotalGB))
            RingCard(icon: "internaldrive",title: "Disco", value: monitor.diskUsagePercent,
                     detail: String(format: "%.0f/%.0fGB", monitor.diskUsedGB, monitor.diskTotalGB))
        }
    }

    // MARK: Sparklines

    private var sparklines: some View {
        VStack(spacing: 6) {
            SparklineChart(data: monitor.cpuHistory, color: .blue,
                           title: "CPU  (últimos 60 lecturas)",
                           latest: String(format: "%.1f%%", monitor.cpuUsage))
            SparklineChart(data: monitor.ramHistory, color: .purple,
                           title: "RAM",
                           latest: String(format: "%.1f%%", monitor.ramUsagePercent))
        }
    }

    // MARK: Battery + Thermal

    private var batteryAndThermal: some View {
        VStack(spacing: 8) {
            batteryRow
            thermalRow
        }
    }

    private var batteryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: batterySymbol)
                .foregroundStyle(batteryColor.gradient)
                .font(.system(size: 15))
            Text("Batería").font(.subheadline)
            Spacer()
            if monitor.batteryConnected {
                Text(monitor.batteryCharging ? "Cargando" : "Enchufado")
                    .font(.caption).foregroundColor(.secondary)
            }
            Text("\(monitor.batteryPercent)%")
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundColor(batteryColor)
        }
    }

    private var batterySymbol: String {
        if monitor.batteryConnected && monitor.batteryCharging { return "battery.100.bolt" }
        if monitor.batteryPercent > 75 { return "battery.100" }
        if monitor.batteryPercent > 50 { return "battery.75" }
        if monitor.batteryPercent > 25 { return "battery.50" }
        if monitor.batteryPercent > 10 { return "battery.25" }
        return "battery.0"
    }

    private var batteryColor: Color {
        monitor.batteryConnected ? .green :
        monitor.batteryPercent > 20 ? .primary : monitor.batteryPercent > 10 ? .orange : .red
    }

    private var thermalRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "thermometer.medium").foregroundColor(thermalColor)
            Text("Temperatura").font(.subheadline)
            Spacer()
            Text(thermalLabel)
                .font(.caption.weight(.semibold)).foregroundColor(thermalColor)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(thermalColor.opacity(0.15)))
        }
    }

    private var thermalColor: Color {
        switch monitor.thermalState {
        case .nominal: return .green
        case .fair:    return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }

    private var thermalLabel: String {
        switch monitor.thermalState {
        case .nominal: return "Normal"
        case .fair:    return "Tibia"
        case .serious: return "Caliente"
        case .critical: return "Crítico"
        @unknown default: return "Desconocido"
        }
    }

    // MARK: Network

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Red", systemImage: "network").font(.subheadline.weight(.semibold))

            HStack {
                NetworkSpeedRow(icon: "arrow.down.circle.fill", color: .blue,
                                label: "Descarga", speed: monitor.networkDownSpeed)
                Spacer()
                Divider().frame(height: 30)
                Spacer()
                NetworkSpeedRow(icon: "arrow.up.circle.fill", color: .green,
                                label: "Subida", speed: monitor.networkUpSpeed)
            }

            HStack(spacing: 6) {
                Image(systemName: "wifi").font(.caption).foregroundColor(.secondary)
                Text(monitor.networkInterface).font(.caption.weight(.semibold))
                Text("·").foregroundColor(.secondary)
                Text(monitor.localIP).font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(monitor.localIP, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }.buttonStyle(.plain).foregroundColor(.accentColor)
            }
        }
    }

    // MARK: GPU

    private var gpuSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.3.group.fill").foregroundStyle(.indigo.gradient)
            Text("GPU").font(.subheadline)
            Spacer()
            Text(String(format: "%.0f / %.0f MB", monitor.gpuUsedMB, monitor.gpuTotalMB))
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundColor(.indigo)
        }
    }
}

// MARK: - Sparkline

struct SparklineChart: View {
    let data: [Double]
    let color: Color
    let title: String
    let latest: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption2.weight(.semibold)).foregroundColor(.secondary)
                Spacer()
                Text(latest).font(.system(.caption2, design: .monospaced, weight: .bold)).foregroundColor(color)
            }
            GeometryReader { geo in
                ZStack {
                    sparkFill(size: geo.size).fill(color.opacity(0.18))
                    sparkLine(size: geo.size).stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func points(size: CGSize) -> [CGPoint] {
        guard data.count > 1 else { return [] }
        let max = Swift.max(data.max() ?? 100, 1)
        let step = size.width / CGFloat(data.count - 1)
        return data.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) * step, y: size.height - size.height * CGFloat(v) / CGFloat(max))
        }
    }

    private func sparkLine(size: CGSize) -> Path {
        var p = Path()
        let pts = points(size: size)
        guard let first = pts.first else { return p }
        p.move(to: first)
        pts.dropFirst().forEach { p.addLine(to: $0) }
        return p
    }

    private func sparkFill(size: CGSize) -> Path {
        var p = sparkLine(size: size)
        p.addLine(to: CGPoint(x: size.width, y: size.height))
        p.addLine(to: CGPoint(x: 0, y: size.height))
        p.closeSubpath()
        return p
    }
}

// MARK: - Ring Card

struct RingCard: View {
    let icon: String
    let title: String
    let value: Double
    let detail: String

    private var ringColor: Color { value < 50 ? .green : value < 80 ? .orange : .red }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(ringColor.opacity(0.15), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: min(CGFloat(value) / 100, 1))
                    .stroke(ringColor.gradient, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: value)
                VStack(spacing: 1) {
                    Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(ringColor.gradient)
                    Text("\(Int(value))%").font(.system(size: 12, weight: .bold, design: .monospaced))
                }
            }
            .frame(width: 70, height: 70)
            Text(title).font(.caption.weight(.semibold))
            Text(detail).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(.secondary.opacity(0.07)))
    }
}

// MARK: - Network Speed Row

struct NetworkSpeedRow: View {
    let icon: String; let color: Color; let label: String; let speed: Double
    private var formatted: String {
        switch speed {
        case ..<1_024:     return String(format: "%.0f B/s",  speed)
        case ..<1_048_576: return String(format: "%.1f KB/s", speed / 1_024)
        default:           return String(format: "%.2f MB/s", speed / 1_048_576)
        }
    }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(color.gradient)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption2).foregroundColor(.secondary)
                Text(formatted).font(.system(.caption, design: .monospaced, weight: .bold))
                    .contentTransition(.numericText()).animation(.easeInOut(duration: 0.3), value: formatted)
            }
        }
    }
}
