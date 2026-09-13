import SwiftUI

struct CustomTimeView: View {

    @State private var time: Date
    private let onConfirm: (Int, Int) -> Void
    private let onCancel: () -> Void

    init(minutesSinceMidnight: Int, onConfirm: @escaping (Int, Int) -> Void, onCancel: @escaping () -> Void) {
        _time = State(initialValue: Self.date(fromMinutesSinceMidnight: minutesSinceMidnight))
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Wake at")
                .font(.headline)

            DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                .labelsHidden()

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Set", action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 240)
    }

    /// The picker assigns its own seconds value, and the date component is whatever today is,
    /// so only the hour and minute may ever leave this view.
    private func confirm() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        guard let hour = parts.hour, let minute = parts.minute else { return }
        onConfirm(hour, minute)
    }

    private static func date(fromMinutesSinceMidnight minutes: Int) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = minutes / 60
        components.minute = minutes % 60
        components.second = 0
        return Calendar.current.date(from: components) ?? Date()
    }
}
