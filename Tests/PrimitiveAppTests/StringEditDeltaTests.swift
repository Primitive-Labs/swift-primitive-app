import XCTest
@testable import PrimitiveApp

/// Tests for the UTF-16 string-edit delta algorithm used by LiveText
/// to translate before/after string snapshots into Y.Text insert/remove ops.
final class StringEditDeltaTests: XCTestCase {

    // MARK: - Trivial cases

    func testEmptyToEmpty() {
        let d = StringEditDelta(from: "", to: "")
        XCTAssertTrue(d.isNoOp)
        XCTAssertEqual(d.start, 0)
        XCTAssertEqual(d.removeCount, 0)
        XCTAssertEqual(d.insert, "")
    }

    func testSameStringNoOp() {
        let d = StringEditDelta(from: "hello", to: "hello")
        XCTAssertTrue(d.isNoOp)
    }

    func testEmptyToString() {
        let d = StringEditDelta(from: "", to: "hello")
        XCTAssertEqual(d.start, 0)
        XCTAssertEqual(d.removeCount, 0)
        XCTAssertEqual(d.insert, "hello")
    }

    func testStringToEmpty() {
        let d = StringEditDelta(from: "hello", to: "")
        XCTAssertEqual(d.start, 0)
        XCTAssertEqual(d.removeCount, 5)
        XCTAssertEqual(d.insert, "")
    }

    // MARK: - Single-char edits (the common case while typing)

    func testTypeCharacterAtEnd() {
        let d = StringEditDelta(from: "hell", to: "hello")
        XCTAssertEqual(d.start, 4)
        XCTAssertEqual(d.removeCount, 0)
        XCTAssertEqual(d.insert, "o")
    }

    func testTypeCharacterAtStart() {
        let d = StringEditDelta(from: "ello", to: "hello")
        XCTAssertEqual(d.start, 0)
        XCTAssertEqual(d.removeCount, 0)
        XCTAssertEqual(d.insert, "h")
    }

    func testTypeCharacterInMiddle() {
        let d = StringEditDelta(from: "helo", to: "hello")
        XCTAssertEqual(d.start, 3)
        XCTAssertEqual(d.removeCount, 0)
        XCTAssertEqual(d.insert, "l")
    }

    func testBackspaceAtEnd() {
        let d = StringEditDelta(from: "hello", to: "hell")
        XCTAssertEqual(d.start, 4)
        XCTAssertEqual(d.removeCount, 1)
        XCTAssertEqual(d.insert, "")
    }

    func testBackspaceInMiddle() {
        let d = StringEditDelta(from: "hello", to: "helo")
        XCTAssertEqual(d.start, 3)
        XCTAssertEqual(d.removeCount, 1)
        XCTAssertEqual(d.insert, "")
    }

    // MARK: - Bulk edits (paste, select-and-replace)

    func testPasteAtEnd() {
        let d = StringEditDelta(from: "hello", to: "hello world")
        XCTAssertEqual(d.start, 5)
        XCTAssertEqual(d.removeCount, 0)
        XCTAssertEqual(d.insert, " world")
    }

    func testSelectAndReplace() {
        let d = StringEditDelta(from: "hello world", to: "hello there")
        XCTAssertEqual(d.start, 6)
        XCTAssertEqual(d.removeCount, 5) // "world"
        XCTAssertEqual(d.insert, "there")
    }

    func testReplaceWholeString() {
        let d = StringEditDelta(from: "hello", to: "world")
        XCTAssertEqual(d.start, 0)
        XCTAssertEqual(d.removeCount, 5)
        XCTAssertEqual(d.insert, "world")
    }

    // MARK: - Unicode (UTF-16 code unit semantics)

    func testInsertBMPChar() {
        // 'é' is 1 UTF-16 code unit (BMP).
        let d = StringEditDelta(from: "ab", to: "aéb")
        XCTAssertEqual(d.start, 1)
        XCTAssertEqual(d.removeCount, 0)
        XCTAssertEqual(d.insert, "é")
    }

    func testRemoveBMPChar() {
        let d = StringEditDelta(from: "aéb", to: "ab")
        XCTAssertEqual(d.start, 1)
        XCTAssertEqual(d.removeCount, 1) // 'é' = 1 UTF-16 unit
        XCTAssertEqual(d.insert, "")
    }

    func testInsertEmojiSurrogatePair() {
        // '🎉' is 2 UTF-16 code units (surrogate pair).
        let d = StringEditDelta(from: "ab", to: "a🎉b")
        XCTAssertEqual(d.start, 1)
        XCTAssertEqual(d.removeCount, 0)
        XCTAssertEqual(d.insert, "🎉")
    }

    func testRemoveEmojiSurrogatePair() {
        let d = StringEditDelta(from: "a🎉b", to: "ab")
        XCTAssertEqual(d.start, 1)
        XCTAssertEqual(d.removeCount, 2) // 🎉 = 2 UTF-16 units
        XCTAssertEqual(d.insert, "")
    }

    func testReplaceCharWithEmoji() {
        let d = StringEditDelta(from: "abc", to: "a🎉c")
        XCTAssertEqual(d.start, 1)
        XCTAssertEqual(d.removeCount, 1)
        XCTAssertEqual(d.insert, "🎉")
    }

    /// Pathological case: appending to a string whose last char repeats elsewhere.
    /// Verifies we don't accidentally over-match the suffix.
    func testRepeatedCharsInSuffix() {
        let d = StringEditDelta(from: "aaa", to: "aaaa")
        XCTAssertEqual(d.removeCount, 0)
        XCTAssertEqual(d.insert, "a")
        // start could be anywhere in 0...3 — they're all valid for inserting "a" into "aaa"
        XCTAssertTrue((0...3).contains(d.start))
    }

    // MARK: - Round-trip property

    /// Applying the delta should reproduce the new string.
    func testRoundTripVariousEdits() {
        let cases: [(old: String, new: String)] = [
            ("", "hello"),
            ("hello", ""),
            ("hello", "hello world"),
            ("hello world", "hello"),
            ("hello world", "goodbye world"),
            ("hello world", "hello, world"),
            ("abc", "axyzc"),
            ("abc", "ac"),
            ("ab", "a🎉b"),
            ("a🎉b", "ab"),
            ("a🎉b", "a🎈b"),
            ("héllo", "hello"),
            ("hello", "héllo"),
            ("aaa", "aaaa"),
            ("aaaa", "aaa"),
        ]

        for (old, new) in cases {
            let d = StringEditDelta(from: old, to: new)
            let result = applyDelta(d, to: old)
            XCTAssertEqual(result, new, "Round-trip failed for '\(old)' -> '\(new)' (delta: start=\(d.start) remove=\(d.removeCount) insert='\(d.insert)' result='\(result)')")
        }
    }

    // MARK: - Helpers

    /// Apply a delta to a string by manipulating its UTF-16 view, mirroring how
    /// YText would apply remove + insert ops at UTF-16 indices.
    private func applyDelta(_ d: StringEditDelta, to old: String) -> String {
        var units = Array(old.utf16)
        if d.removeCount > 0 {
            units.removeSubrange(d.start..<(d.start + d.removeCount))
        }
        if !d.insert.isEmpty {
            let insertUnits = Array(d.insert.utf16)
            units.insert(contentsOf: insertUnits, at: d.start)
        }
        return String(decoding: units, as: UTF16.self)
    }
}
