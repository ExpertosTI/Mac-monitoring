import SwiftUI

/// Pestaña Discos: estado del disco de trabajo y prueba de velocidad.
struct StorageTab: View {
    @ObservedObject private var disk = WorkDiskManager.shared
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Disco de trabajo")
                workDiskCard

                Divider().padding(.vertical, 8)

                sectionHeader("Prueba de velocidad")
                speedCard
            }
            .padding(14)
        }
        .onAppear { disk.refresh() }
        .onChange(of: prefs.workDiskPath) { _, _ in
            disk.refresh()
        }
    }

    // MARK: - Disco de trabajo

    private var workDiskCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(disk.isConnected ? Color.green : Color.orange)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(diskTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(displayPath)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                statusCapsule
            }

            if disk.isConnected && disk.totalBytes > 0 {
                Text(capacityText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                capacityBar
            }

            if !disk.statusMessage.isEmpty {
                Label(disk.statusMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.secondary.opacity(0.07)))
    }

    private var diskTitle: String {
        if disk.isConnected && !disk.volumeName.isEmpty { return disk.volumeName }
        return "Disco de trabajo"
    }

    private var displayPath: String {
        let path = disk.resolvedPath.isEmpty ? prefs.workDiskPath : disk.resolvedPath
        return path.isEmpty ? "/Volumes/Extreme SSD" : path
    }

    private var capacityText: String {
        let free = disk.freeGB < 10
            ? String(format: "%.1f GB libres", disk.freeGB)
            : String(format: "%.0f GB libres", disk.freeGB)
        return "\(free) · \(String(format: "%.0f GB total", disk.totalGB))"
    }

    private var statusCapsule: some View {
        Text(disk.isConnected ? "Conectado" : "No conectado")
            .font(.caption2.weight(.semibold))
            .foregroundColor(disk.isConnected ? .green : .orange)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill((disk.isConnected ? Color.green : Color.orange).opacity(0.15)))
    }

    private var capacityBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.15))
                Capsule()
                    .fill(usageColor.gradient)
                    .frame(width: max(geo.size.width * disk.usedFraction, disk.usedFraction > 0 ? 4 : 0))
            }
        }
        .frame(height: 6)
    }

    private var usageColor: Color {
        let pct = disk.usedFraction * 100
        if pct < 50 { return .green }
        if pct < 80 { return .orange }
        return .red
    }

    // MARK: - Prueba

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Escritura síncrona y lectura de \(WorkDiskManager.testSizeMB) MB, sin caché del sistema. El archivo temporal se borra al terminar.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .running(let phase, let progress) = disk.state {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(phase).font(.caption)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    ProgressView(value: progress).tint(.accentColor)
                }
            }

            if case .completed(let result) = disk.state {
                resultView(result)
            }

            if case .cancelled = disk.state {
                Label("Prueba cancelada. El archivo temporal se eliminó.", systemImage: "stop.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .failed(let message) = disk.state {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                if disk.isRunning {
                    disk.cancelTest()
                } else {
                    disk.startTest()
                }
            } label: {
                Label(
                    disk.isRunning ? "Cancelar" : "Iniciar prueba",
                    systemImage: disk.isRunning ? "stop.fill" : "speedometer"
                )
                .font(.subheadline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(disk.isRunning ? .red : .accentColor)
            .disabled(!disk.isRunning && !disk.canStartTest)
            .help(buttonHelp)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.secondary.opacity(0.07)))
    }

    private var buttonHelp: String {
        if disk.isRunning { return "Detener la prueba y borrar el archivo temporal" }
        if !disk.isConnected { return "Conecta el disco de trabajo para medir su velocidad" }
        if !disk.canStartTest, !disk.statusMessage.isEmpty { return disk.statusMessage }
        return "Mide escritura y lectura en el disco de trabajo"
    }

    private func resultView(_ result: DiskSpeedResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                speedMetric(
                    icon: "arrow.down.doc.fill",
                    color: .orange,
                    title: "Escritura",
                    value: formatSpeed(result.writeMBps)
                )
                speedMetric(
                    icon: "arrow.up.doc.fill",
                    color: .green,
                    title: "Lectura",
                    value: formatSpeed(result.readMBps)
                )
            }

            Divider()

            infoRow("Tamaño", formatSize(result.byteCount))
            infoRow("Duración", String(format: "%.1f s", result.duration))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Ruta")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer(minLength: 8)
                Text(result.path)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.path, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .help("Copiar ruta")
            }
        }
    }

    private func speedMetric(icon: String, color: Color, title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(color.gradient)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundColor(.secondary)
                Text(value)
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .lineLimit(1)
        }
    }

    private func formatSpeed(_ mbps: Double) -> String {
        if mbps >= 100 {
            return String(format: "%.0f MB/s", mbps)
        }
        return String(format: "%.1f MB/s", mbps)
    }

    private func formatSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 10 {
            return String(format: "%.0f MB", mb)
        }
        return String(format: "%.1f MB", mb)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.bottom, 6)
    }
}
