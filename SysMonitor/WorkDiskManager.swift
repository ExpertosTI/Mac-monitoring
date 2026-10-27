import Foundation
import Darwin
import AppKit

// MARK: - Resultado

struct DiskSpeedResult: Equatable, Sendable {
    let writeMBps: Double
    let readMBps: Double
    let byteCount: Int64
    let duration: TimeInterval
    /// Ruta del volumen probado (el archivo temporal ya se eliminó).
    let path: String
}

enum SpeedTestState: Equatable {
    case idle
    case running(phase: String, progress: Double)
    case completed(DiskSpeedResult)
    case cancelled
    case failed(String)
}

enum SpeedTestError: LocalizedError {
    case cancelled
    case notConnected
    case notWritable
    case insufficientSpace(neededMB: Int, freeMB: Int)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Prueba cancelada."
        case .notConnected:
            return "El disco de trabajo no está conectado."
        case .notWritable:
            return "No se puede escribir en el disco de trabajo."
        case .insufficientSpace(let needed, let free):
            return "Espacio insuficiente: hacen falta \(needed) MB y hay \(free) MB libres."
        case .io(let message):
            return message
        }
    }
}

// MARK: - Cancelación cooperativa

private final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

// MARK: - Medición (hilo de fondo)

/// Escribe y lee un archivo temporal en el volumen indicado.
/// La escritura incluye `F_FULLFSYNC` para que el MB/s refleje el dispositivo (USB) y no la caché del sistema.
private enum DiskSpeedBenchmark {
    static func measure(
        volumePath: String,
        totalBytes: Int64,
        isCancelled: @escaping @Sendable () -> Bool,
        onProgress: @escaping @Sendable (_ phase: String, _ fraction: Double) -> Void
    ) throws -> DiskSpeedResult {
        if isCancelled() { throw SpeedTestError.cancelled }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: volumePath, isDirectory: &isDir), isDir.boolValue else {
            throw SpeedTestError.notConnected
        }
        guard FileManager.default.isWritableFile(atPath: volumePath) else {
            throw SpeedTestError.notWritable
        }

        let volumeURL = URL(fileURLWithPath: volumePath, isDirectory: true)
        let free = availableBytes(at: volumeURL)
        let needed = totalBytes + 64 * 1024 * 1024
        if free >= 0 && free < needed {
            throw SpeedTestError.insufficientSpace(
                neededMB: Int((needed + 1024 * 1024 - 1) / (1024 * 1024)),
                freeMB: Int(max(free, 0) / (1024 * 1024))
            )
        }

        removeStaleFiles(in: volumePath)
        if isCancelled() { throw SpeedTestError.cancelled }

        let filePath = (volumePath as NSString)
            .appendingPathComponent(".sysmonitor-speedtest-\(UUID().uuidString).bin")
        let fd = openFile(filePath)
        guard fd >= 0 else {
            throw SpeedTestError.io(message(for: errno, prefix: "No se pudo crear el archivo de prueba"))
        }
        defer {
            close(fd)
            unlinkFile(filePath)
        }

        // Sin caché del sistema: lecturas y escrituras tienen que llegar al disco.
        // F_NOCACHE exige E/S alineada al tamaño de página; el bloque de 8 MB lo cumple.
        var bypassCache = fcntl(fd, F_NOCACHE, 1) == 0
        _ = fcntl(fd, F_RDAHEAD, 0)

