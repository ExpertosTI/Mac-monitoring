import SwiftUI
import ServiceManagement

// RAM threshold above which the process list auto-appears
private let ramAlertThreshold: Double = 70

struct DetailView: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var showProcesses = false

    var ramIsHigh: Bool { monitor.ramUsagePercent >= ramAlertThreshold }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                header
                Divider()
                ringGrid
                Divider()
                networkSection
                Divider()

                // Process section: always visible toggle, auto-expands when RAM is high
                processToggleRow

                if showProcesses {
                    Divider()
                    processSection
                        // Fetch once on appear, then every 3s while visible
                        .task {
                            await monitor.fetchTopProcesses()
                            while !Task.isCancelled {
                                try? await Task.sleep(nanoseconds: 3_000_000_000)
                                await monitor.fetchTopProcesses()
                            }
                        }
                }

                Divider()
                settingsRow
            }
        }
        .frame(width: 340)
        .background(.regularMaterial)
        .onAppear {
            // Auto-expand when RAM is already high
            if ramIsHigh { showProcesses = true }
        }
        .onChange(of: monitor.ramUsagePercent) { _, newValue in
            if newValue >= ramAlertThreshold && !showProcesses {
                withAnimation { showProcesses = true }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(.blue.gradient)
                .font(.title3)
            Text("SysMonitor")
                .font(.headline)
            Spacer()
            Text("renace.tech")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.secondary.opacity(0.15)))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Rings

    private var ringGrid: some View {
        HStack(spacing: 8) {
            RingCard(
                icon: "cpu",
                title: "CPU",
                value: monitor.cpuUsage,
                detail: String(format: "%.1f%%", monitor.cpuUsage)
            )
            RingCard(
                icon: "memorychip",
                title: "RAM",
                value: monitor.ramUsagePercent,
                detail: String(format: "%.1f/%.0fGB", monitor.ramUsedGB, monitor.ramTotalGB)
            )
            RingCard(
                icon: "internaldrive",
                title: "Disco",
                value: monitor.diskUsagePercent,
                detail: String(format: "%.0f/%.0fGB", monitor.diskUsedGB, monitor.diskTotalGB)
            )
        }
        .padding(16)
    }

    // MARK: - Network

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Red", systemImage: "network")
                .font(.subheadline.weight(.semibold))

            HStack {
                NetworkSpeedRow(icon: "arrow.down.circle.fill", color: .blue,
                                label: "Descarga", speed: monitor.networkDownSpeed)
                Spacer()
                Divider().frame(height: 30)
                Spacer()
                NetworkSpeedRow(icon: "arrow.up.circle.fill", color: .green,
                                label: "Subida", speed: monitor.networkUpSpeed)
            }
        }
        .padding(16)
    }

    // MARK: - Process toggle row

    private var processToggleRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                showProcesses.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                if ramIsHigh {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange.gradient)
                } else {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundColor(.secondary)
                }
                Text(ramIsHigh ? "RAM alta — ver procesos" : "Procesos activos")
                    .font(.subheadline.weight(ramIsHigh ? .semibold : .regular))
                    .foregroundColor(ramIsHigh ? .orange : .primary)
                Spacer()
                Image(systemName: showProcesses ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Process list

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column headers
            HStack {
                Text("Proceso")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("RAM")
                    .frame(width: 64, alignment: .trailing)
                Text("CPU")
                    .frame(width: 50, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            if monitor.topRamProcesses.isEmpty {
                HStack {
                    ProgressView().scaleEffect(0.7)
                    Text("Cargando…").font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
            } else {
                ForEach(Array(monitor.topRamProcesses.enumerated()), id: \.element.id) { index, proc in
                    ProcessRow(process: proc, index: index)
                }
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - Settings

    private var settingsRow: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $launchAtLogin) {
                Label("Inicio automático", systemImage: "power.circle")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: launchAtLogin) { _, newValue in
                do {
                    if newValue { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch { launchAtLogin = !newValue }
            }

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Salir", systemImage: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }
}

// MARK: - Process Row

struct ProcessRow: View {
    let process: RunningProcess
    let index: Int

    private var ramColor: Color {
        process.ramMB > 500 ? .red : process.ramMB > 200 ? .orange : .primary
    }

    private var formattedRAM: String {
        process.ramMB >= 1024
            ? String(format: "%.1f GB", process.ramMB / 1024)
            : String(format: "%.0f MB", process.ramMB)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Rank indicator
            Text("\(index + 1)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 14)

            // Process name
            Text(process.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            // RAM usage
            Text(formattedRAM)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(ramColor)
                .frame(width: 64, alignment: .trailing)

            // CPU
            Text(String(format: "%.1f%%", process.cpu))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(process.cpu > 20 ? .orange : .secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(index % 2 == 0 ? Color.clear : Color.secondary.opacity(0.05))
    }
}

// MARK: - Ring Card

struct RingCard: View {
    let icon: String
    let title: String
    let value: Double
    let detail: String

    private var ringColor: Color {
        value < 50 ? .green : value < 80 ? .orange : .red
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(ringColor.opacity(0.15), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: min(CGFloat(value) / 100, 1))
                    .stroke(ringColor.gradient,
                            style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: value)
                VStack(spacing: 1) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ringColor.gradient)
                    Text("\(Int(value))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                }
            }
            .frame(width: 72, height: 72)

            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(.secondary.opacity(0.07)))
    }
}

// MARK: - Network Speed Row

struct NetworkSpeedRow: View {
    let icon: String
    let color: Color
    let label: String
    let speed: Double

    private var formattedSpeed: String {
        switch speed {
        case ..<1_024:          return String(format: "%.0f B/s",   speed)
        case ..<1_048_576:      return String(format: "%.1f KB/s",  speed / 1_024)
        default:                return String(format: "%.2f MB/s",  speed / 1_048_576)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(color.gradient)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption2).foregroundColor(.secondary)
                Text(formattedSpeed)
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: formattedSpeed)
            }
        }
    }
}
