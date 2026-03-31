import SwiftUI

class Preferences: ObservableObject {
    static let shared = Preferences()
    private init() {}

    @AppStorage("showCPU")              var showCPU: Bool = true
    @AppStorage("showRAM")              var showRAM: Bool = true
    @AppStorage("showDisk")             var showDisk: Bool = true
    @AppStorage("showBatteryBar")       var showBatteryBar: Bool = false
    @AppStorage("showNetworkBar")       var showNetworkBar: Bool = false
    @AppStorage("refreshInterval")      var refreshInterval: Double = 2.0
    @AppStorage("cpuThreshold")         var cpuThreshold: Double = 85.0
    @AppStorage("ramThreshold")         var ramThreshold: Double = 80.0
    @AppStorage("diskThreshold")        var diskThreshold: Double = 90.0
    @AppStorage("notificationsEnabled") var notificationsEnabled: Bool = true
}
