import AppKit

/// Everything the approval window shows. SPEC.md §13.4.
struct ApprovalRequest {
    var pluginName: String
    var noteTitle: String?
    var kind: TrustKey.Kind
    var text: String            // the exact command line, or the Shortcut's name
    var cwd: String
    var shell: String
}

/// Asks the person whether something may run. Only ever answered by a human: a plugin cannot reach
/// this, and there is deliberately no flag, setting or environment variable that answers it. Tests
/// inject a fake presenter, which is why this is a protocol.
protocol ApprovalPresenter {
    func approve(_ request: ApprovalRequest) -> Bool
}

/// A native sheet that shows the EXACT string that will run, in a monospaced, selectable, scrollable
/// box, so a friendly button label can never conceal what it does.
final class NativeApprovalPresenter: ApprovalPresenter {

    func approve(_ r: ApprovalRequest) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch r.kind {
        case .command:  alert.messageText = "Allow this command to run?"
        case .shortcut: alert.messageText = "Allow this macOS Shortcut to run?"
        }
        let from = r.noteTitle.map { " from the note “\($0)”" } ?? ""
        var info = "The “\(r.pluginName)” plugin\(from) wants to run the following."
        if r.kind == .command {
            info += "\n\nIt runs in your login shell (\(r.shell)), in \(r.cwd), with your account's permissions."
        }
        info += "\n\nRead it before you approve. Your approval is remembered for exactly this text"
            + (r.kind == .command ? " and this folder" : "") + "; changing even one character asks again."
        alert.informativeText = info

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 470, height: 130))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = r.text
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        scroll.documentView = text
        alert.accessoryView = scroll

        // Cancel is the default button: an approval must be a deliberate click, not a reflexive Return.
        let approve = alert.addButton(withTitle: r.kind == .command ? "Approve and Run" : "Approve and Run")
        let cancel = alert.addButton(withTitle: "Cancel")
        approve.keyEquivalent = ""
        cancel.keyEquivalent = "\r"

        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
