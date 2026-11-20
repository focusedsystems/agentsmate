import AppKit
import Combine

/// Whether background work should slow down: the app is not active, Low
/// Power Mode is on, or the Mac is running hot. Every periodic timer in the
/// package reads it through ``CadenceTimer``, so the rule lives in one place.
@MainActor
final class BackgroundCadence: ObservableObject {
    static let shared = BackgroundCadence(observesSystem: true)

    /// How much longer intervals get while backed off.
    static let backoffFactor: Double = 4

    @Published private(set) var isBackedOff = false

    private(set) var appActive = true
    private(set) var lowPower = false
    private(set) var thermal: ProcessInfo.ThermalState = .nominal
    private var observers: [NSObjectProtocol] = []

    /// A cadence that only changes through ``update(appActive:lowPower:thermal:)``,
    /// for tests.
    convenience init() { self.init(observesSystem: false) }

    private init(observesSystem: Bool) {
        guard observesSystem else { return }
        let info = ProcessInfo.processInfo
        appActive = NSApp?.isActive ?? true
        lowPower = info.isLowPowerModeEnabled
        thermal = info.thermalState
        isBackedOff = Self.backsOff(appActive: appActive, lowPower: lowPower, thermal: thermal)
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            .NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification,
        ]
        for name in names {
            // Power and thermal notices arrive on any thread; read state on main.
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let becameActive = note.name == NSApplication.didBecomeActiveNotification
                let resigned = note.name == NSApplication.didResignActiveNotification
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let active = becameActive ? true : resigned ? false : (NSApp?.isActive ?? self.appActive)
                    self.update(appActive: active, lowPower: info.isLowPowerModeEnabled, thermal: info.thermalState)
                }
            })
        }
    }

    func update(appActive: Bool, lowPower: Bool, thermal: ProcessInfo.ThermalState) {
        self.appActive = appActive
        self.lowPower = lowPower
        self.thermal = thermal
        let backedOff = Self.backsOff(appActive: appActive, lowPower: lowPower, thermal: thermal)
        if backedOff != isBackedOff { isBackedOff = backedOff }
    }

    nonisolated static func backsOff(appActive: Bool, lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Bool {
        !appActive || lowPower || thermal == .serious || thermal == .critical
    }
}

/// A repeating main-run-loop timer that follows ``BackgroundCadence``: its
/// interval stretches while the app is backed off, it fires once to catch up
/// when the back-off ends if a tick is overdue, and it always has a tolerance
/// so the system can batch its wake-ups with others.
@MainActor
final class CadenceTimer {
    /// The fraction of the interval the system may delay a tick by.
    static let toleranceFraction = 0.2

    /// The interval while the app is in use.
    private(set) var interval: TimeInterval
    private let cadence: BackgroundCadence
    private let action: () -> Void
    private var timer: Timer?
    private var subscription: AnyCancellable?
    private(set) var lastFired: Date
    /// Kept from the cadence's announcements, which arrive before its
    /// property changes.
    private var backedOff: Bool

    /// Starts at once; the first tick is one interval away. Pass `fireNow` to
    /// also run `action` right away.
    init(interval: TimeInterval, cadence: BackgroundCadence = .shared, fireNow: Bool = false,
         action: @escaping () -> Void) {
        self.interval = interval
        self.cadence = cadence
        self.action = action
        self.lastFired = Date()
        self.backedOff = cadence.isBackedOff
        subscription = cadence.$isBackedOff.dropFirst().removeDuplicates().sink { [weak self] backedOff in
            MainActor.assumeIsolated { self?.cadenceChanged(backedOff: backedOff) }
        }
        schedule(after: currentInterval)
        if fireNow { fire() }
    }

    /// The interval in effect now, after any back-off.
    var currentInterval: TimeInterval { backedOff ? interval * BackgroundCadence.backoffFactor : interval }

    var isValid: Bool { timer != nil }

    /// How late the system may run a tick, to batch it with other wake-ups.
    var tolerance: TimeInterval { timer?.tolerance ?? 0 }

    /// Change the base interval; the next tick moves to match.
    func setInterval(_ new: TimeInterval) {
        guard new != interval else { return }
        interval = new
        let elapsed = Date().timeIntervalSince(lastFired)
        schedule(after: max(currentInterval - elapsed, 0.5))
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
        subscription = nil
    }

    /// Run the action now and start the next interval from here.
    func fire() {
        lastFired = Date()
        action()
        if timer != nil { schedule(after: currentInterval) }
    }

    private func cadenceChanged(backedOff: Bool) {
        self.backedOff = backedOff
        guard timer != nil else { return }
        let elapsed = Date().timeIntervalSince(lastFired)
        if !backedOff, Self.isOverdue(elapsed: elapsed, interval: interval) {
            fire()
        } else {
            schedule(after: max(currentInterval - elapsed, 0.5))
        }
    }

    /// Whether a catch-up tick is due when a back-off ends.
    nonisolated static func isOverdue(elapsed: TimeInterval, interval: TimeInterval) -> Bool {
        elapsed >= interval
    }

    private func schedule(after delay: TimeInterval) {
        timer?.invalidate()
        let first = Timer(fire: Date().addingTimeInterval(delay), interval: currentInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastFired = Date()
                self.action()
            }
        }
        first.tolerance = currentInterval * Self.toleranceFraction
        RunLoop.main.add(first, forMode: .common)
        timer = first
    }
}
