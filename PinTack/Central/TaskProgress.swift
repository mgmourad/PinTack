import SwiftUI
import AppKit

/// How a todo note's progress is drawn everywhere it appears: one square per task, in GitHub's
/// contribution-graph language — a bright square for a finished task, a dark dull one for an
/// unfinished task — followed by "3/7". SPEC.md §6.
enum TaskProgressStyle {
    static let done = NSColor(srgbRed: 0.22, green: 0.83, blue: 0.33, alpha: 1)     // #39d353
    static let todo = NSColor(srgbRed: 0.05, green: 0.27, blue: 0.16, alpha: 1)     // #0e4429
    static let square: CGFloat = 9
    static let gap: CGFloat = 3

    /// Gap between the last square and the "3/7" label.
    static let labelGap: CGFloat = 6

    /// Most squares on one row of a note's action bar. Past this the tracker wraps and the bar
    /// grows a row taller — the owner's call (2026-09-20), and deliberately unlimited.
    static let perRow = 6

    /// Above this many tasks the squares become a plain bar: 60 tiny squares is noise, not progress.
    /// Only the All Notes list, which has one line to work with, falls back to it.
    static let maxSquares = 24
}

/// The SwiftUI form, used in All Notes' todo tab.
struct TaskProgressBar: View {
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            if total <= TaskProgressStyle.maxSquares {
                HStack(spacing: TaskProgressStyle.gap) {
                    ForEach(0..<total, id: \.self) { index in
                        let isDone = index < done
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(nsColor: isDone ? TaskProgressStyle.done : TaskProgressStyle.todo))
                            .frame(width: TaskProgressStyle.square, height: TaskProgressStyle.square)
                            // A finished square glows, the way a lit contribution square does.
                            .shadow(color: Color(nsColor: TaskProgressStyle.done).opacity(isDone ? 0.85 : 0),
                                    radius: isDone ? 3.5 : 0)
                    }
                }
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: TaskProgressStyle.todo))
                        RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: TaskProgressStyle.done))
                            .frame(width: geo.size.width * (total == 0 ? 0 : Double(done) / Double(total)))
                            .shadow(color: Color(nsColor: TaskProgressStyle.done).opacity(0.85), radius: 3.5)
                    }
                }
                .frame(height: TaskProgressStyle.square)
            }
            Text("\(done)/\(total)")
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// The AppKit form, shown in a todo note's own action bar. Transparent to the mouse, so the empty
/// action bar still drags the note.
///
/// Squares WRAP: six to a row at most (the owner's cap, 2026-09-20), fewer on a note too narrow for
/// six, and as many rows as the tasks need. It used to be one row that simply vanished once it no
/// longer fitted, which is what made a todo note's tracker disappear at about seven items.
final class TaskProgressView: NSView {

    var counts: (done: Int, total: Int) = (0, 0) { didSet { needsDisplay = true } }
    /// Squares on one row. Set by whoever lays this out, from `grid`.
    var perRow: Int = TaskProgressStyle.perRow { didSet { needsDisplay = true } }
    /// Whether the "3/7" count is drawn. A note too narrow for both gives the count up rather
    /// than its squares or its tags.
    var showsLabel = true { didSet { needsDisplay = true } }
    /// The note's automatic text colour, for the "3/7" label.
    var foreground: NSColor = .black { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Drawn, not built from controls, so VoiceOver would otherwise find nothing here at all.
    override func isAccessibilityElement() -> Bool { counts.total > 0 }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? {
        counts.total > 0 ? "\(counts.done) of \(counts.total) tasks done" : nil
    }
    override func accessibilityValue() -> Any? { "\(counts.done)/\(counts.total)" }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)

    /// Room the "3/7" label needs. It is monospaced-digit, so the widest reading is total/total.
    static func labelWidth(for total: Int) -> CGFloat {
        ("\(total)/\(total)" as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    /// How `total` squares arrange themselves in `width` points, keeping `reservedForTags` points
    /// clear for the note's tag pills where it can.
    ///
    /// Six a row is what the owner asked for (2026-09-20), and a narrow note gives things up in a
    /// fixed order to keep it: first the tags' elbow room, then the "3/7" count, and only then
    /// squares a row. The tracker itself is never given up — hiding it is the bug this replaces.
    static func grid(total: Int, room: CGFloat,
                     reservedForTags: CGFloat = 0) -> (perRow: Int, rows: Int, showsLabel: Bool) {
        guard total > 0 else { return (0, 0, false) }
        let cap = min(TaskProgressStyle.perRow, total)
        func rows(_ perRow: Int) -> Int { (total + perRow - 1) / perRow }
        func block(_ perRow: Int, _ label: Bool) -> CGFloat { width(perRow: perRow, total: total, showsLabel: label) }

        // Preference order, widest arrangement first. Keeping the tags' room outranks both the
        // count and a sixth square, because a bar where the tags simply vanished is the fault this
        // replaces; only when nothing fits beside them is their room given up.
        for reserve in [reservedForTags, 0] {
            for perRow in stride(from: cap, through: 1, by: -1) {
                if block(perRow, true) <= room - reserve { return (perRow, rows(perRow), true) }
                if block(perRow, false) <= room - reserve { return (perRow, rows(perRow), false) }
            }
        }
        return (1, total, false)
    }

    /// Width this block occupies once it is wrapped `perRow` to a row.
    static func width(perRow: Int, total: Int, showsLabel: Bool) -> CGFloat {
        guard total > 0, perRow > 0 else { return 0 }
        let n = min(total, perRow)
        let squares = CGFloat(n) * TaskProgressStyle.square + CGFloat(n - 1) * TaskProgressStyle.gap
        return showsLabel ? squares + TaskProgressStyle.labelGap + labelWidth(for: total) : squares
    }

    /// Height `rows` rows of squares occupy.
    static func height(rows: Int) -> CGFloat {
        rows <= 0 ? 0 : CGFloat(rows) * TaskProgressStyle.square + CGFloat(rows - 1) * TaskProgressStyle.gap
    }

    override func draw(_ dirtyRect: NSRect) {
        guard counts.total > 0, perRow > 0 else { return }
        let side = TaskProgressStyle.square
        let unit = side + TaskProgressStyle.gap

        for index in 0..<counts.total {
            let x = CGFloat(index % perRow) * unit
            let y = CGFloat(index / perRow) * unit
            let isDone = index < counts.done
            let box = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: side, height: side),
                                   xRadius: 2, yRadius: 2)
            if isDone, let ctx = NSGraphicsContext.current?.cgContext {
                // A finished square glows, the way a lit contribution square does.
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 4, color: TaskProgressStyle.done.withAlphaComponent(0.9).cgColor)
                TaskProgressStyle.done.setFill()
                box.fill()
                ctx.restoreGState()
            }
            (isDone ? TaskProgressStyle.done : TaskProgressStyle.todo).setFill()
            box.fill()
        }

        // The count stays on the first row, so it does not wander as tasks are added.
        guard showsLabel else { return }
        let label = "\(counts.done)/\(counts.total)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: TaskProgressView.font,
            .foregroundColor: foreground.withAlphaComponent(0.65),
        ]
        let size = label.size(withAttributes: attributes)
        let firstRow = CGFloat(min(counts.total, perRow))
        let x = firstRow * TaskProgressStyle.square + (firstRow - 1) * TaskProgressStyle.gap
            + TaskProgressStyle.labelGap
        label.draw(at: NSPoint(x: x, y: (side - size.height) / 2), withAttributes: attributes)
    }
}
