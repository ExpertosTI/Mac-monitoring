import Cocoa
import SwiftUI
import UserNotifications
import WidgetKit

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var popover: NSPopover!
    let monitor = SystemMonitor()
    let prefs   = Preferences.shared

    private var lastCPUAlert:  Date = .distantPast
    private var lastRAMAlert:  Date = .distantPast
    private var lastDiskAlert: Date = .distantPast
    private let alertCooldown: TimeInterval = 300   // 5 min entre alertas

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 540)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: DetailView(monitor: monitor)
        )

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        monitor.refresh()
        updateStatusBar()
        startTimer(interval: prefs.refreshInterval)

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Recargar widget cada vez que los datos cambian
        NotificationCenter.default.addObserver(self, selector: #selector(reloadWidget),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: - Timer

    func startTimer(interval: Double) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.monitor.refresh()
            self.updateStatusBar()
            self.checkAlerts()
        }
    }

    // MARK: - Status bar

    func updateStatusBar() {
        guard let button = statusItem.button else { return }
        button.attributedTitle = buildStatusString()
    }

    private func buildStatusString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font   = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

        var metrics: [(icon: String, value: Double, fmt: String)] = []
        if prefs.showCPU   { metrics.append(("cpu",          monitor.cpuUsage,          "%")) }
        if prefs.showRAM   { metrics.append(("memorychip",   monitor.ramUsagePercent,   "%")) }
        if prefs.showDisk  { metrics.append(("internaldrive",monitor.diskUsagePercent,  "%")) }

        for (i, m) in metrics.enumerated() {
            let color = colorFor(m.value)
            if let icon = makeSymbol(m.icon, color: color) { result.append(icon); result.append(space()) }
            result.append(NSAttributedString(string: "\(Int(m.value))\(m.fmt)", attributes: [.font: font, .foregroundColor: color]))
            if i < metrics.count - 1 { result.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
        }

        if prefs.showBatteryBar {
            if !metrics.isEmpty { result.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            let battColor: NSColor = monitor.batteryConnected ? .systemGreen :
                                     monitor.batteryPercent > 20 ? .labelColor : .systemRed
            if let icon = makeSymbol(batterySymbol, color: battColor) { result.append(icon); result.append(space()) }
            result.append(NSAttributedString(string: "\(monitor.batteryPercent)%", attributes: [.font: font, .foregroundColor: battColor]))
        }

        if prefs.showNetworkBar {
            result.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            if let dn = makeSymbol("arrow.down", color: .labelColor) { result.append(dn); result.append(space()) }
            result.append(NSAttributedString(string: formatSpeed(monitor.networkDownSpeed), attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }

        return result
    }

    private var batterySymbol: String {
        if monitor.batteryConnected && monitor.batteryCharging { return "battery.100.bolt" }
        if monitor.batteryPercent > 75 { return "battery.100" }
        if monitor.batteryPercent > 50 { return "battery.75" }
        if monitor.batteryPercent > 25 { return "battery.50" }
        if monitor.batteryPercent > 10 { return "battery.25" }
        return "battery.0"
    }

    private func makeSymbol(_ name: String, color: NSColor) -> NSAttributedString? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        let att = NSTextAttachment(); att.image = img
        att.bounds = CGRect(x: 0, y: -2.5, width: 12, height: 12)
        return NSAttributedString(attachment: att)
    }

    private func space() -> NSAttributedString {
        NSAttributedString(string: " ", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)])
    }

    func colorFor(_ v: Double) -> NSColor {
        v < 50 ? .labelColor : v < 80 ? .systemOrange : .systemRed
    }

    func formatSpeed(_ bps: Double) -> String {
        switch bps {
        case ..<1_024:     return String(format: "%.0fB/s",  bps)
        case ..<1_048_576: return String(format: "%.1fK/s",  bps / 1_024)
        default:           return String(format: "%.1fM/s",  bps / 1_048_576)
        }
    }

    // MARK: - Alerts / Notifications

    func checkAlerts() {
        guard prefs.notificationsEnabled else { return }
        let now = Date()
        func coolOk(_ last: Date) -> Bool { now.timeIntervalSince(last) > alertCooldown }

        if monitor.cpuUsage > prefs.cpuThreshold && coolOk(lastCPUAlert) {
            notify("CPU Alta 🔴", body: "CPU al \(Int(monitor.cpuUsage))%")
            lastCPUAlert = now
        }
        if monitor.ramUsagePercent > prefs.ramThreshold && coolOk(lastRAMAlert) {
            notify("RAM Alta 🟠", body: "RAM al \(Int(monitor.ramUsagePercent))% · \(String(format: "%.1f", monitor.ramUsedGB)) GB usados")
            lastRAMAlert = now
        }
        if monitor.diskUsagePercent > prefs.diskThreshold && coolOk(lastDiskAlert) {
            notify("Disco Lleno 💾", body: "Disco al \(Int(monitor.diskUsagePercent))%")
            lastDiskAlert = now
        }
    }

    private func notify(_ title: String, body: String) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        )
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }

    // MARK: - Widget

    @objc func reloadWidget() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Popover

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            monitor.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
