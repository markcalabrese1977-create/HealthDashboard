import Foundation

// App-target only. Policy for ContentView's live evaluations: when to persist the verdict log, and
// when an evaluation is display-only.
//
// ReadinessEngine.evaluate() upserts the verdict log into the slot for the WALL-CLOCK day (the slot
// key is Date(), see ReadinessEngine), whatever day the evaluated history ends on. On the first open
// of a new day the stored history still ends YESTERDAY until a HealthKit fetch lands, so an
// evaluation of it would write yesterday's verdict into today's slot. `evaluateForLive` keeps that
// evaluation (the card still renders it) but stops it persisting.
enum LiveEvaluationPolicy {

    /// Today's ISO day, built EXACTLY as ReadinessEngine builds its verdict-log slot key: the current
    /// calendar and time zone (`Calendar.current`), year/month/day components, `%04d-%02d-%02d`.
    static func todayISO(now: Date = Date()) -> String {
        let c = Calendar.current
        let comps = c.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d",
                      comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    /// True when the evaluated history does not end today. nil (empty history) counts as "not today".
    static func shouldSuppressPersistence(historyLastDayISO: String?, todayISO: String) -> Bool {
        historyLastDayISO != todayISO
    }

    /// The live `onAppear` evaluation. Identical to a plain `ReadinessEngine.evaluate` (which
    /// persists) unless the history ends before today, in which case persistence is suppressed.
    static func evaluateForLive(
        history: [DailyHealthPoint],
        manual: ManualReadinessInputs,
        now: Date = Date()
    ) -> ReadinessResult {
        if shouldSuppressPersistence(historyLastDayISO: history.last?.dayISO, todayISO: todayISO(now: now)) {
            return VerdictPersistence.withSuppressedPersistence {
                ReadinessEngine.evaluate(history: history, manual: manual)
            }
        }
        return ReadinessEngine.evaluate(history: history, manual: manual)
    }

    /// True when the store holds a strictly newer snapshot than the one the view last rendered: a
    /// background delivery (hkObserver) saved newer data while the view was on screen. nil previous
    /// with a non-nil current also counts; a nil current never does.
    static func needsReevaluation(previousUpdatedAt: Date?, currentUpdatedAt: Date?) -> Bool {
        guard let current = currentUpdatedAt else { return false }
        guard let previous = previousUpdatedAt else { return true }
        return current > previous
    }

    /// Re-evaluation for DISPLAY ONLY: always suppresses verdict-log persistence. The writer of record
    /// for this data (hkObserver / postBackfill) already persisted its own verdict; the card just needs
    /// to show a result consistent with the history it now holds.
    static func evaluateForDisplay(
        history: [DailyHealthPoint],
        manual: ManualReadinessInputs
    ) -> ReadinessResult {
        VerdictPersistence.withSuppressedPersistence {
            ReadinessEngine.evaluate(history: history, manual: manual)
        }
    }
}
