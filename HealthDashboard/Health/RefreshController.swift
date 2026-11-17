import Foundation
import Observation
import os

// App-target only. Owns the state of one "refresh from HealthKit" at a time and guarantees it can
// not hang: the fetch is raced against a timeout, and a fetch that finishes after it was timed out
// or superseded is dropped before it can write anything.

enum RefreshTuning {
    /// How long one refresh (authorization + 28-day fetch) may run before it is abandoned.
    static let refreshTimeoutSeconds: TimeInterval = 45
}

enum RefreshError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "Refresh timed out after \(Int(RefreshTuning.refreshTimeoutSeconds)) s — tap to retry."
    }
}

@MainActor
@Observable
final class RefreshController {

    enum Outcome: Equatable {
        case applied
        case skippedAlreadyRefreshing
        case failed
        case timedOut
        case superseded
    }

    private(set) var isRefreshing = false
    private(set) var errorText: String?
    /// Status line beside "As of": why a tap did nothing, or when the data was last confirmed current.
    private(set) var refreshNote: String?

    private let timeoutSeconds: TimeInterval
    private let abandonInFlight: @MainActor () -> Void
    private var generation = 0

    /// - Parameter abandonInFlight: called on timeout so the shared HealthKit fetch is dropped and the
    ///   next refresh starts a new one instead of rejoining the hung one.
    init(timeoutSeconds: TimeInterval = RefreshTuning.refreshTimeoutSeconds,
         abandonInFlight: @escaping @MainActor () -> Void = {}) {
        self.timeoutSeconds = timeoutSeconds
        self.abandonInFlight = abandonInFlight
    }

    /// Invalidates the run in flight: its result will be dropped when (if) it arrives.
    func supersedeCurrentRun() {
        generation += 1
        isRefreshing = false
    }

    /// Runs one refresh. `apply` is the only place results are written (history, snapshot, readiness,
    /// widget, Watch); it is called at most once, and only if this run is still current.
    @discardableResult
    func run(
        source: RefreshSource,
        probe: RefreshProbe? = nil,
        now: Date = Date(),
        fetch: @escaping @MainActor @Sendable () async throws -> [DailyHealthPoint],
        apply: @MainActor ([DailyHealthPoint]) -> Void
    ) async -> Outcome {
        guard !isRefreshing else {
            if source == .userTap { refreshNote = "Already refreshing…" }
            return .skippedAlreadyRefreshing
        }
        isRefreshing = true
        errorText = nil
        refreshNote = nil
        generation += 1
        let myGeneration = generation

        let timeout = timeoutSeconds
        #if DEBUG
        let clock = ContinuousClock()
        let started = clock.now
        #endif
        let result: Result<[DailyHealthPoint], Error> = await withCheckedContinuation { cont in
            let once = OSAllocatedUnfairLock(initialState: false)
            // True for exactly the first caller; the loser's result is discarded.
            @Sendable func claim() -> Bool {
                once.withLock { done in
                    if done { return false }
                    done = true
                    return true
                }
            }
            // Unstructured on purpose: a structured group would wait for a hung fetch to finish.
            let fetchTask = Task { @MainActor in
                do {
                    let points = try await fetch()
                    if claim() { cont.resume(returning: .success(points)) }
                } catch {
                    if claim() { cont.resume(returning: .failure(error)) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if claim() {
                    fetchTask.cancel()
                    cont.resume(returning: .failure(RefreshError.timedOut))
                }
            }
        }

        // A newer run (or an explicit supersede) owns the state now.
        #if DEBUG
        // Wall-clock from authorization + fetch start to completion, before apply runs.
        let outcomeName: String = {
            switch result {
            case .success: return "success"
            case .failure(let e): if case RefreshError.timedOut = e { return "timeout" } else { return "error" }
            }
        }()
        RefreshDurationLog.record(RefreshDurationEntry(
            date: now,
            ms: RefreshDurationLog.milliseconds(started.duration(to: clock.now)),
            outcome: outcomeName,
            source: source.rawValue,
            joined: probe?.joined ?? false
        ))
        #endif

        // supersedeCurrentRun() already released isRefreshing, so a newer run's flag is not touched here.
        guard myGeneration == generation else { return .superseded }

        switch result {
        case .success(let points):
            apply(points)
            refreshNote = "Up to date · " + Self.timeString(now)
            isRefreshing = false
            return .applied
        case .failure(let error):
            let isTimeout: Bool = { if case RefreshError.timedOut = error { return true } else { return false } }()
            errorText = error.localizedDescription
            if isTimeout {
                generation += 1          // anything the abandoned fetch still produces is an orphan
                abandonInFlight()
            }
            isRefreshing = false
            return isTimeout ? .timedOut : .failed
        }
    }

    private static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm"
        return f.string(from: date)
    }
}
