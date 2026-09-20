import SwiftUI
import AppKit

/// The little panel behind the bell in a todo note's action bar. SPEC.md §6.
///
/// Deliberately three controls and nothing else: when it is due, whether to say so at the time,
/// and whether to say so earlier. A sticky note should not grow a scheduling dialog.
struct ReminderPopoverView: View {

    let note: Note
    var onChange: () -> Void

    @State private var enabled: Bool
    @State private var due: Date
    @State private var onTime: Bool
    @State private var aheadOn: Bool
    @State private var aheadValue: String
    @State private var aheadUnit: String

    init(note: Note, onChange: @escaping () -> Void) {
        self.note = note
        self.onChange = onChange
        let existing = note.due
        _enabled = State(initialValue: existing != nil)
        // A sensible first guess beats making someone dial in today's date: tomorrow, 9am.
        _due = State(initialValue: existing ?? ReminderPopoverView.defaultDue())
        _onTime = State(initialValue: existing == nil ? true : note.remindOnTime)
        _aheadOn = State(initialValue: !note.remindAhead.isEmpty)
        _aheadValue = State(initialValue: note.remindAhead.isEmpty ? "30" : String(note.remindAhead.dropLast()))
        _aheadUnit = State(initialValue: note.remindAhead.isEmpty ? "m" : String(note.remindAhead.suffix(1)))
    }

    private static func defaultDue() -> Date {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Due date", isOn: $enabled).font(.system(size: 13, weight: .semibold))

            DatePicker("", selection: $due, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
                .labelsHidden()
                .disabled(!enabled)

            Divider()

            Toggle("Remind me at the time", isOn: $onTime).disabled(!enabled)

            HStack(spacing: 6) {
                Toggle("Remind me", isOn: $aheadOn).disabled(!enabled)
                TextField("30", text: $aheadValue)
                    .frame(width: 46)
                    .multilineTextAlignment(.trailing)
                    .disabled(!enabled || !aheadOn)
                    // Digits only: "half an hour" cannot be scheduled.
                    .onChange(of: aheadValue) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(5))
                        if digits != new { aheadValue = digits }
                    }
                Picker("", selection: $aheadUnit) {
                    Text("minutes").tag("m")
                    Text("hours").tag("h")
                    Text("days").tag("d")
                }
                .labelsHidden().frame(width: 92)
                .disabled(!enabled || !aheadOn)
                Text("before").foregroundStyle(.secondary)
            }

            if enabled, !onTime, !aheadOn {
                Label("Nothing will be announced; the date is just written on the note.",
                      systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                if note.due != nil {
                    Button("Clear") { enabled = false; apply() }
                }
                Spacer()
                Button("Done") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320)
        .tint(Color(nsColor: Brand.accentNS))
        .onChange(of: enabled) { _, _ in apply() }
        .onChange(of: due) { _, _ in apply() }
        .onChange(of: onTime) { _, _ in apply() }
        .onChange(of: aheadOn) { _, _ in apply() }
        .onChange(of: aheadUnit) { _, _ in apply() }
    }

    private func apply() {
        note.due = enabled ? due : nil
        note.remindOnTime = enabled && onTime
        note.remindAhead = (enabled && aheadOn) ? Note.normalizedAhead(aheadValue + aheadUnit) : ""
        VaultStore.shared.save(note)
        Reminders.shared.schedule(note)
        onChange()
    }
}
