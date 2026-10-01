import Foundation

// App-target only (deliberately NOT compiled into the Watch or widget targets, which do not
// include ReadinessPresentation.swift). Builds the post-evaluate VerdictResultEntry from a
// finished ReadinessResult and hands it to VerdictWriteTrace.recordResult. Strictly
// observational: it reads the result and the manual inputs, scores nothing, and the result is
// returned to the call site unchanged.

extension VerdictWriteTrace {

    /// Overload of `withContext` for the live sites: binds the same task-local context, runs the
    /// existing evaluate() call as-is, then records the result entry. `manual` is the same value
    /// the call site passes to evaluate(); the presentation's message-state resolver needs it
    /// (sick / high-pain take precedence over the verdict-derived states).
    static func withContext(
        site: String,
        history: [DailyHealthPoint],
        manual: ManualReadinessInputs,
        _ body: () throws -> ReadinessResult
    ) rethrows -> ReadinessResult {
        let result = try withContext(site: site, history: history, body)

        if verdictTraceEnabled, resultTraceSites.contains(site) {
            recordResult(
                makeResultEntry(result: result, site: site, history: history, manual: manual)
            )
        }
        return result
    }

    /// Pure: no I/O. Split out so tests can exercise it.
    static func makeResultEntry(
        result: ReadinessResult,
        site: String,
        history: [DailyHealthPoint],
        manual: ManualReadinessInputs,
        at writtenAt: Date = Date()
    ) -> VerdictResultEntry {
        let last = history.last

        // driverDisplays maps result.drivers 1:1, in order (ReadinessPresentation.driverDisplays),
        // so the rendered sentiment lines up by index.
        let displays = result.driverDisplays(manual: manual)
        let drivers: [VerdictResultDriver] = result.drivers.enumerated().map { i, d in
            VerdictResultDriver(
                label: d.label,
                isNegative: d.isNegative,
                sentiment: i < displays.count ? String(describing: displays[i].sentiment) : nil
            )
        }

        let hrvFallback: Bool? = {
            guard let last, last.hrvMS != nil else { return nil }
            return last.sleepWindowHRV == nil
        }()

        return VerdictResultEntry(
            writtenAt: writtenAt,
            site: site,
            evalDayISO: last?.dayISO ?? resultNoEvalDay,
            action: result.action,
            rawRecoveryTruth: result.rawRecoveryTruth,
            confidence: result.confidence,
            messageState: String(describing: result.resolveMessageState(manual: manual)),
            // Left nil on purpose: the negative-driver count lives inline in
            // resolveMessageState / presentation (`drivers.filter { $0.isNegative }`), with no
            // helper to reuse. `drivers` above carries isNegative per row.
            negativeDriverCount: nil,
            drivers: drivers,
            hrvFallback: hrvFallback,
            sleepWindowEnd: last?.sleepWindowEnd
        )
    }
}
