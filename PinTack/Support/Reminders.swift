import AppKit
import UserNotifications

/// Due-date reminders for todo notes. SPEC.md §6.
///
/// Scheduled with UNUserNotificationCenter, so they still fire when PinTack is not in front; the
/// dates live in the note's own frontmatter, so a reminder travels with the note through sync
/// rather than sitting in app state that a second Mac would never see.
///
/// Permission is asked for the first time a reminder is actually set, not at launch: a sticky-note
/// app that demands notification access before you have asked for anything is obnoxious, and the
/// answer is meaningless until there is something to deliver.
final class Reminders: NSObject, UNUserNotificationCenterDelegate {

    static let shared = Reminders()

    private var centre: UNUserNotificationCenter? {
        // Returns nil rather than trapping when there is no real bundle (unit tests, odd launches).
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    /// Set once the user has been asked, so we ask at most once per launch.
    private var askedThisLaunch = false

    func start() {
        centre?.delegate = self
    }

    /// Re-scheduling everything on launch is what makes this survive a quit: notifications that
    /// were already delivered are gone, and anything still in the future is put back.
    func rescheduleAll(_ notes: [Note]) {
        guard let centre else { return }
        centre.getPendingNotificationRequests { pending in
            let wanted = Set(notes.flatMap { note in note.reminderDates.map { Reminders.identifier(note, $0.id) } })
            let stale = pending.map(\.identifier).filter { $0.hasPrefix("pintack.") && !wanted.contains($0) }
            DispatchQueue.main.async {
                centre.removePendingNotificationRequests(withIdentifiers: stale)
                for note in notes where note.due != nil { self.schedule(note, requestPermission: false) }
            }
        }
    }

    static func identifier(_ note: Note, _ kind: String) -> String { "pintack.\(note.id).\(kind)" }

    /// Replaces whatever was scheduled for this note with what its frontmatter now says.
    func schedule(_ note: Note, requestPermission: Bool = true) {
        guard let centre else { return }
        cancel(note)
        let wanted = note.reminderDates
        guard !wanted.isEmpty else { return }

        let post = { [weak self] in
            guard let self else { return }
            for (kind, date) in wanted {
                let content = UNMutableNotificationContent()
                content.title = note.title
                content.body = self.bodyText(for: note, kind: kind)
                content.sound = .default
                content.userInfo = ["noteID": note.id]

                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                centre.add(UNNotificationRequest(identifier: Reminders.identifier(note, kind),
                                                 content: content, trigger: trigger)) { error in
                    if let error { NSLog("PinTack: could not schedule reminder: \(error)") }
                }
            }
        }

        centre.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                DispatchQueue.main.async(execute: post)
            case .notDetermined where requestPermission:
                guard !self.askedThisLaunch else { return }
                self.askedThisLaunch = true
                centre.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else {
                        DispatchQueue.main.async { Toast.show("Reminders need notification permission") }
                        return
                    }
                    DispatchQueue.main.async(execute: post)
                }
            case .denied:
                DispatchQueue.main.async {
                    Toast.show("Notifications are off for PinTack in System Settings")
                }
            default:
                break
            }
        }
    }

    private func bodyText(for note: Note, kind: String) -> String {
        guard let due = note.due else { return "Due" }
        let when = due.formatted(date: .abbreviated, time: .shortened)
        if kind == "ahead", let ahead = note.remindAheadInterval {
            return "Due in \(Reminders.friendly(ahead)) — \(when)"
        }
        return "Due now — \(when)"
    }

    static func friendly(_ seconds: TimeInterval) -> String {
        if seconds >= 86400 { let d = Int(seconds / 86400); return "\(d) day\(d == 1 ? "" : "s")" }
        if seconds >= 3600  { let h = Int(seconds / 3600);  return "\(h) hour\(h == 1 ? "" : "s")" }
        let m = Int(seconds / 60); return "\(m) minute\(m == 1 ? "" : "s")"
    }

    func cancel(_ note: Note) {
        centre?.removePendingNotificationRequests(withIdentifiers: ["ontime", "ahead"].map { Reminders.identifier(note, $0) })
    }

    // MARK: Delivery

    /// Show the banner even when PinTack is the active app; a reminder you only get when you are
    /// looking elsewhere is not much of a reminder.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Clicking the banner brings that note to the front.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["noteID"] as? String,
           let note = VaultStore.shared.note(id: id) {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                WindowManager.shared.open(note, focus: true).makeKeyAndOrderFront(nil)
            }
        }
        completionHandler()
    }
}
