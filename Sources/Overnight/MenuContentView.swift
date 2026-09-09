import AppKit
import SwiftUI
import OvernightCore

struct MenuContentView: View {
    @ObservedObject var model: AppModel

    @State private var hour = 7
    @State private var minute = 30

    /// Common wake times, as minutes since midnight.
    private static let presets = [6 * 60 + 30, 7 * 60 + 30, 8 * 60 + 30]

    private static func label(for minutesOfDay: Int) -> String {
        String(format: "%02d:%02d", minutesOfDay / 60, minutesOfDay % 60)
    }

    private static let deadlineFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.onBatteryWhileActive {
                warning(
                    "Running on battery",
                    "Sleep is disabled system-wide, so this Mac will not sleep on battery. Restore now."
                )
            }

            if let error = model.lastError {
                warning("Something went wrong", error)
            }

            Divider()

            switch model.status {
            case .off, .offWithStaleState:
                offControls
            case .active, .activeTimerMissing:
                activeControls
            case .externallyDisabled:
                externallyDisabledNotice
            }

            Divider()

            HStack {
                Button("Refresh") { model.refresh() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { model.refresh() }
        .disabled(model.isBusy)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Overnight").font(.headline)
            Text(statusLine).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var statusLine: String {
        switch model.status {
        case .off:
            return "Off. This Mac sleeps normally."
        case .offWithStaleState:
            return "Off, with a leftover state file to clean up."
        case .active(let deadline):
            return "On until \(formatted(deadline))."
        case .activeTimerMissing(let deadline):
            return "On, but the \(formatted(deadline)) timer is missing."
        case .externallyDisabled:
            return "Sleep is disabled, but not by Overnight."
        }
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "an unknown time" }
        return Self.deadlineFormatter.string(from: date)
    }

    private var offControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            deadlinePicker(label: "Stay awake until")

            Button {
                model.enable(hour: hour, minute: minute)
            } label: {
                Text("Turn On").frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)

            if case .offWithStaleState = model.status {
                Button("Clean up leftover state") { model.disable() }
                    .font(.callout)
            }
        }
    }

    private var activeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .activeTimerMissing = model.status {
                warning(
                    "No automatic restore",
                    "The timer that would turn Overnight off is gone. Re-arm it, or turn Overnight off now."
                )
            }

            deadlinePicker(label: "Change deadline to")

            Button("Update Deadline") {
                model.changeDeadline(hour: hour, minute: minute)
            }
            .font(.callout)

            Button {
                model.disable()
            } label: {
                Text("Turn Off Now").frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    /// Overnight did not set this flag, so it holds no captured values and must not offer to
    /// replay any. Guessing would overwrite settings it never took.
    private var externallyDisabledNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Something else disabled sleep on this Mac.")
                .font(.callout)
            Text("Overnight has no saved settings to restore, so it will not change anything. To clear the flag yourself:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("sudo pmset -a disablesleep 0")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
    }

    // MARK: - Pieces

    private func deadlinePicker(label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout)
            HStack(spacing: 4) {
                Stepper(value: $hour, in: 0...23) {
                    Text(String(format: "%02d", hour)).monospacedDigit()
                }
                Text(":")
                Stepper(value: $minute, in: 0...59, step: 5) {
                    Text(String(format: "%02d", minute)).monospacedDigit()
                }
            }
            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.self) { minutesOfDay in
                    Button(Self.label(for: minutesOfDay)) {
                        hour = minutesOfDay / 60
                        minute = minutesOfDay % 60
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func warning(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }
}