        let page = max(Int(vm_page_size), 4096)
        let chunk = 8 * 1024 * 1024
        precondition(chunk % page == 0, "El bloque de prueba debe ser múltiplo de la página")
        precondition(totalBytes > 0 && totalBytes % Int64(page) == 0, "El tamaño de prueba debe ser múltiplo de la página")

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: page)
        defer { buffer.deallocate() }
        arc4random_buf(buffer, chunk)
        if isCancelled() { throw SpeedTestError.cancelled }

        let readBuffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: page)
        defer { readBuffer.deallocate() }

        let overallStart = DispatchTime.now().uptimeNanoseconds

        onProgress("Escribiendo…", 0)
        let writeStart = DispatchTime.now().uptimeNanoseconds
        var written: Int64 = 0
        while written < totalBytes {
            if isCancelled() { throw SpeedTestError.cancelled }
            let want = min(chunk, Int(totalBytes - written))
            var offset = 0
            while offset < want {
                let n = write(fd, buffer.advanced(by: offset), want - offset)
                if n < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    if err == EINVAL && bypassCache && written == 0 && offset == 0 {
                        _ = fcntl(fd, F_NOCACHE, 0)
                        bypassCache = false
                        continue
                    }
                    throw SpeedTestError.io(message(for: err, prefix: "Error al escribir"))
                }
                if n == 0 {
                    throw SpeedTestError.io("El disco no aceptó más datos.")
                }
                offset += n
                if bypassCache && offset % page != 0 {
                    throw SpeedTestError.io("Escritura incompleta en el disco.")
                }
            }
            written += Int64(want)
            onProgress("Escribiendo…", Double(written) / Double(totalBytes) * 0.45)
        }

        if isCancelled() { throw SpeedTestError.cancelled }
        onProgress("Sincronizando…", 0.48)
        if fcntl(fd, F_FULLFSYNC) != 0 {
            if fsync(fd) != 0 {
                throw SpeedTestError.io(message(for: errno, prefix: "No se pudo sincronizar la escritura"))
            }
        }
        let writeMBps = megabytesPerSecond(bytes: totalBytes, since: writeStart)

        if isCancelled() { throw SpeedTestError.cancelled }
        if lseek(fd, 0, SEEK_SET) < 0 {
            throw SpeedTestError.io(message(for: errno, prefix: "No se pudo rebobinar el archivo"))
        }
        if bypassCache {
            _ = fcntl(fd, F_NOCACHE, 1)
        }

        onProgress("Leyendo…", 0.5)
        let readStart = DispatchTime.now().uptimeNanoseconds
        var readTotal: Int64 = 0
        var checksum: UInt64 = 0
        while readTotal < totalBytes {
            if isCancelled() { throw SpeedTestError.cancelled }
            let want = min(chunk, Int(totalBytes - readTotal))
            var offset = 0
            while offset < want {
                let n = read(fd, readBuffer.advanced(by: offset), want - offset)
                if n < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    throw SpeedTestError.io(message(for: err, prefix: "Error al leer"))
                }
                if n == 0 {
                    throw SpeedTestError.io("Lectura incompleta del archivo de prueba.")
                }
                offset += n
                if bypassCache && offset % page != 0 {
                    throw SpeedTestError.io("Lectura incompleta del archivo de prueba.")
                }
            }
            checksum = checksum &+ readBuffer.load(as: UInt64.self)
            readTotal += Int64(want)
            onProgress("Leyendo…", 0.5 + Double(readTotal) / Double(totalBytes) * 0.5)
        }
        withExtendedLifetime(checksum) {}

        let readMBps = megabytesPerSecond(bytes: totalBytes, since: readStart)
        return DiskSpeedResult(
            writeMBps: writeMBps,
            readMBps: readMBps,
            byteCount: totalBytes,
            duration: seconds(since: overallStart),
            path: volumePath
        )
    }

    static func removeStaleFiles(in volumePath: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: volumePath) else { return }
        for name in names where name.hasPrefix(".sysmonitor-speedtest-") && name.hasSuffix(".bin") {
            let full = (volumePath as NSString).appendingPathComponent(name)
            unlinkFile(full)
        }
    }

    private static func openFile(_ path: String) -> Int32 {
        open((path as NSString).fileSystemRepresentation, O_RDWR | O_CREAT | O_TRUNC, mode_t(0o644))
    }

    private static func unlinkFile(_ path: String) {
        _ = unlink((path as NSString).fileSystemRepresentation)
    }

    private static func availableBytes(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return -1 }
        if let important = values.volumeAvailableCapacityForImportantUsage { return important }
        if let avail = values.volumeAvailableCapacity { return Int64(avail) }
        return -1
    }

    private static func megabytesPerSecond(bytes: Int64, since start: UInt64) -> Double {
        Double(bytes) / 1_048_576 / max(seconds(since: start), 0.000_001)
    }

    private static func seconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000_000
    }

    private static func message(for err: Int32, prefix: String) -> String {
        switch err {
        case ENOSPC:
            return "Sin espacio en el disco de trabajo."
        case EACCES, EPERM:
            return "No hay permiso de escritura en el disco de trabajo."
        case EROFS:
            return "El disco de trabajo es de solo lectura."
        case ENOENT, ENXIO, ENODEV:
            return "El disco de trabajo se desconectó."
        case EIO:
            return "Error de E/S. Revisa la conexión del disco."
        case EINVAL:
            return "La prueba no pudo acceder al disco sin caché."
        default:
            return "\(prefix): \(String(cString: strerror(err)))"
        }
    }
}

// MARK: - Estado del disco de trabajo

@MainActor
final class WorkDiskManager: ObservableObject {
    static let shared = WorkDiskManager()

    /// Tamaño modesto: suficiente para un USB y sin llenar el volumen.
    static let testSizeBytes: Int64 = 256 * 1024 * 1024
    static var testSizeMB: Int { Int(testSizeBytes / (1024 * 1024)) }

    @Published private(set) var isConnected = false
    @Published private(set) var isWritable = false
    @Published private(set) var hasEnoughSpace = false
    @Published private(set) var volumeName = ""
    @Published private(set) var resolvedPath = ""
    @Published private(set) var freeBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var statusMessage = "Comprobando disco de trabajo…"
    @Published private(set) var state: SpeedTestState = .idle

