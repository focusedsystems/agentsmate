import XCTest
@testable import AgentsMate

final class ScrollStepAccumulatorTests: XCTestCase {
    private let row: CGFloat = 16

    private func total(_ deltas: [CGFloat], precise: Bool = true, momentum: Bool = false,
                       into accumulator: inout ScrollStepAccumulator) -> Int {
        deltas.reduce(0) {
            $0 + accumulator.steps(for: .init(delta: $1, isPrecise: precise, isMomentum: momentum), rowHeight: row)
        }
    }

    func testTrackpadGivesAStepPerRowOfTravel() {
        var accumulator = ScrollStepAccumulator()
        // 160 points of travel in small events is ten rows, not one or more
        // lines for every event.
        XCTAssertEqual(total(Array(repeating: 4, count: 40), into: &accumulator), 10)
        XCTAssertEqual(total(Array(repeating: -4, count: 40), into: &accumulator), -10)
    }

    func testSmallTravelBuildsUpBeforeAStep() {
        var accumulator = ScrollStepAccumulator()
        XCTAssertEqual(accumulator.steps(for: .init(delta: 10, isPrecise: true), rowHeight: row), 0)
        XCTAssertEqual(accumulator.steps(for: .init(delta: 10, isPrecise: true), rowHeight: row), 1)
        XCTAssertEqual(accumulator.remainder, 0.25, accuracy: 0.0001)
    }

    func testTurningBackDropsTheOtherWaysTravel() {
        var accumulator = ScrollStepAccumulator()
        XCTAssertEqual(accumulator.steps(for: .init(delta: 12, isPrecise: true), rowHeight: row), 0)
        XCTAssertEqual(accumulator.steps(for: .init(delta: -16, isPrecise: true), rowHeight: row), -1)
    }

    func testANewGestureStartsAfresh() {
        var accumulator = ScrollStepAccumulator()
        _ = accumulator.steps(for: .init(delta: 12, isPrecise: true), rowHeight: row)
        XCTAssertEqual(accumulator.steps(for: .init(delta: 8, isPrecise: true, beginsGesture: true), rowHeight: row), 0)
    }

    func testMomentumCountsForLess() {
        var accumulator = ScrollStepAccumulator()
        XCTAssertEqual(total(Array(repeating: 8, count: 20), momentum: true, into: &accumulator), 5)
        var dropped = ScrollStepAccumulator(momentumFactor: 0)
        XCTAssertEqual(total(Array(repeating: 8, count: 20), momentum: true, into: &dropped), 0)
    }

    func testAHardFlickIsCapped() {
        var accumulator = ScrollStepAccumulator()
        XCTAssertEqual(accumulator.steps(for: .init(delta: 400, isPrecise: true), rowHeight: row), 6)
        XCTAssertEqual(accumulator.remainder, 0, "travel past the cap is not saved up")
    }

    func testWheelNotchesGiveOneToThreeSteps() {
        var accumulator = ScrollStepAccumulator()
        XCTAssertEqual(accumulator.steps(for: .init(delta: 1, isPrecise: false), rowHeight: row), 1)
        XCTAssertEqual(accumulator.steps(for: .init(delta: -1, isPrecise: false), rowHeight: row), -1)
        XCTAssertEqual(accumulator.steps(for: .init(delta: 9, isPrecise: false), rowHeight: row), 3)
        // A smooth-scrolling mouse's fractions add up to a step.
        XCTAssertEqual(total([0.4, 0.4, 0.4], precise: false, into: &accumulator), 1)
    }

    func testSensitivityScalesTravel() {
        var slow = ScrollStepAccumulator(sensitivity: 0.5)
        XCTAssertEqual(total(Array(repeating: 4, count: 40), into: &slow), 5)
        var fast = ScrollStepAccumulator(sensitivity: 2)
        XCTAssertEqual(total(Array(repeating: 4, count: 40), into: &fast), 20)
    }

    func testNoTravelNoSteps() {
        var accumulator = ScrollStepAccumulator()
        XCTAssertEqual(accumulator.steps(for: .init(delta: 0, isPrecise: true), rowHeight: row), 0)
        XCTAssertEqual(accumulator.steps(for: .init(delta: .nan, isPrecise: true), rowHeight: row), 0)
    }
}
