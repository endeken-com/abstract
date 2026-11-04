import Foundation
import os

/// Signposted intervals around what the main thread does when you navigate,
/// send or open a chat (ABS-184), for Instruments' Points of Interest. Debug
/// builds also watch for stalls (see `HangMonitor`), as does any build run
/// with `ABSTRACT_HANG_MONITOR=1`.
enum Perf {
    nonisolated static let signposter = OSSignposter(subsystem: "sh.abstract.app", category: .pointsOfInterest)

    /// Runs `body` as an interval named `name`.
    @discardableResult
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = HangMonitor.shared.isRunning ? ContinuousClock.now : nil
        defer { if let start { HangMonitor.shared.record(name, since: start) } }
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    /// An interval begun here and ended with `end`, for work that doesn't fit a closure.
    struct Interval {
        let name: StaticString
        let state: OSSignpostIntervalState
        let start: ContinuousClock.Instant
    }

    static func begin(_ name: StaticString) -> Interval {
        Interval(name: name, state: signposter.beginInterval(name), start: .now)
    }

    static func end(_ interval: Interval) {
        signposter.endInterval(interval.name, interval.state)
        if HangMonitor.shared.isRunning { HangMonitor.shared.record(interval.name, since: interval.start) }
    }

    /// A view's body built, or anything else worth counting, as a point.
    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
        if HangMonitor.shared.isRunning { HangMonitor.shared.count(name) }
    }
}

/// Logs every stretch of over 100 ms the main thread spends without going
/// back to waiting for events, with the signposted intervals that ran in it,
/// longest first. A run loop observer marks when the thread wakes and when it
/// is about to sleep again, after the window has drawn.
final class HangMonitor {
    static let shared = HangMonitor()
    static let threshold: Duration = .milliseconds(100)
    private static let logger = Logger(subsystem: "sh.abstract.app", category: "hangs")

    /// One stretch of work between two waits.
    struct Busy {
        let start: ContinuousClock.Instant
        let end: ContinuousClock.Instant
        /// The main thread's own time on the processor in it: the stretch as
        /// it would be on a machine with nothing else running.
        let cpu: Duration
        /// Time spent in each interval in it, and how many times each ran or was counted.
        let intervals: [String: (time: Duration, count: Int)]
        var duration: Duration { end - start }
    }

    /// On in debug builds, and in any build run with `ABSTRACT_HANG_MONITOR=1`.
    static var wanted: Bool {
        #if DEBUG
        return true
        #else
        return ProcessInfo.processInfo.environment["ABSTRACT_HANG_MONITOR"] == "1"
        #endif
    }

    private var observers: [CFRunLoopObserver] = []
    var isRunning: Bool { !observers.isEmpty }
    private var wokeAt: ContinuousClock.Instant?
    private var wokeCPU: UInt64 = 0
    private var intervals: [String: (time: Duration, count: Int)] = [:]
    /// The latest stretches, newest last, for the demo's timing probe.
    private(set) var recent: [Busy] = []

    func start() {
        guard observers.isEmpty else { return }
        let woke = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { _, _ in
            MainActor.assumeIsolated { HangMonitor.shared.wake() }
        }
        // After AppKit's display cycle and Core Animation's commit, so a
        // stretch includes drawing what changed.
        let sleeps = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            MainActor.assumeIsolated { HangMonitor.shared.sleep() }
        }
        for observer in [woke, sleeps].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    func record(_ name: StaticString, since start: ContinuousClock.Instant) {
        let key = "\(name)"
        let entry = intervals[key] ?? (.zero, 0)
        intervals[key] = (entry.time + (ContinuousClock.now - start), entry.count + 1)
    }

    func count(_ name: StaticString) {
        let key = "\(name)"
        let entry = intervals[key] ?? (.zero, 0)
        intervals[key] = (entry.time, entry.count + 1)
    }

    private func wake() {
        wokeAt = .now
        wokeCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    private func sleep() {
        let end = ContinuousClock.now
        // Work before the first wake (launch) counts from then.
        let start = wokeAt ?? end
        let cpu = wokeAt == nil ? .zero : Duration.nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - wokeCPU))
        wokeAt = nil
        let busy = Busy(start: start, end: end, cpu: cpu, intervals: intervals)
        intervals = [:]
        recent.append(busy)
        if recent.count > 400 { recent.removeFirst(recent.count - 400) }
        guard busy.duration > Self.threshold else { return }
        let message = "main thread busy \(Self.ms(busy.duration)) ms (\(Self.ms(busy.cpu)) ms on the processor): \(Self.describe(busy.intervals))"
        Self.logger.warning("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("hang: \(message)\n".utf8))
    }

    static func describe(_ intervals: [String: (time: Duration, count: Int)]) -> String {
        guard !intervals.isEmpty else { return "no signposted work" }
        return intervals.sorted { ($0.value.time, $0.value.count) > ($1.value.time, $1.value.count) }
            .map { name, entry in entry.time > .zero ? "\(name) \(ms(entry.time)) ms ×\(entry.count)" : "\(name) ×\(entry.count)" }
            .joined(separator: ", ")
    }

    static func ms(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.1f", value)
    }
}