    private var observers: [NSObjectProtocol] = []
    private var cancelToken: CancelToken?
    private var runID = UUID()

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var canStartTest: Bool {
        isConnected && isWritable && hasEnoughSpace && !isRunning
    }

    var freeGB: Double { Double(freeBytes) / 1_073_741_824 }
    var totalGB: Double { Double(totalBytes) / 1_073_741_824 }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        let used = max(totalBytes - freeBytes, 0)
        return min(Double(used) / Double(totalBytes), 1)
    }

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]
        for name in names {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Task { @MainActor in
                        WorkDiskManager.shared.refresh()
                    }
                }
            )
        }
        refresh()
    }

    func refresh() {
        var path = Preferences.shared.workDiskPath.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        if path.hasPrefix("~") {
            path = (path as NSString).expandingTildeInPath
        }
        resolvedPath = path

        guard !path.isEmpty else {
            applyDisconnected("Indica la ruta del disco de trabajo en Ajustes.")
            return
        }

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        guard exists else {
            applyDisconnected("El disco de trabajo no está conectado. Conecta el volumen o revisa la ruta en Ajustes.")
            return
        }
        guard isDir.boolValue else {
            applyDisconnected("La ruta del disco de trabajo no es una carpeta.")
            return
        }

        let url = URL(fileURLWithPath: path, isDirectory: true)
        let values = try? url.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsReadOnlyKey
        ])

        let fallbackName = url.lastPathComponent
        volumeName = values?.volumeName?.isEmpty == false ? (values?.volumeName ?? fallbackName) : fallbackName
        if let total = values?.volumeTotalCapacity {
            totalBytes = Int64(total)
        } else {
            totalBytes = 0
        }
        if let important = values?.volumeAvailableCapacityForImportantUsage {
            freeBytes = important
        } else if let avail = values?.volumeAvailableCapacity {
            freeBytes = Int64(avail)
        } else {
            freeBytes = 0
        }

        let readOnly = values?.volumeIsReadOnly ?? false
        isWritable = !readOnly && FileManager.default.isWritableFile(atPath: path)
        isConnected = true

        let reserve: Int64 = 64 * 1024 * 1024
        if totalBytes > 0 {
            hasEnoughSpace = freeBytes >= Self.testSizeBytes + reserve
        } else {
            hasEnoughSpace = isWritable
        }

        if !isWritable {
            hasEnoughSpace = false
            statusMessage = "El disco está conectado, pero no se puede escribir en él."
        } else if !hasEnoughSpace {
            statusMessage = "No hay espacio suficiente. La prueba necesita \(Self.testSizeMB) MB libres."
        } else {
            statusMessage = ""
        }
    }

    func startTest() {
        guard canStartTest else { return }
        let path = resolvedPath
        let bytes = Self.testSizeBytes
        let token = CancelToken()
        let id = UUID()
        runID = id
        cancelToken = token
        state = .running(phase: "Preparando…", progress: 0)

        Task.detached(priority: .userInitiated) {
            let outcome: Result<DiskSpeedResult, Error>
            do {
                let value = try DiskSpeedBenchmark.measure(
                    volumePath: path,
                    totalBytes: bytes,
                    isCancelled: { token.isCancelled },
                    onProgress: { phase, fraction in
                        Task { @MainActor in
                            WorkDiskManager.shared.updateProgress(runID: id, phase: phase, fraction: fraction)
                        }
                    }
                )
                outcome = .success(value)
            } catch {
                outcome = .failure(error)
            }
            await WorkDiskManager.shared.finish(runID: id, outcome: outcome)
        }
    }

    func cancelTest() {
        guard isRunning else { return }
        cancelToken?.cancel()
        if case .running(_, let progress) = state {
            state = .running(phase: "Cancelando…", progress: progress)
        }
    }

    private func updateProgress(runID: UUID, phase: String, fraction: Double) {
        guard self.runID == runID else { return }
        guard case .running(let current, _) = state else { return }
        if current == "Cancelando…" { return }
        state = .running(phase: phase, progress: min(max(fraction, 0), 1))
    }

    private func finish(runID: UUID, outcome: Result<DiskSpeedResult, Error>) {
        guard self.runID == runID else { return }
        cancelToken = nil
        switch outcome {
        case .success(let result):
            state = .completed(result)
        case .failure(let error):
            if let test = error as? SpeedTestError, case .cancelled = test {
                state = .cancelled
            } else {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                state = .failed(message.isEmpty ? "No se pudo completar la prueba." : message)
            }
        }
        refresh()
    }

    private func applyDisconnected(_ message: String) {
        isConnected = false
        isWritable = false
        hasEnoughSpace = false
        volumeName = ""
        freeBytes = 0
        totalBytes = 0
        statusMessage = message
    }
}
