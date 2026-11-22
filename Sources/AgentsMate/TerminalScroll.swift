import AppKit

/// Turns scroll wheel and trackpad events into whole scroll steps.
///
/// A trackpad sends many small, precise deltas in points, then a tail of
/// momentum events after the fingers lift. Treating each event as one or
/// more lines makes the terminal fly past where the person meant to stop.
/// Here precise deltas are summed and a step is given for each row height
/// of travel, so the text follows the fingers, and momentum counts for less.
/// A mouse wheel's deltas are already in lines: about one step a notch, up
/// to a few when the system accelerates a fast spin.
public struct ScrollStepAccumulator: Sendable, Equatable {
    /// One scroll event, in the terms the accumulator needs.
    public struct Input: Sendable, Equatable {
        /// Positive scrolls toward older text, as `scrollingDeltaY` does.
        public var delta: CGFloat
        /// A trackpad or Magic Mouse (`hasPreciseScrollingDeltas`): the
        /// delta is in points, not lines.
        public var isPrecise: Bool
        /// The fingers have just touched down, starting a new gesture.
        public var beginsGesture: Bool
        /// The event is part of the glide after the fingers lifted.
        public var isMomentum: Bool

        public init(delta: CGFloat, isPrecise: Bool, beginsGesture: Bool = false, isMomentum: Bool = false) {
            self.delta = delta
            self.isPrecise = isPrecise
            self.beginsGesture = beginsGesture
            self.isMomentum = isMomentum
        }

        public init(_ event: NSEvent, delta: CGFloat? = nil) {
            self.init(delta: delta ?? event.scrollingDeltaY,
                      isPrecise: event.hasPreciseScrollingDeltas,
                      beginsGesture: event.phase.contains(.began) || event.phase.contains(.mayBegin),
                      isMomentum: !event.momentumPhase.isEmpty)
        }
    }

    /// Scales every delta; 1 is a step per row height of trackpad travel
    /// and a step per wheel notch.
    public var sensitivity: CGFloat
    /// How much of each momentum event counts, from 0 (momentum dropped)
    /// to 1 (counted in full).
    public var momentumFactor: CGFloat
    /// The most steps one trackpad event can give, so a hard flick does not
    /// skip a screenful at once.
    public var maxPreciseSteps: Int
    /// The most steps one wheel event can give.
    public var maxWheelSteps: Int

    /// Travel not yet given out as a step, in rows (precise) or lines.
    public private(set) var remainder: CGFloat = 0

    public init(sensitivity: CGFloat = 1, momentumFactor: CGFloat = 0.5,
                maxPreciseSteps: Int = 6, maxWheelSteps: Int = 3) {
        self.sensitivity = sensitivity
        self.momentumFactor = momentumFactor
        self.maxPreciseSteps = maxPreciseSteps
        self.maxWheelSteps = maxWheelSteps
    }

    /// The steps `input` adds: positive toward older text, negative toward
    /// newer, zero while travel is still building up. `rowHeight` is the
    /// height of one terminal row in points.
    public mutating func steps(for input: Input, rowHeight: CGFloat) -> Int {
        if input.beginsGesture { remainder = 0 }
        guard input.delta != 0, input.delta.isFinite, sensitivity > 0 else { return 0 }
        var travel = input.delta * sensitivity
        if input.isPrecise {
            travel /= max(rowHeight, 1)
            if input.isMomentum { travel *= max(0, min(1, momentumFactor)) }
        }
        // Turning back starts afresh rather than first undoing travel the
        // other way.
        if remainder != 0, (remainder > 0) != (travel > 0) { remainder = 0 }
        remainder += travel
        let limit = input.isPrecise ? maxPreciseSteps : maxWheelSteps
        let whole = Int(remainder.rounded(.towardZero))
        guard whole != 0 else { return 0 }
        let steps = max(-limit, min(limit, whole))
        // Travel past the limit is dropped, not saved up for later events.
        remainder = steps == whole ? remainder - CGFloat(whole) : 0
        return steps
    }

    /// Forget travel not yet given out.
    public mutating func reset() { remainder = 0 }
}
