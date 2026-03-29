import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var popover: NSPopover!
    let monitor = SystemMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 500)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: DetailView(monitor: monitor))

        monitor.refresh()
        updateStatusBar()

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.monitor.refresh()
            self?.updateStatusBar()
        }

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    func updateStatusBar() {
        guard let button = statusItem.button else { return }
        button.attributedTitle = buildStatusString()
    }

    private func buildStatusString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

        let metrics: [(icon: String, value: Double)] = [
            ("cpu", monitor.cpuUsage),
            ("memorychip", monitor.ramUsagePercent),
            ("internaldrive", monitor.diskUsagePercent),
        ]

        for (index, metric) in metrics.enumerated() {
            let color = colorForPercent(metric.value)

            if let iconAttr = makeSymbolAttachment(metric.icon, color: color) {
                result.append(iconAttr)
                result.append(NSAttributedString(string: " "))
            }

            let valueStr = "\(Int(metric.value))%"
            result.append(NSAttributedString(string: valueStr, attributes: [
                .font: font,
                .foregroundColor: color
            ]))

            if index < metrics.count - 1 {
                result.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            }
        }

        return result
    }

    private func makeSymbolAttachment(_ name: String, color: NSColor) -> NSAttributedString? {
        let sizeConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let colorConfig = NSImage.SymbolConfiguration(paletteColors: [color])
        let config = sizeConfig.applying(colorConfig)

        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -2.5, width: 12, height: 12)
        return NSAttributedString(attachment: attachment)
    }

    func colorForPercent(_ value: Double) -> NSColor {
        if value < 50 { return .labelColor }
        if value < 80 { return .systemOrange }
        return .systemRed
    }

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
