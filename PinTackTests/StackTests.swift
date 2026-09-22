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

    // MARK: The file is disposable, like the search index: nothing it says can stop a launch or touch a note.

    func testAMissingFileMeansNoStacksAndWritesNothing() {
        let m = StackManager()
        m.load(from: meta, alive: ["n1", "n2"])
        XCTAssertTrue(m.stacks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "no stacks, so no file is conjured up")
    }

    func testAFileThatCannotBeReadMeansNoStacks() throws {
        try write([stack("a", ["n1", "n2"])])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let m = StackManager()
        m.load(from: meta, alive: ["n1", "n2"])
        XCTAssertTrue(m.stacks.isEmpty)
    }

    func testTheWrongShapeOfJSONMeansNoStacks() throws {
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try #"{"version": 9, "stacks": [{"id": 3, "members": "n1"}]}"#.write(to: file, atomically: true, encoding: .utf8)
        let m = StackManager()
        m.load(from: meta, alive: ["n1"])
        XCTAssertTrue(m.stacks.isEmpty)
    }

    func testStaleReferencesAreDroppedEverywhereTheyAppear() throws {
        var s = stack("a", ["n1", "gone", "n2"], order: ["gone", "n2", "n1"])
        s.before = ["n1": .init(x: 0, y: 0, width: 1, height: 1, collapsed: false),
                    "gone": .init(x: 0, y: 0, width: 1, height: 1, collapsed: false)]
        try write([s, stack("b", ["gone", "also-gone"])])
        let m = StackManager()
        m.load(from: meta, alive: ["n1", "n2"])
        XCTAssertEqual(m.stacks.count, 1, "a stack whose notes are all gone is gone")
        XCTAssertEqual(m.stacks.first?.order, ["n2", "n1"])
        XCTAssertEqual(m.stacks.first.map { Set($0.before.keys) }, ["n1"])
    }

    func testNothingInTheStackFileEverModifiesANote() throws {
        let a = store.createNote(body: "first"), b = store.createNote(body: "second")
        let before = try [a, b].map { try read($0.fileURL) }
        for text in ["{ not json", #"{"version":1,"stacks":[]}"#] {
            try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
            StackManager().load(from: meta, alive: [a.id, b.id])
        }
        try write([stack("s", [a.id, "gone", b.id])])
        StackManager().load(from: meta, alive: [a.id, b.id])
        XCTAssertEqual(try [a, b].map { try read($0.fileURL) }, before, "a stack file, good or bad, is never written into a note")
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
