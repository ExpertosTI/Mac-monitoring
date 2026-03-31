import SwiftUI

enum ProcessSort { case ram, cpu }

struct ProcessesView: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var sort: ProcessSort = .ram
    @State private var search: String = ""
    @State private var isLoading = true

    private var processes: [RunningProcess] {
        let base = sort == .ram ? monitor.topRamProcesses : monitor.topCpuProcesses
        guard !search.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search + sort controls
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.caption).foregroundColor(.secondary)
                    TextField("Buscar proceso…", text: $search)
                        .textFieldStyle(.plain).font(.subheadline)
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.1)))

                Picker("", selection: $sort) {
                    Text("RAM").tag(ProcessSort.ram)
                    Text("CPU").tag(ProcessSort.cpu)
                }
                .pickerStyle(.segmented).frame(width: 90)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider()

            // Column headers
            HStack {
                Text("#").frame(width: 16).font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                Text("Proceso").frame(maxWidth: .infinity, alignment: .leading)
                Text("RAM").frame(width: 68, alignment: .trailing)
                Text("CPU").frame(width: 50, alignment: .trailing)
                Spacer().frame(width: 28)
            }
            .font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 5)

            // Process rows
            if isLoading && processes.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Cargando procesos…").font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if processes.isEmpty {
                Text("Sin resultados").font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity).padding()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(processes.prefix(15).enumerated()), id: \.element.id) { idx, proc in
                            KillableProcessRow(process: proc, index: idx, monitor: monitor)
                        }
                    }
                }
            }
        }
        .task {
            isLoading = true
            await monitor.fetchTopProcesses()
            isLoading = false
            // Refresh every 3s while visible
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await monitor.fetchTopProcesses()
            }
        }
    }
}

// MARK: - Killable Process Row

struct KillableProcessRow: View {
    let process: RunningProcess
    let index: Int
    @ObservedObject var monitor: SystemMonitor
    @State private var isHovered = false
    @State private var killFailed = false

    private var ramColor: Color {
        process.ramMB > 500 ? .red : process.ramMB > 200 ? .orange : .primary
    }

    private var formattedRAM: String {
        process.ramMB >= 1024
            ? String(format: "%.1f GB", process.ramMB / 1024)
            : String(format: "%.0f MB", process.ramMB)
    }

    var body: some View {
        HStack(spacing: 6) {
            // Rank
            Text("\(index + 1)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary).frame(width: 16)

            // Name
            Text(process.name)
                .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            // RAM
            Text(formattedRAM)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(ramColor).frame(width: 68, alignment: .trailing)

            // CPU
            Text(String(format: "%.1f%%", process.cpu))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(process.cpu > 20 ? .orange : .secondary)
                .frame(width: 50, alignment: .trailing)

            // Kill button
            Button {
                confirmKill()
            } label: {
                Image(systemName: killFailed ? "exclamationmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(killFailed ? .orange : .red)
                    .opacity(isHovered ? 1 : 0)
            }
            .buttonStyle(.plain)
            .frame(width: 22)
            .help(killFailed ? "Sin permisos para terminar este proceso" : "Terminar proceso")
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .background(isHovered ? Color.secondary.opacity(0.1) :
                    index % 2 == 1 ? Color.secondary.opacity(0.04) : Color.clear)
        .onHover { isHovered = $0 }
    }

    private func confirmKill() {
        let alert = NSAlert()
        alert.messageText = "¿Terminar \"\(process.name)\"?"
        alert.informativeText = "PID \(process.id)  ·  RAM: \(formattedRAM)  ·  CPU: \(String(format: "%.1f", process.cpu))%\n\nEl proceso se cerrará. Puedes perder datos no guardados."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Terminar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let ok = monitor.killProcess(process.id)
        if ok {
            Task { await monitor.fetchTopProcesses() }
        } else {
            killFailed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { killFailed = false }
        }
    }
}
