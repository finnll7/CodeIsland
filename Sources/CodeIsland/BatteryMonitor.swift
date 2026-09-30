import AppKit
import Foundation
import IOKit.ps

/// Battery level / power source via IOKit.ps — a footer line for laptops.
/// Desktop Macs (no internal battery) report `hasBattery == false` and the
/// footer hides itself. Updates are pushed by IOPSNotificationCreateRunLoopSource
/// (no polling — the OS wakes us on every power state change).
@MainActor
@Observable
final class BatteryMonitor {
    private(set) var level = 100
    private(set) var isCharging = false
    private(set) var isPluggedIn = false
    /// False on desktop Macs — drives footer visibility.
    private(set) var hasBattery = true

    var isEnabled: Bool {
        // Same initialization-order fallback as the other ambient monitors.
        UserDefaults.standard.object(forKey: SettingsKey.showBattery) as? Bool
            ?? SettingsDefaults.showBattery
    }

    var isLive: Bool { isEnabled && hasBattery }

    private var runLoopSource: CFRunLoopSource?

    init() {
        update()
        // Power-state changes are pushed, not polled.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ rawContext in
            guard let rawContext else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(rawContext).takeUnretainedValue()
            DispatchQueue.main.async {
                Task { @MainActor in monitor.refreshPowerState() }
            }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
    }

    // No deinit: lives as long as AppState; the runloop source is main-queue.

    private func refreshPowerState() {
        update()
    }

    private func update() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any] else {
            hasBattery = false
            return
        }
        var found = false
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef)?
                .takeUnretainedValue() as? [String: Any],
                  let type = desc["Power Source"] as? String,
                  type == "InternalBattery" else {
                continue
            }
            found = true
            if let capacity = desc["Current Capacity"] as? Int {
                level = capacity
            }
            isCharging = desc["Is Charging"] as? Bool ?? false
            isPluggedIn = desc["Power Source State"] as? String == "AC Power"
        }
        hasBattery = found
    }

    // MARK: - Display helpers (pure)

    /// SF Symbol battery glyph for the current level/charging state.
    static func symbol(level: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch level {
        case 90...: return "battery.100"
        case 60..<90: return "battery.75"
        case 30..<60: return "battery.50"
        default: return "battery.25"
        }
    }

    /// Level color: white normally, amber ≤20%, red ≤10% (and not charging).
    static func levelColor(level: Int, charging: Bool) -> NSColor {
        if charging { return .white }
        if level <= 10 { return NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1) }
        if level <= 20 { return NSColor(red: 1.0, green: 0.7, blue: 0.28, alpha: 1) }
        return .white
    }
}
