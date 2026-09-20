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

    /// Above this many tasks the squares become a plain bar: 60 tiny squares is noise, not progress.
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
final class TaskProgressView: NSView {

    var counts: (done: Int, total: Int) = (0, 0) { didSet { needsDisplay = true } }
    /// The note's automatic text colour, for the "3/7" label.
    var foreground: NSColor = .black { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)

    /// Width this needs for `total` tasks, so the footer can decide whether it fits.
    static func width(for total: Int) -> CGFloat {
        guard total > 0 else { return 0 }
        let squares = min(total, TaskProgressStyle.maxSquares)
        let label = ("\(total)/\(total)" as NSString).size(withAttributes: [.font: font]).width
        return CGFloat(squares) * TaskProgressStyle.square
            + CGFloat(max(0, squares - 1)) * TaskProgressStyle.gap + 6 + label.rounded(.up)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard counts.total > 0 else { return }
        let height = TaskProgressStyle.square
        let y = ((bounds.height - height) / 2).rounded()
        var x: CGFloat = 0

        let squares = min(counts.total, TaskProgressStyle.maxSquares)
        // With more tasks than squares, each square stands for a slice of the list.
        let filled = Int((Double(counts.done) / Double(counts.total) * Double(squares)).rounded(.down))
        for index in 0..<squares {
            let isDone = counts.total <= TaskProgressStyle.maxSquares ? index < counts.done : index < filled
            let box = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: height, height: height), xRadius: 2, yRadius: 2)
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
            x += height + TaskProgressStyle.gap
        }

        let label = "\(counts.done)/\(counts.total)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: TaskProgressView.font,
            .foregroundColor: foreground.withAlphaComponent(0.65),
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: x + 3, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}
