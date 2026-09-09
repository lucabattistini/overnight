import Foundation
import IOKit.ps

/// Watches the power source and reports the moment the machine leaves AC.
///
/// This is the reason the app has to be running at all while Overnight is active. `disablesleep`
/// is global: the 2026-09-09 hardware spike confirmed `pmset -c disablesleep 1` writes the
/// system-wide flag regardless of the `-c`. So a machine unplugged mid-run will sit on battery
/// refusing to sleep, and something has to notice.
///
/// Reading the power source needs no privilege. Acting on it does, which is why the app raises
/// the authorization prompt immediately rather than restoring silently — an unattended restore
/// would need the persistent privileged daemon this project deliberately does not have.
final class PowerSourceMonitor {
    enum Source: Equatable {
        case ac
        case battery
        case unknown
    }

    private var runLoopSource: CFRunLoopSource?
    private var onChange: ((Source) -> Void)?
    private var lastSource: Source = .unknown

    static func currentSource() -> Source {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String? else {
            return .unknown
        }
        switch type {
        case kIOPMACPowerKey: return .ac
        case kIOPMBatteryPowerKey: return .battery
        default: return .unknown
        }
    }

    /// Starts watching. The callback fires only on an actual transition, not on every
    /// notification, because IOKit reports battery percentage changes through the same source.
    func start(onChange: @escaping (Source) -> Void) {
        stop()
        self.onChange = onChange
        lastSource = Self.currentSource()

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handleNotification()
        }, context)?.takeRetainedValue() else {
            return
        }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
        onChange = nil
    }

    private func handleNotification() {
        let current = Self.currentSource()
        guard current != lastSource else { return }
        lastSource = current
        onChange?(current)
    }

    deinit { stop() }
}
