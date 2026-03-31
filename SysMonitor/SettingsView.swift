import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var prefs: Preferences
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var copied = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Barra de Menú")
                menuBarToggles

                Divider().padding(.vertical, 8)

                sectionHeader("Frecuencia de actualización")
                refreshPicker

                Divider().padding(.vertical, 8)

                sectionHeader("Alertas de umbral")
                thresholdSliders

                Divider().padding(.vertical, 8)

                sectionHeader("Sistema")
                systemOptions

                Divider().padding(.vertical, 8)

                actionButtons
            }
            .padding(14)
        }
    }

    // MARK: - Menu bar toggles

    private var menuBarToggles: some View {
        VStack(spacing: 0) {
            toggleRow("cpu", label: "CPU", binding: $prefs.showCPU)
            toggleRow("memorychip", label: "RAM", binding: $prefs.showRAM)
            toggleRow("internaldrive", label: "Disco", binding: $prefs.showDisk)
            toggleRow("battery.75", label: "Batería", binding: $prefs.showBatteryBar)
            toggleRow("arrow.down.circle", label: "Red (descarga)", binding: $prefs.showNetworkBar)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(.secondary.opacity(0.07)))
    }

    private func toggleRow(_ icon: String, label: String, binding: Binding<Bool>) -> some View {
        HStack {
            Image(systemName: icon).frame(width: 22).foregroundColor(.accentColor)
            Text(label).font(.subheadline)
            Spacer()
            Toggle("", isOn: binding).labelsHidden()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - Refresh

    private var refreshPicker: some View {
        HStack {
            Image(systemName: "timer").foregroundColor(.accentColor)
            Text("Intervalo").font(.subheadline)
            Spacer()
            Picker("", selection: $prefs.refreshInterval) {
                Text("1s").tag(1.0)
                Text("2s").tag(2.0)
                Text("5s").tag(5.0)
            }
            .pickerStyle(.segmented).frame(width: 110)
            .onChange(of: prefs.refreshInterval) { _, v in
                (NSApp.delegate as? AppDelegate)?.startTimer(interval: v)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.secondary.opacity(0.07)))
    }

    // MARK: - Thresholds

    private var thresholdSliders: some View {
        VStack(spacing: 10) {
            thresholdRow("CPU",   icon: "cpu",          value: $prefs.cpuThreshold,  color: .blue)
            thresholdRow("RAM",   icon: "memorychip",   value: $prefs.ramThreshold,  color: .purple)
            thresholdRow("Disco", icon: "internaldrive",value: $prefs.diskThreshold, color: .orange)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.secondary.opacity(0.07)))
    }

    private func thresholdRow(_ label: String, icon: String, value: Binding<Double>, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon).foregroundColor(color).frame(width: 22)
                Text("Alerta \(label)").font(.subheadline)
                Spacer()
                Text("\(Int(value.wrappedValue))%")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundColor(color)
            }
            Slider(value: value, in: 50...95, step: 5)
                .tint(color).padding(.leading, 22)
        }
    }

    // MARK: - System options

    private var systemOptions: some View {
        VStack(spacing: 0) {
            // Notifications
            HStack {
                Image(systemName: "bell.badge").frame(width: 22).foregroundColor(.red)
                Text("Notificaciones").font(.subheadline)
                Spacer()
                Toggle("", isOn: $prefs.notificationsEnabled).labelsHidden()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider().padding(.leading, 36)

            // Launch at login
            HStack {
                Image(systemName: "power.circle").frame(width: 22).foregroundColor(.green)
                Text("Inicio automático").font(.subheadline)
                Spacer()
                Toggle("", isOn: $launchAtLogin).labelsHidden()
                    .onChange(of: launchAtLogin) { _, v in
                        try? v ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(.secondary.opacity(0.07)))
    }

    // MARK: - Action buttons

    private var actionButtons: some View {
        HStack(spacing: 10) {
            // Copy snapshot
            Button {
                copySnapshot()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                Label(copied ? "Copiado ✓" : "Copiar snapshot", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                    .font(.subheadline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(copied ? .green : .accentColor)

            // Quit
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Salir", systemImage: "xmark.circle.fill")
                    .font(.subheadline).foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.bottom, 6)
    }

    private func copySnapshot() {
        let snap = """
SysMonitor — \(Date().formatted())
────────────────────────────
CPU:   \(String(format: "%.1f", monitor.cpuUsage))%
RAM:   \(String(format: "%.1f", monitor.ramUsagePercent))%  (\(String(format: "%.1f / %.0f", monitor.ramUsedGB, monitor.ramTotalGB)) GB)
Disco: \(String(format: "%.1f", monitor.diskUsagePercent))%  (\(String(format: "%.0f / %.0f", monitor.diskUsedGB, monitor.diskTotalGB)) GB · \(String(format: "%.0f GB libres", monitor.diskFreeGB)))
Red ↓: \(fmtSpeed(monitor.networkDownSpeed))   ↑: \(fmtSpeed(monitor.networkUpSpeed))
Interfaz: \(monitor.networkInterface) · IP: \(monitor.localIP)
Batería: \(monitor.batteryPercent)% \(monitor.batteryConnected ? "(enchufado)" : "(batería)")
Temperatura: \(thermalLabel)
Activo: \(monitor.uptime)
GPU: \(String(format: "%.0f / %.0f MB", monitor.gpuUsedMB, monitor.gpuTotalMB))
────────────────────────────
Top procesos por RAM:
\(monitor.topRamProcesses.prefix(5).enumerated().map { "\($0.offset+1). \($0.element.name) — \(String(format: "%.0f MB", $0.element.ramMB))" }.joined(separator: "\n"))
"""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snap, forType: .string)
    }

    private var thermalLabel: String {
        switch monitor.thermalState {
        case .nominal: return "Normal"
        case .fair:    return "Tibia"
        case .serious: return "Caliente"
        case .critical: return "Crítico"
        @unknown default: return "?"
        }
    }

    private func fmtSpeed(_ bps: Double) -> String {
        switch bps {
        case ..<1_024:     return String(format: "%.0f B/s",  bps)
        case ..<1_048_576: return String(format: "%.1f KB/s", bps / 1_024)
        default:           return String(format: "%.2f MB/s", bps / 1_048_576)
        }
    }
}

// Helper to get AppDelegate from SwiftUI
extension AppDelegate {
    static var appDelegate: AppDelegate {
        NSApp.delegate as! AppDelegate
    }
}
