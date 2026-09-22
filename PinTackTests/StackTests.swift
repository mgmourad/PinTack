import XCTest
@testable import PinTack

/// Note Stacks' file, `.pintack/stacks.json` (SPEC.md §5.10). The notes themselves never carry a
/// stack; this file does, so what it keeps and drops is tested here.
final class StackTests: VaultTestCase {

    private var meta: URL { root.appendingPathComponent(".pintack", isDirectory: true) }
    private var file: URL { meta.appendingPathComponent("stacks.json") }

    private func stack(_ id: String, _ members: [String], order: [String]? = nil) -> NoteStack {
        NoteStack(id: id, name: "S-\(id)", members: members, order: order ?? members)
    }

    private func write(_ stacks: [NoteStack]) throws {
        struct File: Codable { var version = 1; var stacks: [NoteStack] }
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try JSONEncoder().encode(File(stacks: stacks)).write(to: file)
    }

    func testAStackSurvivesARoundTripThroughItsFile() throws {
        var s = stack("a", ["n1", "n2", "n3"], order: ["n2", "n1", "n3"])
        s.pinned = true
        s.collapsed = true
        s.before["n1"] = .init(x: 10, y: 20, width: 300, height: 250, collapsed: false)
        try write([s])
        let m = StackManager()
        m.load(from: meta, alive: ["n1", "n2", "n3"])
        XCTAssertEqual(m.stacks, [s], "name, numbers, order, pin, collapse and the before-sizes all come back")
        XCTAssertEqual(m.stacks.first?.number(of: "n3"), 3)
        XCTAssertEqual(m.stacks.first?.front, "n2")
    }

    func testANoteThatIsGoneLeavesItsStackAndTheFileIsRewritten() throws {
        try write([stack("a", ["n1", "gone", "n2"])])
        let m = StackManager()
        m.load(from: meta, alive: ["n1", "n2"])
        XCTAssertEqual(m.stacks.first?.members, ["n1", "n2"])
        XCTAssertEqual(m.stacks.first?.order, ["n1", "n2"])
        let text = try read(file)
        XCTAssertFalse(text.contains("gone"), "the pruned file is what is on disk now")
    }

    func testAStackOfOneIsNoStack() {
        XCTAssertTrue(StackManager.pruned([stack("a", ["n1", "gone"])], alive: ["n1"]).isEmpty)
    }

    func testANoteBelongsToOneStackAtATime() {
        let result = StackManager.pruned([stack("a", ["n1", "n2"]), stack("b", ["n2", "n3", "n4"])],
                                         alive: ["n1", "n2", "n3", "n4"])
        XCTAssertEqual(result.map(\.members), [["n1", "n2"], ["n3", "n4"]])
    }

    func testNoMoreThanFiveAndAnOrderThatNamesEveryMemberOnce() {
        let ids = (1...7).map { "n\($0)" }
        let result = StackManager.pruned([stack("a", ids, order: ["n3", "n3", "n9"])], alive: Set(ids))
        XCTAssertEqual(result.first?.members, Array(ids.prefix(5)))
        XCTAssertEqual(result.first?.order, ["n3", "n1", "n2", "n4", "n5"])
    }

    func testAnUnreadableFileLosesNothingElse() throws {
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)
        let m = StackManager()
        m.load(from: meta, alive: [])
        XCTAssertTrue(m.stacks.isEmpty)
        XCTAssertEqual(try read(file), "{ not json", "a file it cannot read is left for a person to look at, not overwritten")
    }
}
