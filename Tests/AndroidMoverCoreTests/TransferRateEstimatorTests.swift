import XCTest
@testable import AndroidMoverCore

final class TransferRateEstimatorTests: XCTestCase {
    func testNilUntilEnoughSamples() {
        var e = TransferRateEstimator()
        e.record(bytesDone: 0, bytesTotal: 1_000, at: 0)
        XCTAssertNil(e.bytesPerSecond)
        XCTAssertNil(e.estimatedSecondsRemaining)
    }

    func testSteadyRateAndETA() throws {
        var e = TransferRateEstimator()
        // 10 МБ/с рівно: кожну секунду +10 МБ, обсяг 100 МБ.
        for s in 0...5 {
            e.record(bytesDone: Int64(s) * 10_000_000, bytesTotal: 100_000_000, at: TimeInterval(s))
        }
        let rate = try XCTUnwrap(e.bytesPerSecond)
        XCTAssertEqual(rate, 10_000_000, accuracy: 1)
        let eta = try XCTUnwrap(e.estimatedSecondsRemaining)
        XCTAssertEqual(eta, 5, accuracy: 0.01) // лишилось 50 МБ при 10 МБ/с
    }

    func testWindowFollowsSlowdown() throws {
        var e = TransferRateEstimator()
        e.windowSeconds = 4
        for s in 0...4 { e.record(bytesDone: Int64(s) * 10_000_000, bytesTotal: 1_000_000_000, at: TimeInterval(s)) }
        let fast = try XCTUnwrap(e.bytesPerSecond)
        // Далі — 1 МБ/с протягом 10 с: швидкість мусить впасти щонайменше вдвічі.
        var done: Int64 = 40_000_000
        for s in 5...15 { done += 1_000_000; e.record(bytesDone: done, bytesTotal: 1_000_000_000, at: TimeInterval(s)) }
        let slow = try XCTUnwrap(e.bytesPerSecond)
        XCTAssertLessThan(slow, fast / 2)
    }

    func testNonMonotonicProgressResetsInsteadOfNegativeRate() throws {
        var e = TransferRateEstimator()
        for s in 0...3 { e.record(bytesDone: Int64(s) * 5_000_000, bytesTotal: 50_000_000, at: TimeInterval(s)) }
        XCTAssertNotNil(e.bytesPerSecond)
        // Докачка після обриву: bytesDone впав.
        e.record(bytesDone: 2_000_000, bytesTotal: 50_000_000, at: 4)
        XCTAssertNil(e.bytesPerSecond, "після скидання вікна швидкість невідома, а не від'ємна")
        e.record(bytesDone: 4_000_000, bytesTotal: 50_000_000, at: 5)
        XCTAssertEqual(try XCTUnwrap(e.bytesPerSecond), 2_000_000, accuracy: 1)
    }

    func testStallGivesNoETAWhenRateZero() {
        var e = TransferRateEstimator()
        e.record(bytesDone: 1_000, bytesTotal: 10_000, at: 0)
        e.record(bytesDone: 1_000, bytesTotal: 10_000, at: 1)
        XCTAssertNil(e.bytesPerSecond)
        XCTAssertNil(e.estimatedSecondsRemaining)
    }
}
