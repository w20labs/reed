import XCTest
@testable import Reed

/// The per-press bookkeeping behind overlapped cleanup: ordered, serial,
/// sticky-failure. No models involved.
@MainActor
final class OverlapSessionTests: XCTestCase {
    func testSegmentsCollectInOrderEvenWhenLaterOnesFinishFirst() async {
        let session = OverlapSession()
        session.arm()
        session.enqueue { try? await Task.sleep(nanoseconds: 60_000_000); return "one" }
        session.enqueue { "two" }
        session.enqueue { "three" }
        let texts = await session.collect()
        XCTAssertEqual(texts, ["one", "two", "three"])
    }

    func testWorkersRunSeriallyNotConcurrently() async {
        // Foundation Models serializes anyway (lever 1) — the session must not
        // pretend otherwise: each worker starts after the previous finishes.
        let session = OverlapSession()
        session.arm()
        let log = Log2()
        session.enqueue { await log.note("a-start"); try? await Task.sleep(nanoseconds: 50_000_000); await log.note("a-end"); return "a" }
        session.enqueue { await log.note("b-start"); return "b" }
        _ = await session.collect()
        let events = await log.events
        XCTAssertEqual(events, ["a-start", "a-end", "b-start"], "b must not start before a ends")
    }

    func testAnyFailureMakesTheWholePressFallBack() async {
        let session = OverlapSession()
        session.arm()
        session.enqueue { "fine" }
        session.enqueue { nil }
        session.enqueue { "also fine" }
        let texts = await session.collect()
        XCTAssertNil(texts, "one failed segment must surface as a full fallback, never a hole in the text")
    }

    func testEnqueueIsIgnoredWhenNotArmed() async {
        let session = OverlapSession()
        session.enqueue { "late" }
        XCTAssertEqual(session.segmentCount, 0)
        session.arm(); session.disarm()
        session.enqueue { "after disarm" }
        XCTAssertEqual(session.segmentCount, 0)
    }

    func testResetDropsEverything() async {
        let session = OverlapSession()
        session.arm()
        session.enqueue { "x" }
        session.reset()
        XCTAssertEqual(session.segmentCount, 0)
        XCTAssertFalse(session.isArmed)
    }
}

private actor Log2 {
    var events: [String] = []
    func note(_ e: String) { events.append(e) }
}
