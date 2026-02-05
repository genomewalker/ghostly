import Foundation
import IOKit.ps

@Observable
final class BatteryMonitor {
    var isOnBattery: Bool = false
    var batteryLevel: Int = 100
    var isLowBattery: Bool = false

    private var timer: Timer?

    var pollIntervalMultiplier: Double {
        if isLowBattery { return 0 } // pause monitoring
        return isOnBattery ? 2.0 : 1.0
    }

    var statusText: String {
        if isOnBattery {
            return "Battery (\(batteryLevel)%)"
        } else {
            return "Power Adapter"
        }
    }

    init() {
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    deinit {
        timer?.invalidate()
    }

    func update() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue() as? [String: Any]
        else {
            isOnBattery = false
            batteryLevel = 100
            isLowBattery = false
            return
        }

        let powerSource = desc[kIOPSPowerSourceStateKey] as? String ?? ""
        isOnBattery = (powerSource == kIOPSBatteryPowerValue)
        batteryLevel = desc[kIOPSCurrentCapacityKey] as? Int ?? 100
        isLowBattery = isOnBattery && batteryLevel < 20
    }
}
