import XCTest
@testable import PinTack

/// A partial write must never be able to corrupt a note. CLAUDE.md constraint 5, SPEC.md §4.5.
final class AtomicWriterTests: VaultTestCase {

    func testCreatesAndReplaces() throws {
        let f = root.appendingPathComponent("a.md")
        try AtomicWriter.write("one", to: f)
        XCTAssertEqual(try read(f), "one")
        try AtomicWriter.write("two", to: f)
        XCTAssertEqual(try read(f), "two")
    }

    func testLeavesNoTempFilesBehind() throws {
        let f = root.appendingPathComponent("a.md")
        for i in 0..<20 { try AtomicWriter.write("v\(i)", to: f) }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testAFailedWriteLeavesTheOriginalIntactAndCleansUp() throws {
        let f = root.appendingPathComponent("keep.md")
        try AtomicWriter.write("precious", to: f)

        // Make the directory unwritable so the temp file cannot be created.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        XCTAssertThrowsError(try AtomicWriter.write("partial garbage", to: f))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)

        XCTAssertEqual(try read(f), "precious")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }, [])
    }

    func testTempFileIsInTheSameDirectoryAsTheTarget() throws {
        // Same directory means same volume, so the swap is a rename rather than a copy.
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try AtomicWriter.write("x", to: sub.appendingPathComponent("n.md"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sub.path), ["n.md"])
    }
}
