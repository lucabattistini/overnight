import Foundation
import SwiftUI
import UserNotifications
import OvernightCore

/// The app's single source of truth, and the only place that decides what is true.
///
/// Status is always re-derived from live `pmset` output plus the saved state file. Nothing here
/// remembers what it did and reports that back: after a crash, a relaunch, or a restore that
/// happened while the app was closed, the menu bar shows what the machine actually reports.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: OvernightStatus = .off
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?
    /// Set when the machine left AC while Overnight was active and the restore has not
    /// completed yet. Drives the warning in the menu.
    @Published private(set) var onBatteryWhileActive = false

    private let monitor = PowerSourceMonitor()
    private var refreshTimer: Timer?

    private var hasStarted = false

    /// Nonisolated and empty so `@StateObject private var model = AppModel()` in the `App`
    /// struct does not have to be evaluated from a main-actor context. Startup work happens in
    /// `start()` instead: an initializer cannot capture `self` into a concurrent task.
    nonisolated init() {}

    /// Called when the menu first appears. Idempotent, because the menu appears many times.
    func start() {
        refresh()
        guard !hasStarted else { return }
        hasStarted = true
        startPeriodicRefresh()
        requestNotificationPermission()
    }

    // MARK: - Status

    /// Re-reads the machine. Cheap enough to run whenever the menu opens.
    func refresh() {
        let sleepDisabled = readSleepDisabled()
        let capture = readCapture()
        let jobInstalled = FileManager.default.fileExists(atPath: OvernightPaths.launchDaemonPlist)

        status = OvernightStatus.derive(
            sleepDisabled: sleepDisabled,
            capture: capture,
            jobInstalled: jobInstalled
        )

        if status.isActive {
            startWatchingPower()
        } else {
            stopWatchingPower()
            onBatteryWhileActive = false
        }
    }

    private func readSleepDisabled() -> Bool? {
        guard let result = try? CommandRunner.run(OvernightPaths.pmsetExecutable, ["-g"]),
              result.succeeded else { return nil }
        return (try? PMSetParser.parseSleepDisabled(result.standardOutput)) ?? nil
    }

    private func readCapture() -> PowerCapture? {
        guard let contents = try? String(contentsOfFile: OvernightPaths.stateFile, encoding: .utf8) else {
            return nil
        }
        // A state file that will not parse is treated as no capture rather than as a usable
        // baseline. The privileged side re-validates it too and refuses to replay it.
        return try? PMSetParser.parseState(contents)
    }

    private func startPeriodicRefresh() {
        // The deadline job can restore while the app is idle, and the menu should not keep
        // claiming Overnight is on for minutes afterwards.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Actions

    func enable(hour: Int, minute: Int) {
        perform(expecting: .active) {
            let deadline = try Deadline(hour: hour, minute: minute)
            try PrivilegedRunner.run(.enable(deadline))
        }
    }

    /// Changing the deadline re-runs the same enable transaction. The restore is idempotent and
    /// enable overwrites the job, so extending needs no separate code path.
    func changeDeadline(hour: Int, minute: Int) {
        enable(hour: hour, minute: minute)
    }

    func disable() {
        perform(expecting: .inactive) {
            try PrivilegedRunner.run(.restore)
        }
    }

    /// What the machine should report once the action has run. Checked by reading `pmset` back,
    /// not by trusting the exit code: `disablesleep` is undocumented, and the hardware spike
    /// showed it accepting a flag it then ignores without warning.
    private enum Expectation {
        case active
        case inactive
    }

    private func perform(expecting expectation: Expectation, _ work: @escaping @Sendable () throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil

        Task {
            let outcome: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try work()
                    return nil
                } catch PrivilegedRunner.PrivilegeError.userCancelled {
                    return ""
                } catch {
                    return error.localizedDescription
                }
            }.value

            self.isBusy = false
            // An empty string means the user cancelled the prompt. That is a decision, not an
            // error, so it is not surfaced as one.
            let cancelled = outcome?.isEmpty == true
            if let outcome, !outcome.isEmpty {
                self.lastError = outcome
            }
            self.refresh()
            if !cancelled { self.reportMismatch(expectation) }
        }
    }

    /// Reports the case where the privileged step succeeded but the machine did not end up in
    /// the expected state.
    private func reportMismatch(_ expectation: Expectation) {
        guard lastError == nil else { return }
        switch expectation {
        case .active where !status.isActive:
            lastError = "macOS reported success but sleep is still enabled. Overnight is not holding this Mac awake."
        case .inactive where status.isActive:
            lastError = "The restore ran but sleep is still disabled. Use the Terminal recovery steps in the README."
        default:
            break
        }
    }

    // MARK: - AC watching

    private func startWatchingPower() {
        onBatteryWhileActive = PowerSourceMonitor.currentSource() == .battery
        monitor.start { [weak self] source in
            Task { @MainActor in self?.handlePowerSourceChange(source) }
        }
    }

    private func stopWatchingPower() {
        monitor.stop()
    }

    /// On unplug, restore immediately.
    ///
    /// "Immediately" means the authorization prompt comes up straight away, because clearing a
    /// global `pmset` flag needs root and this app has no standing privilege. If nobody is at
    /// the machine to answer it, the warning stays up and the deadline job remains the backstop.
    private func handlePowerSourceChange(_ source: PowerSourceMonitor.Source) {
        guard status.isActive else { return }
        guard source == .battery else {
            onBatteryWhileActive = false
            return
        }

        onBatteryWhileActive = true
        notifyUnplugged()
        disable()
    }

    // MARK: - Notifications

    /// UNUserNotificationCenter traps when the process has no bundle identifier, which happens
    /// if the binary is run directly instead of from the app bundle. The menu-bar warning does
    /// not depend on notifications, so losing them is survivable; crashing is not.
    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private func requestNotificationPermission() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyUnplugged() {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Overnight: power unplugged"
        content.body = "Sleep is still disabled system-wide. Approve the prompt to restore your settings now."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
