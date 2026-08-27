import XCTest
@testable import PrimitiveApp
import JsBaoClient

/// #2244 Phase 2 — the debug inspector's timeline records the client's emit
/// instant, its emit order, and the main-actor hop it cost to record them.
///
/// Two kinds of check here. The record shape is a unit test on
/// `DebugInspector.makeEventRecord` — the whole timestamp contract without
/// standing up the inspector's HTTP server. The wiring (all nine subscriptions
/// on the metadata form, the old residual note gone) is only visible in the
/// source, so it is checked there.
final class InspectorEventRecordTests: XCTestCase {

    private var inspectorSource: String {
        get throws {
            var url = URL(fileURLWithPath: #filePath)
            // .../Tests/PrimitiveAppTests/<this file>
            for _ in 0..<3 { url.deleteLastPathComponent() }
            return try String(
                contentsOf: url.appendingPathComponent("Sources/PrimitiveApp/Debug/DebugInspector.swift"),
                encoding: .utf8
            )
        }
    }

    private var performanceTabSource: String {
        get throws {
            var url = URL(fileURLWithPath: #filePath)
            for _ in 0..<3 { url.deleteLastPathComponent() }
            return try String(
                contentsOf: url.appendingPathComponent("Sources/PrimitiveApp/Debug/ui/tabs/performance.js"),
                encoding: .utf8
            )
        }
    }

    // MARK: - Behavior 7: ts is the emit clock, not the record clock

    /// `ts` comes from `delivery.emittedAt`, so a record written a whole second
    /// after the emit still reports the emit's millisecond.
    func testRecordTimestampComesFromTheEmitNotTheRecordingInstant() throws {
        let emittedAt = Date(timeIntervalSince1970: 1_770_000_000.123)
        let deliveredAt = emittedAt.addingTimeInterval(1.0)

        let record = DebugInspector.makeEventRecord(
            type: "documentLoaded",
            fields: ["documentId": "doc-1", "source": "sqlite"],
            delivery: EventDelivery(emittedAt: emittedAt, sequence: 7),
            deliveredAt: deliveredAt
        )

        XCTAssertEqual(
            record["ts"] as? Int, Int(emittedAt.timeIntervalSince1970 * 1000),
            "ts must be the emit instant in milliseconds"
        )
        XCTAssertNotEqual(
            record["ts"] as? Int, Int(deliveredAt.timeIntervalSince1970 * 1000),
            "ts must not be the instant the record was written"
        )
        XCTAssertEqual(record["type"] as? String, "documentLoaded")
        XCTAssertEqual(record["documentId"] as? String, "doc-1", "payload fields are preserved")
        XCTAssertEqual(record["source"] as? String, "sqlite")
    }

    // MARK: - Behavior 8: seq rides along as the timeline's tie-break

    /// Every record carries the emit sequence, so two events emitted in the
    /// same millisecond can still be ordered.
    func testRecordCarriesTheEmitSequence() throws {
        let emittedAt = Date(timeIntervalSince1970: 1_770_000_000.500)
        let first = DebugInspector.makeEventRecord(
            type: "sync",
            fields: ["documentId": "doc-1"],
            delivery: EventDelivery(emittedAt: emittedAt, sequence: 41),
            deliveredAt: emittedAt
        )
        let second = DebugInspector.makeEventRecord(
            type: "documentSyncStateChanged",
            fields: ["documentId": "doc-1"],
            delivery: EventDelivery(emittedAt: emittedAt.addingTimeInterval(0.0002), sequence: 42),
            deliveredAt: emittedAt
        )

        XCTAssertEqual(first["ts"] as? Int, second["ts"] as? Int,
                       "these two emits land in the same millisecond — the case seq exists for")
        XCTAssertEqual(first["seq"] as? UInt64, 41)
        XCTAssertEqual(second["seq"] as? UInt64, 42)
    }

    /// The record is what goes down the SSE channel, so every field has to
    /// survive `JSONSerialization` — including the `UInt64` sequence.
    func testRecordIsJSONSerializable() throws {
        let record = DebugInspector.makeEventRecord(
            type: "status",
            fields: ["status": "connected"],
            delivery: EventDelivery(emittedAt: Date(), sequence: UInt64.max / 2),
            deliveredAt: Date()
        )
        XCTAssertTrue(JSONSerialization.isValidJSONObject(record))
        let data = try JSONSerialization.data(withJSONObject: record)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual((decoded["seq"] as? NSNumber)?.uint64Value, UInt64.max / 2)
        XCTAssertNotNil(decoded["ts"])
        XCTAssertNotNil(decoded["deliveredTs"])
    }

    // MARK: - Behavior 14: the hop cost is recorded too

    /// The record carries both instants, so the Performance tab can show the
    /// main-actor hop the recording cost.
    func testRecordCarriesTheDeliveryInstantSoTheHopIsVisible() throws {
        let emittedAt = Date(timeIntervalSince1970: 1_770_000_000.000)
        let deliveredAt = emittedAt.addingTimeInterval(0.250)

        let record = DebugInspector.makeEventRecord(
            type: "sync",
            fields: ["documentId": "doc-1"],
            delivery: EventDelivery(emittedAt: emittedAt, sequence: 1),
            deliveredAt: deliveredAt
        )

        let ts = try XCTUnwrap(record["ts"] as? Int)
        let deliveredTs = try XCTUnwrap(record["deliveredTs"] as? Int)
        XCTAssertEqual(deliveredTs - ts, 250, "the hop the Performance tab shows is deliveredTs - ts")
    }

    /// The Performance tab derives the hop column from those two fields, and
    /// sorts on `seq` — the emit order — whenever both rows carry it, so
    /// neither a same-millisecond burst nor a backwards clock adjustment can
    /// invert the timeline. `ts` only orders records from before `seq` existed.
    /// The behavior itself is pinned in `tests/unit/inspector/performance-timeline.test.ts`;
    /// this checks the shipped source still has the sort it was reviewed with.
    func testPerformanceTabSortsOnSeqAndDerivesTheHop() throws {
        let source = try performanceTabSource
        XCTAssertTrue(
            source.contains("if (a.seq != null && b.seq != null) return b.seq - a.seq;"),
            "the timeline must sort on seq when both rows carry it"
        )
        XCTAssertTrue(
            source.contains("return (b.ts - a.ts) || ((b.seq || 0) - (a.seq || 0));"),
            "records without a seq must still fall back to ts order"
        )
        XCTAssertTrue(source.contains("perfHopMs(e)"), "the hop column must be derived in the tab")
        XCTAssertTrue(
            source.contains("e.deliveredTs - e.ts"),
            "the hop is the gap between the emit and the recording"
        )
    }

    // MARK: - Behavior 9: the wiring, and the residual note that is now fixed

    /// All nine event subscriptions take the metadata form. A subscription left
    /// on the plain form would silently go back to record-time timestamps.
    func testAllNineSubscriptionsUseTheDeliveryForm() throws {
        let source = try inspectorSource
        let start = try XCTUnwrap(
            source.range(of: "let s: [EventSubscription] = ["),
            "the subscription list moved"
        )
        let end = try XCTUnwrap(
            source.range(of: "subscriptions.append(contentsOf: s)", range: start.upperBound..<source.endIndex),
            "the subscription list moved"
        )
        let region = String(source[start.upperBound..<end.lowerBound])

        let withDelivery = region.components(separatedBy: "withDelivery:").count - 1
        let total = region.components(separatedBy: "client.observeOnMainActor(").count - 1
        XCTAssertEqual(total, 9, "the inspector observes nine client events")
        XCTAssertEqual(withDelivery, 9, "every one of them must take the delivery metadata")

        let recordCalls = region.components(separatedBy: "recordEvent(").count - 1
        let deliveryArguments = region.components(separatedBy: "delivery: d").count - 1
        XCTAssertEqual(recordCalls, 9)
        XCTAssertEqual(deliveryArguments, 9, "every record must be written with its delivery metadata")
    }

    /// The `#2244` residual note is gone — the timestamp it described as
    /// unavailable is what this file now records.
    func testTheResidualTimestampNoteIsGone() throws {
        let source = try inspectorSource
        XCTAssertFalse(
            source.contains("#2244"),
            "the #2244 note must be removed now that the inspector has emit-accurate timestamps"
        )
        XCTAssertTrue(
            source.contains("EventDelivery` carries the"),
            "the comment should describe the mechanism that replaced it"
        )
    }
}
