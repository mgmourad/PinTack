import SwiftUI
import AppKit

/// The little panel behind the bell in a todo note's action bar. SPEC.md §6.
///
/// Deliberately three controls and nothing else: when it is due, whether to say so at the time,
/// and whether to say so earlier. A sticky note should not grow a scheduling dialog.
struct ReminderPopoverView: View {

    let note: Note
    var onChange: () -> Void
    /// Closes the popover. A panel with a Done button that leaves itself on screen reads as broken.
    var onDone: () -> Void

    @State private var enabled: Bool
    /// The date lives in a REFERENCE, not in @State. Writing SwiftUI state on every keystroke
    /// re-renders the panel, and a re-render takes keyboard focus off the date field: after the
    /// month was typed the caret left the control and the rest of the date went nowhere. Nothing
    /// in the panel's layout depends on the date, so nothing needs to re-render when it changes.
    @State private var dateBox: DateBox
    @State private var onTime: Bool
    @State private var aheadOn: Bool
    @State private var aheadValue: String
    @State private var aheadUnit: String

    init(note: Note, onChange: @escaping () -> Void, onDone: @escaping () -> Void = {}) {
        self.note = note
        self.onChange = onChange
        self.onDone = onDone
        let existing = note.due
        _enabled = State(initialValue: existing != nil)
        // A sensible first guess beats making someone dial in today's date: tomorrow, 9am.
        _dateBox = State(initialValue: DateBox(existing ?? ReminderPopoverView.defaultDue()))
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

            DateField(box: dateBox, isEnabled: enabled)

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
                Button("Done") { apply(); onDone() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320)
        .tint(Color(nsColor: Brand.accentNS))
        // Clicking outside is a perfectly ordinary way to finish, so the date is committed on the
        // way out as well as from Done.
        .onDisappear { apply() }
        .onChange(of: enabled) { _, _ in apply() }
        .onChange(of: onTime) { _, _ in apply() }
        .onChange(of: aheadOn) { _, _ in apply() }
        .onChange(of: aheadUnit) { _, _ in apply() }
    }

    private func apply() {
        note.due = enabled ? dateBox.date : nil
        note.remindOnTime = enabled && onTime
        note.remindAhead = (enabled && aheadOn) ? Note.normalizedAhead(aheadValue + aheadUnit) : ""
        VaultStore.shared.save(note)
        Reminders.shared.schedule(note)
        onChange()
    }
}

/// Holds the chosen date OUTSIDE SwiftUI's state, so typing into the field changes nothing SwiftUI
/// watches. See the note on `dateBox` above: this is what keeps the keyboard in the control.
final class DateBox {
    var date: Date
    init(_ date: Date) { self.date = date }
}

/// AppKit's NSDatePicker rather than SwiftUI's `DatePicker`.
///
/// SwiftUI's own DatePicker is rebuilt from its binding on every re-render, which threw away a
/// half-typed entry: "37" in the minute field committed the 3, re-rendered, and started over on the
/// 7, so the minute came out as 7. AppKit owns the editing state here and nothing pushes a value
/// back into the control while it is open.
private struct DateField: NSViewRepresentable {

    let box: DateBox
    var isEnabled: Bool

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.controlSize = .regular
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.pickerChanged(_:))
        picker.dateValue = box.date
        #if DEBUG
        DateField.mostRecent = picker
        #endif
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.box = box
        // The only write, and it is guarded: setting a control's enabled state while it is being
        // typed into ends the entry. The VALUE is never written back — the picker is the one that
        // holds it while the panel is open.
        if picker.isEnabled != isEnabled { picker.isEnabled = isEnabled }
    }

    func makeCoordinator() -> Coordinator { Coordinator(box: box) }

    final class Coordinator: NSObject {
        var box: DateBox
        init(box: DateBox) { self.box = box }
        @objc func pickerChanged(_ sender: NSDatePicker) { box.date = sender.dateValue }
    }

    #if DEBUG
    /// The self-test types into this to prove a two-digit entry survives.
    static weak var mostRecent: NSDatePicker?
    #endif
}

#if DEBUG
enum ReminderPopoverDebug {
    static var datePicker: NSDatePicker? { DateField.mostRecent }
}
#endif
