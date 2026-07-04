import Foundation
import HealthKit

// SleepStage / SleepSegment are defined in SharedHealthSnapshot.swift (relocated in
// Phase 2 so they thread through the shared scoring path, not this file).

final class HealthKitManager {
    static let shared = HealthKitManager()
    private let store = HKHealthStore()
    private init() {}

    // Most-recent night's RAW sleep segments from the last fetch. Held in memory only and
    // handed to SleepQualityEngine transiently — deliberately NOT persisted onto
    // DailyHealthPoint / SharedStore (would bloat every WatchPayload push).
    private(set) var lastNightSegments: [SleepSegment] = []

    // Confirmed personal max HR — PINNED for TRIMP's HRr denominator. Previously estimated
    // as max(observedPeakHR/0.85, 175), which drifted run-to-run (175→173→…) with whatever
    // peak HR happened to be in the window. Since TRIMP feeds load, and load is the CONTROL
    // in the sleep-composite partial correlation, a drifting denominator injects noise into
    // the composite's exoneration. Pinned to the confirmed value; retune here if it changes.
    private static let confirmedMaxHR: Double = 170.0

    // MARK: - Fetch coalescing
    //
    // fetchLast28Days() has more callers than ContentView's own isRefreshing guard
    // can see: HealthDashboardApp registers an HKObserverQuery per sample type
    // (5 types — HRV, RHR, SpO2, resp rate, sleep), and HealthKit invokes each
    // observer's update handler independently, each spawning its own
    // Task.detached that calls fetchLast28Days() — completely bypassing
    // ContentView's UI-level guard. Without coalescing here, up to 5 concurrent
    // 28-day HealthKit fetches can run at once on a single launch.
    //
    // Every caller ends up running fetchLast28Days()'s body on the MainActor (see
    // the comment there), which serializes the check-and-set below, so all
    // callers — regardless of which queue/Task they call from — either start the
    // one fetch or await the in-flight one's result.
    private var inFlightLast28DaysFetch: Task<[DailyHealthPoint], Error>?

        #if DEBUG
        private func debugDumpRestingHRSamples(dayStart: Date, dayEnd: Date) {
            guard let type = HKObjectType.quantityType(forIdentifier: .restingHeartRate) else { return }

            let predicate = HKQuery.predicateForSamples(withStart: dayStart, end: dayEnd, options: .strictStartDate)
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]

            let q = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: sort
            ) { _, samples, error in
                if let error {
                    print("❌ RHR sample dump error: \(error)")
                    return
                }

                let qs = (samples as? [HKQuantitySample]) ?? []
                
                print("🩺 RHR raw samples \(dayStart) → \(dayEnd) count=\(qs.count)")

                let bpmUnit = HKUnit.count().unitDivided(by: .minute())
                for s in qs {
                    let bpm = s.quantity.doubleValue(for: bpmUnit)
                    let bundle = s.sourceRevision.source.bundleIdentifier
                    let sourceName = s.sourceRevision.source.name
                    let device = s.device?.name ?? "nil"
                    print("🩺 \(String(format: "%.1f", bpm)) bpm  \(s.startDate) → \(s.endDate)  source=\(sourceName) (\(bundle)) device=\(device)")
                }
            }

            self.store.execute(q)
        }
        #endif
    
    // MARK: - Authorization

    private var typesToRead: Set<HKObjectType> {
        var set: Set<HKObjectType> = []

        // Physiology
        if let rhr = HKObjectType.quantityType(forIdentifier: .restingHeartRate) { set.insert(rhr) }
        if let hrv = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { set.insert(hrv) }
        if let rr = HKObjectType.quantityType(forIdentifier: .respiratoryRate) { set.insert(rr) }
        if let spo2 = HKObjectType.quantityType(forIdentifier: .oxygenSaturation) { set.insert(spo2) }

        // Wrist Temperature (sleeping; Apple Watch) — iOS 16+
        if #available(iOS 16.0, *) {
            if let wt = HKObjectType.quantityType(forIdentifier: .appleSleepingWristTemperature) { set.insert(wt) }
        }

        // Sleep
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { set.insert(sleep) }

        // Activity / load
        if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) { set.insert(steps) }
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { set.insert(energy) }
        if let exercise = HKObjectType.quantityType(forIdentifier: .appleExerciseTime) { set.insert(exercise) }
        if let stand = HKObjectType.quantityType(forIdentifier: .appleStandTime) { set.insert(stand) }

        // Workouts + workout heart rate + VO2 max
                set.insert(HKObjectType.workoutType())
                if let hr = HKObjectType.quantityType(forIdentifier: .heartRate) { set.insert(hr) }
        if let vo2 = HKObjectType.quantityType(forIdentifier: .vo2Max) { set.insert(vo2) }
                let mlTypeID = HKQuantityTypeIdentifier(rawValue: "com.calabrese.eliteperformance.mechanicalLoad")
                if let mlType = HKQuantityType.quantityType(forIdentifier: mlTypeID) { set.insert(mlType) }

        // Body comp (smart scale)
        if let bodyMass = HKObjectType.quantityType(forIdentifier: .bodyMass) { set.insert(bodyMass) }
        if let bodyFat = HKObjectType.quantityType(forIdentifier: .bodyFatPercentage) { set.insert(bodyFat) }
        if let leanMass = HKObjectType.quantityType(forIdentifier: .leanBodyMass) { set.insert(leanMass) }

        return set
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await store.requestAuthorization(toShare: [], read: typesToRead)
    }

    // MARK: - Public fetches

    /// Fetch last N days INCLUDING today. Oldest -> newest.
    func fetchLastNDays(_ days: Int) async throws -> [DailyHealthPoint] {
        // One-time reset: clears the 28-day history if it was built from a now-superseded
        // signal source (e.g. Apple's all-day RHR/HRV before the sleep-window cutover).
        SharedStore.performSignalCutoverIfNeeded()

        let t0 = Date()

        let cal = Calendar.current
        let now = Date()

        let clampedDays = max(1, min(days, 90)) // safety cap
        let start = cal.startOfDay(for: cal.date(byAdding: .day, value: -(clampedDays - 1), to: now)!)
        let end = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now)!)

        // RHR: Apple Watch only, most recent per day
                // fetchDailyAverage uses HKStatisticsCollectionQuery which averages all sources,
                // causing contamination when third-party apps (e.g. Athlytic) write their own RHR samples.
                async let rhrDict = fetchDailyMostRecentApple(
                    identifier: .restingHeartRate,
                    unit: HKUnit.count().unitDivided(by: .minute()),
                    start: start,
                    end: end
                )

        // Sleep-window RHR: comparison field, computed from raw HR during verified
        // asleep states. Parallel to rhrDict above — not used for scoring yet.
        //
        // Timing is threaded through as a return value rather than written to a
        // `self` property from inside this closure — async let spawns a child task
        // that does not inherit this class's (project-default) MainActor isolation,
        // so mutating an isolated stored property here would be a Swift 6 error.
        async let sleepWindowRHRTimed: ([String: Double], TimeInterval) = {
            let s = Date()
            let r = try await self.fetchSleepWindowRHR(start: start, end: end)
            return (r, Date().timeIntervalSince(s))
        }()

        // AFTER
        async let hrvSecondsDict = fetchOvernightHRV(start: start, end: end)

        // Sleep-window HRV: comparison field, computed from raw SDNN during verified
        // asleep states. Parallel to hrvSecondsDict above.
        async let sleepWindowHRVTimed: ([String: Double], TimeInterval) = {
            let s = Date()
            let r = try await self.fetchSleepWindowHRV(start: start, end: end)
            return (r, Date().timeIntervalSince(s))
        }()

        // Averages (sleep-window day; noon->noon)
        async let respRateDict = fetchOvernightPointInTimeAverage(
                    identifier: .respiratoryRate,
                    unit: HKUnit.count().unitDivided(by: .minute()),
                    start: start,
                    end: end
                )

        async let wristTempDict: [String: Double] = {
            if #available(iOS 16.0, *) {
                return try await fetchSleepWindowDailyAverage(
                    identifier: .appleSleepingWristTemperature,
                    unit: HKUnit.degreeCelsius(),
                    start: start,
                    end: end
                )
            } else {
                return [:]
            }
        }()

        // Oxygen saturation:
        // Some HealthKit pipelines return fraction (0–1) even when requesting percent.
        // We'll normalize at assignment time (<= 1.5 => *100).
        // AFTER
        async let spo2RawDict = fetchSleepWindowDailyAverage(
            identifier: .oxygenSaturation,
            unit: HKUnit.percent(),
            start: start,
            end: end
        )

        // Sums
        async let stepsDict = fetchDailySum(
            identifier: .stepCount,
            unit: HKUnit.count(),
            start: start,
            end: end
        )

        async let energyDict = fetchDailySum(
            identifier: .activeEnergyBurned,
            unit: HKUnit.kilocalorie(),
            start: start,
            end: end
        )

        async let exerciseMinDict = fetchDailySum(
            identifier: .appleExerciseTime,
            unit: HKUnit.minute(),
            start: start,
            end: end
        )

        async let standMinDict = fetchDailySum(
            identifier: .appleStandTime,
            unit: HKUnit.minute(),
            start: start,
            end: end
        )

        // Body comp (most recent per day)
        async let weightLbDict = fetchDailyMostRecent(
            identifier: .bodyMass,
            unit: .pound(),
            start: start,
            end: end
        )

        // Body fat percentage:
        // Normalize the same way (<= 1.5 => *100), because some sources also store fraction.
        async let bodyFatRawDict = fetchDailyMostRecent(
            identifier: .bodyFatPercentage,
            unit: .percent(),
            start: start,
            end: end
        )

        async let leanLbDict = fetchDailyMostRecent(
            identifier: .leanBodyMass,
            unit: .pound(),
            start: start,
            end: end
        )

        // Sleep (Apple Watch only, noon->noon)
        async let sleepDict = fetchDailySleepBreakdownApple(start: start, end: end)

        // Workouts
                async let workoutSummaryDict    = fetchDailyWorkouts(start: start, end: end)
                async let mechanicalLoadRawDict = fetchMechanicalLoad(start: start, end: end)

        let (
            rhr,
            sleepWindowRHRResult,
            hrvSeconds,
            sleepWindowHRVResult,
            respRate,
            wristTemp,
            spo2Raw,
            steps,
            energy,
            exerciseMin,
            standMin,
            sleepDictResolved,
            weightDict,
            bodyFatRaw,
            leanDict,
            workoutSummary,
                        mechanicalLoadDict
                    ) = try await (
                        rhrDict,
                        sleepWindowRHRTimed,
                        hrvSecondsDict,
                        sleepWindowHRVTimed,
                        respRateDict,
                        wristTempDict,
                        spo2RawDict,
                        stepsDict,
                        energyDict,
                        exerciseMinDict,
                        standMinDict,
                        sleepDict,
                        weightLbDict,
                        bodyFatRawDict,
                        leanLbDict,
                        workoutSummaryDict,
                        mechanicalLoadRawDict
                    )

        let sleepWindowRHR = sleepWindowRHRResult.0
        let sleepWindowHRV = sleepWindowHRVResult.0

        #if DEBUG
        let elapsed = Date().timeIntervalSince(t0)
        print("⏱ fetchLastNDays completed in \(String(format: "%.2f", elapsed))s")
        print("⏱ fetchSleepWindowRHR: \(String(format: "%.2f", sleepWindowRHRResult.1))s  fetchSleepWindowHRV: \(String(format: "%.2f", sleepWindowHRVResult.1))s")
        #endif

        func normalizePercent(_ v: Double?) -> Double? {
                    guard let v else { return nil }
                    return (v <= 1.5) ? (v * 100.0) : v
                }

                // MARK: - Compute daily TRIMP (Bannister)
                // TRIMP = Σ duration_min × HRr × 0.64 × e^(1.92 × HRr)
                // HRr = (avgHR − restHR) / (maxHR − restHR)

                var dailyTrimpDict: [String: Double] = [:]
                var dailyAvgHRDict: [String: Double] = [:]

                let allWorkouts = workoutSummary.values.flatMap { $0.workouts }

                // Fetch avg HR per workout concurrently
        struct WorkoutHREntry {
                            let avgHR: Double
                            let peakHR: Double
                        }
                        var workoutHRDict: [String: WorkoutHREntry] = [:]
                        await withTaskGroup(of: (String, WorkoutHREntry?).self) { group in
                            for w in allWorkouts {
                                group.addTask {
                                    guard let summary = try? await self.fetchWorkoutHR(for: w) else {
                                        return (w.uuid.uuidString, nil)
                                    }
                                    return (w.uuid.uuidString, WorkoutHREntry(avgHR: summary.avgHR, peakHR: summary.peakHR))
                                }
                            }
                            for await (uuid, entry) in group {
                                if let entry { workoutHRDict[uuid] = entry }
                            }
                        }

                        // maxHR is PINNED to the confirmed value — no longer derived from
                        // observedPeakHR/0.85 (that drifted the load-control each run).
                        // observedPeakHR is kept for the DEBUG comparison only.
        let observedPeakHR = workoutHRDict.values.map { $0.peakHR }.max() ?? 0
                        let estimatedMaxHR = Self.confirmedMaxHR

                for (dayISO, summary) in workoutSummary {
                    let restHR = rhr[dayISO] ?? 60.0
                    var dayTrimp = 0.0
                    var dayHRSum = 0.0
                    var dayHRCount = 0

                    for w in summary.workouts {
                                            guard let avgHR = workoutHRDict[w.uuid.uuidString]?.avgHR else { continue }
                        let durationMin = w.duration / 60.0
                        let hrr = max(0, min(1, (avgHR - restHR) / (estimatedMaxHR - restHR)))
                        let trimp = durationMin * hrr * 0.64 * exp(1.92 * hrr)
                        dayTrimp += trimp
                        dayHRSum += avgHR
                        dayHRCount += 1
                    }

                    if dayTrimp > 0 { dailyTrimpDict[dayISO] = dayTrimp }
                    if dayHRCount > 0 { dailyAvgHRDict[dayISO] = dayHRSum / Double(dayHRCount) }
                                    }

                                    #if DEBUG
        print("💪 estimatedMaxHR=\(String(format: "%.0f", estimatedMaxHR)) observedPeakHR=\(String(format: "%.0f", observedPeakHR))")
                        for (uuid, entry) in workoutHRDict.prefix(3) {
                            print("💪 sample uuid=\(uuid.prefix(8)) avgHR=\(String(format: "%.0f", entry.avgHR)) peakHR=\(String(format: "%.0f", entry.peakHR))")
                        }
                                    for day in dailyTrimpDict.keys.sorted() {
                                        print("💪 TRIMP[\(day)] score=\(String(format: "%.1f", dailyTrimpDict[day] ?? 0)) avgHR=\(String(format: "%.0f", dailyAvgHRDict[day] ?? 0))")
                                    }
                                    if dailyTrimpDict.isEmpty {
                                        print("💪 TRIMP: no workout HR data found — check authorization or workout HR samples")
                                    }
                                    #endif

                                    var points: [DailyHealthPoint] = []
        
        points.reserveCapacity(clampedDays)

        for dayOffset in 0..<clampedDays {
            let day = cal.date(byAdding: .day, value: dayOffset, to: start)!
            let dayISO = Self.isoDayString(day)

            let rhrValRaw = rhr[dayISO]
            let rhrVal: Double? = {
                guard let v = rhrValRaw else { return nil }
                if v < 35 || v > 110 { return nil }   // drop bad day-value at the source
                return v
            }()
            #if DEBUG
            if let v = rhrValRaw, (v < 35 || v > 110) {
                print("⚠️ Dropping implausible RHR avg \(String(format: "%.2f", v)) on \(dayISO)")
            }
            #endif
            // Comparison field — no plausibility gate applied yet, kept raw for sanity-checking
            // against Apple's restingHeartRate during the comparison period.
            let sleepWindowRHRVal = sleepWindowRHR[dayISO]

            // CUTOVER: sleep-window RHR is now the primary signal (Apple's restingHeartRate
            // blends daytime low-motion periods with true overnight resting state — confirmed
            // 11-17 bpm discrepancies vs sleep-window values over 4 consecutive nights).
            // Falls back to Apple's value only when sleep-window data is unavailable.
            let primaryRHR = sleepWindowRHRVal ?? rhrVal

            let appleHRVMS = hrvSeconds[dayISO].map { $0 * 1000.0 }

            // Comparison field — raw sleep-window-derived HRV, kept for sanity-checking
            // against Apple's heartRateVariabilitySDNN during the comparison period.
            let sleepWindowHRVVal = sleepWindowHRV[dayISO]

            // CUTOVER: sleep-window HRV is now the primary signal (Apple's SDNN is an
            // all-day average including awake readings, mixing daytime sympathetic activity
            // with overnight parasympathetic state). Falls back to Apple's value only when
            // sleep-window data is unavailable.
            let primaryHRV = sleepWindowHRVVal ?? appleHRVMS

            let rr = respRate[dayISO]
            let wristAbsC = wristTemp[dayISO]

            let spo2PctVal = normalizePercent(spo2Raw[dayISO])

            let stepsVal = steps[dayISO]
            let energyVal = energy[dayISO]
            let exerciseVal = exerciseMin[dayISO]
            let standHoursVal = standMin[dayISO].map { $0 / 60.0 }

            let sleepBreak = sleepDictResolved[dayISO]
            let sleepVal = sleepBreak?.asleepHours
            let inBedVal = sleepBreak?.inBedHours

            let w = workoutSummary[dayISO]
            let wCount = w?.count ?? 0
            let wMinutes = w?.minutes ?? 0
            let wEnergy = w?.energyKcal ?? 0

            let weightLb = weightDict[dayISO]
            let bodyFatPctVal = normalizePercent(bodyFatRaw[dayISO])
            let leanLb = leanDict[dayISO]

            points.append(
                DailyHealthPoint(
                    dayISO: dayISO,
                    restingHR: primaryRHR,
                    sleepWindowRHR: sleepWindowRHRVal,
                    appleRestingHR: rhrVal,
                    hrvMS: primaryHRV,
                    sleepWindowHRV: sleepWindowHRVVal,
                    sleepHours: sleepVal,
                    sleepInBedHours: inBedVal,
                    respiratoryRate: rr,
                    spo2Pct: spo2PctVal,
                    // Phase 5: persist per-stage minutes + window bounds (additive; previously
                    // always nil). Baseline-relative architecture/consistency now have real
                    // history. Raw segments are NOT persisted (Watch-payload size) — they ride
                    // the transient scoring path via lastNightSegments.
                    sleepDeepMinutes: sleepBreak?.deepMinutes,
                    sleepREMMinutes: sleepBreak?.remMinutes,
                    sleepCoreMinutes: sleepBreak?.coreMinutes,
                    sleepUnspecifiedMinutes: sleepBreak?.unspecifiedMinutes,
                    sleepAwakeMinutes: sleepBreak?.awakeMinutes,
                    sleepWindowStart: sleepBreak?.windowStart,
                    sleepWindowEnd: sleepBreak?.windowEnd,
                    sleepPeriodMinutes: sleepBreak?.sleepPeriodMinutes,
                    wristTempDeltaC: wristAbsC, // NOTE: absolute °C, naming legacy
                    steps: stepsVal,
                    activeEnergyKcal: energyVal,
                    exerciseMinutes: exerciseVal,
                    standHours: standHoursVal,
                    workoutCount: wCount,
                                        workoutMinutes: wMinutes,
                                        workoutEnergyKcal: wEnergy,
                                        workoutAvgHR: dailyAvgHRDict[dayISO],
                    dailyTrimp: dailyTrimpDict[dayISO],
                                        mechanicalLoad: mechanicalLoadDict[dayISO],
                                        bodyWeightLb: weightLb,
                    bodyFatPct: bodyFatPctVal,
                    leanMassLb: leanLb
                )
            )
        }

        // Backfill the composite series across the window (validation precondition).
        // Each day D is scored with an EXPANDING PRIOR-ONLY baseline (points[0...D], whose
        // evaluate() drops the last element for its baseline) and that day's own raw
        // segments — no lookahead leakage. Stamps sleepCompositeScore on the point and logs
        // per-axis sub-scores + the `matured` flag to the side store for diagnosis.
        var axisRecords: [SleepAxisLogRecord] = []
        for i in points.indices {
            let slice = Array(points[0...i])
            let daySegments = sleepDictResolved[points[i].dayISO]?.segments ?? []
            let sq = SleepQualityEngine.evaluate(history: slice, todaySegments: daySegments)

            if sq != .unavailable {
                points[i].sleepCompositeScore = sq.composite
            }
            axisRecords.append(
                SleepAxisLogRecord(
                    dateISO: points[i].dayISO,
                    composite: sq.composite,
                    matured: sq.matured,
                    availableAxes: sq.availableAxes,
                    subScores: sq.subScores
                )
            )
        }
        SharedStore.saveSleepAxisLog(axisRecords)

        #if DEBUG
        // Blocker-2 readout: composite(D) vs logged readiness(D+1) over matured days.
        print(SleepCompositeValidator.run().summary)
        #endif

        // Cache the newest night's raw segments for transient sleep-quality scoring.
        if let newestISO = points.map({ $0.dayISO }).max() {
            self.lastNightSegments = sleepDictResolved[newestISO]?.segments ?? []
        } else {
            self.lastNightSegments = []
        }

        return points
    }

    /// UI can still display 7; engine can use 28.
    func fetchLast7Days() async throws -> [DailyHealthPoint] {
        try await fetchLastNDays(7)
    }

    func fetchLast28Days() async throws -> [DailyHealthPoint] {
        // This class has no explicit isolation, so under the project's
        // SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor setting it's implicitly
        // @MainActor — every caller (ContentView, and HealthDashboardApp's
        // Task.detached observer handlers) hops onto the MainActor to run this
        // body, so the check-and-set of inFlightLast28DaysFetch below is already
        // serialized without a lock. (An explicit NSLock can't be used here
        // anyway — its lock()/unlock() are unavailable from async contexts under
        // Swift 6.) MainActor serialization is exactly what lets a caller that
        // arrives while a fetch is already in flight see it and join it instead
        // of starting a second concurrent HealthKit query.
        if let existing = inFlightLast28DaysFetch {
            #if DEBUG
            print("⏱ fetchLast28Days: joining in-flight fetch instead of starting a new one")
            #endif
            return try await existing.value
        }

        let task = Task { try await self.fetchLastNDays(28) }
        inFlightLast28DaysFetch = task

        defer { inFlightLast28DaysFetch = nil }

        return try await task.value
    }

    // MARK: - Daily Average (quantity, calendar-day)

    private func fetchDailyAverage(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async throws -> [String: Double] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [:] }

        let cal = Calendar.current
        let anchor = cal.startOfDay(for: start)
        var interval = DateComponents()
        interval.day = 1

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { cont in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage,
                anchorDate: anchor,
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, results, error in
                if let error = error {
                    cont.resume(throwing: error)
                    return
                }

                var out: [String: Double] = [:]
                results?.enumerateStatistics(from: start, to: end) { stats, _ in
                    let dayISO = Self.isoDayString(stats.startDate)
                    guard let avg = stats.averageQuantity()?.doubleValue(for: unit) else { return }

                    #if DEBUG
                    if identifier == .restingHeartRate, avg > 110 {
                        print("⚠️ RHR avg outlier \(String(format: "%.2f", avg)) on \(dayISO) — dumping samples…")
                        self.debugDumpRestingHRSamples(dayStart: stats.startDate, dayEnd: stats.endDate)
                    }
                    #endif

                    out[dayISO] = avg
                }

                cont.resume(returning: out)
            }

            self.store.execute(query)
        }
    }
    
        #if DEBUG
        private func debugDumpRestingHRSamples(dayStart: Date, dayEnd: Date) async {
            guard let type = HKObjectType.quantityType(forIdentifier: .restingHeartRate) else { return }

            let predicate = HKQuery.predicateForSamples(withStart: dayStart, end: dayEnd, options: .strictStartDate)
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]

            do {
                let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { cont in
                    let q = HKSampleQuery(
                        sampleType: type,
                        predicate: predicate,
                        limit: HKObjectQueryNoLimit,
                        sortDescriptors: sort
                    ) { _, samples, error in
                        if let error = error { cont.resume(throwing: error); return }
                        cont.resume(returning: (samples as? [HKQuantitySample]) ?? [])
                    }
                    self.store.execute(q)
                }

                print("🩺 RHR raw samples \(dayStart) → \(dayEnd) count=\(samples.count)")
                for s in samples {
                    let v = s.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                    let bundle = s.sourceRevision.source.bundleIdentifier
                    let sourceName = s.sourceRevision.source.name
                    let device = s.device?.name ?? "nil"
                    print("🩺 \(String(format: "%.1f", v)) bpm  \(s.startDate) → \(s.endDate)  source=\(sourceName) (\(bundle)) device=\(device)")
                }
            } catch {
                print("❌ debugDumpRestingHRSamples error: \(error)")
            }
        }
        #endif
    
    // MARK: - Sleep-window Daily Average (noon->noon, labeled by wake-up day)

    private func fetchSleepWindowDailyAverage(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async throws -> [String: Double] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [:] }

        // AFTER
        let widenedStart = Calendar.current.date(byAdding: .hour, value: -14, to: start) ?? start
        let predicate = HKQuery.predicateForSamples(withStart: widenedStart, end: end, options: .strictStartDate)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]

        return try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: sort
            ) { _, samples, error in
                if let error = error {
                    cont.resume(throwing: error)
                    return
                }

                let cal = Calendar.current
                let qs = (samples as? [HKQuantitySample]) ?? []
                #if DEBUG
                if identifier == .respiratoryRate {
                    print("🫁 RR raw sample count=\(qs.count) for window \(start) → \(end)")
                    for s in qs.prefix(5) {
                        print("🫁 \(String(format: "%.1f", s.quantity.doubleValue(for: unit))) br/min  \(s.startDate) → \(s.endDate)  source=\(s.sourceRevision.source.bundleIdentifier)")
                    }
                }
                #endif

                func sleepWindowStart(for date: Date) -> Date {
                    let sod = cal.startOfDay(for: date)
                    let noon = cal.date(byAdding: .hour, value: 12, to: sod)!
                    return (date < noon) ? cal.date(byAdding: .day, value: -1, to: noon)! : noon
                }

                func sleepLabelISO(for windowStart: Date) -> String {
                    let labelDate = cal.date(byAdding: .day, value: 1, to: windowStart)!
                    return Self.isoDayString(labelDate)
                }

                // Weighted avg by sample duration
                var sumByDay: [String: Double] = [:]
                var weightByDay: [String: Double] = [:]

                for s in qs {
                    // AFTER
                    var curStart = max(s.startDate, widenedStart)
                    let sampleEnd = min(s.endDate, end)

                    while curStart < sampleEnd {
                        let windowStart = sleepWindowStart(for: curStart)
                        let nextBoundary = cal.date(byAdding: .day, value: 1, to: windowStart)! // next noon
                        let curEnd = min(sampleEnd, nextBoundary)

                        let key = sleepLabelISO(for: windowStart)
                        let val = s.quantity.doubleValue(for: unit)
                        let w = curEnd.timeIntervalSince(curStart)

                        sumByDay[key, default: 0] += val * w
                        weightByDay[key, default: 0] += w

                        curStart = curEnd
                    }
                }

                var out: [String: Double] = [:]
                for (day, w) in weightByDay where w > 0 {
                    out[day] = (sumByDay[day] ?? 0) / w
                }

                cont.resume(returning: out)
            }

            self.store.execute(query)
        }
    }
    
    // MARK: - Overnight HRV (noon->noon, simple average — HRV samples are point-in-time)

    private func fetchOvernightHRV(start: Date, end: Date) async throws -> [String: Double] {
        guard let type = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return [:] }

        let cal = Calendar.current
        // Widen back 14 hours to capture sleep onset before midnight
        let widenedStart = cal.date(byAdding: .hour, value: -14, to: start) ?? start
        let predicate = HKQuery.predicateForSamples(withStart: widenedStart, end: end, options: .strictStartDate)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]

        return try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: sort
            ) { _, samples, error in
                if let error = error { cont.resume(throwing: error); return }

                let cal = Calendar.current
                let qs = (samples as? [HKQuantitySample]) ?? []

                var sumByDay: [String: Double] = [:]
                var countByDay: [String: Int] = [:]

                for s in qs {
                    // Bucket by sleep window (noon->noon), labeled by wake-up day
                    let sod = cal.startOfDay(for: s.startDate)
                    let noon = cal.date(byAdding: .hour, value: 12, to: sod)!
                    let windowStart = (s.startDate < noon)
                        ? cal.date(byAdding: .day, value: -1, to: noon)!
                        : noon
                    let labelDate = cal.date(byAdding: .day, value: 1, to: windowStart)!
                    let key = Self.isoDayString(labelDate)

                    // Simple unweighted average — HRV is point-in-time, duration weighting is meaningless
                    sumByDay[key, default: 0] += s.quantity.doubleValue(for: .second())
                    countByDay[key, default: 0] += 1
                }

                
                
                var out: [String: Double] = [:]
                for (day, count) in countByDay where count > 0 {
                    out[day] = (sumByDay[day] ?? 0) / Double(count)
                }

                cont.resume(returning: out)
            }
            self.store.execute(query)
        }
    }
    
    // MARK: - Overnight point-in-time average (noon->noon, simple average)
        // Used for respiratory rate and any other metric where samples have zero duration.

        private func fetchOvernightPointInTimeAverage(
            identifier: HKQuantityTypeIdentifier,
            unit: HKUnit,
            start: Date,
            end: Date
        ) async throws -> [String: Double] {
            guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [:] }

            let cal = Calendar.current
            let widenedStart = cal.date(byAdding: .hour, value: -14, to: start) ?? start
            let predicate = HKQuery.predicateForSamples(withStart: widenedStart, end: end, options: .strictStartDate)
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]

            return try await withCheckedThrowingContinuation { cont in
                let query = HKSampleQuery(
                    sampleType: type,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: sort
                ) { _, samples, error in
                    if let error = error { cont.resume(throwing: error); return }

                    let cal = Calendar.current
                    let qs = (samples as? [HKQuantitySample]) ?? []

                    var sumByDay: [String: Double] = [:]
                    var countByDay: [String: Int] = [:]

                    for s in qs {
                        // Bucket by sleep window (noon->noon), labeled by wake-up day
                        let sod = cal.startOfDay(for: s.startDate)
                        let noon = cal.date(byAdding: .hour, value: 12, to: sod)!
                        let windowStart = (s.startDate < noon)
                            ? cal.date(byAdding: .day, value: -1, to: noon)!
                            : noon
                        let labelDate = cal.date(byAdding: .day, value: 1, to: windowStart)!
                        let key = Self.isoDayString(labelDate)

                        sumByDay[key, default: 0] += s.quantity.doubleValue(for: unit)
                        countByDay[key, default: 0] += 1
                    }

                    var out: [String: Double] = [:]
                    for (day, count) in countByDay where count > 0 {
                        out[day] = (sumByDay[day] ?? 0) / Double(count)
                    }

                    cont.resume(returning: out)
                }
                self.store.execute(query)
            }
        }
    // MARK: - Daily Most Recent (quantity)

    private func fetchDailyMostRecent(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async throws -> [String: Double] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [:] }

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)] // newest first

        return try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: sort
            ) { _, samples, error in
                if let error = error {
                    cont.resume(throwing: error)
                    return
                }

                let qs = (samples as? [HKQuantitySample]) ?? []
                var out: [String: Double] = [:]

                for s in qs {
                    let dayISO = Self.isoDayString(s.startDate)
                    guard out[dayISO] == nil else { continue }
                    out[dayISO] = s.quantity.doubleValue(for: unit)
                }

                cont.resume(returning: out)
            }

            self.store.execute(query)
        }
    }

    // MARK: - Daily Sum (quantity, calendar-day)

    // MARK: - Daily Most Recent, Apple sources only (quantity)
        // Used for RHR to prevent contamination from third-party apps writing their own samples.

        private func fetchDailyMostRecentApple(
            identifier: HKQuantityTypeIdentifier,
            unit: HKUnit,
            start: Date,
            end: Date
        ) async throws -> [String: Double] {
            guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [:] }

            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)] // newest first

            return try await withCheckedThrowingContinuation { cont in
                let query = HKSampleQuery(
                    sampleType: type,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: sort
                ) { _, samples, error in
                    if let error = error {
                        cont.resume(throwing: error)
                        return
                    }

                    let qs = (samples as? [HKQuantitySample]) ?? []
                    var out: [String: Double] = [:]

                    for s in qs {
                        // Apple Watch / Apple Health sources only
                        let bundle = s.sourceRevision.source.bundleIdentifier.lowercased()
                        guard bundle.hasPrefix("com.apple.") else { continue }

                        let dayISO = Self.isoDayString(s.startDate)
                        guard out[dayISO] == nil else { continue } // keep newest (sort is descending)
                        let v = s.quantity.doubleValue(for: unit)
                        guard v >= 35 && v <= 110 else { continue } // same plausibility gate as before
                        out[dayISO] = v
                    }

                    cont.resume(returning: out)
                }

                self.store.execute(query)
            }
        }
    
    private func fetchDailySum(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async throws -> [String: Double] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [:] }

        let cal = Calendar.current
        let anchor = cal.startOfDay(for: start)
        var interval = DateComponents()
        interval.day = 1

        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: []
        )

        return try await withCheckedThrowingContinuation { cont in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: anchor,
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, results, error in
                if let error = error {
                    cont.resume(throwing: error)
                    return
                }

                var out: [String: Double] = [:]
                results?.enumerateStatistics(from: start, to: end) { stats, _ in
                    let dayISO = Self.isoDayString(stats.startDate)


                    if let sum = stats.sumQuantity()?.doubleValue(for: unit) {
                        out[dayISO] = sum
                    }
                }

                cont.resume(returning: out)
            }

            self.store.execute(query)
        }
    }

    // MARK: - Workouts (local calendar-day bucket)

    // MARK: - Mechanical Load (ElitePerformance → UserDefaults shared store)

    private func fetchMechanicalLoad(start: Date, end: Date) async throws -> [String: Double] {
        let raw = MechanicalLoadReader.readRange(from: start, to: end)
        var out: [String: Double] = [:]
        for (date, value) in raw {
            let dayISO = Self.isoDayString(Calendar.current.startOfDay(for: date))
            out[dayISO] = (out[dayISO] ?? 0) + value
        }
        #if DEBUG
        print("⚙️ MechanicalLoad (UserDefaults): \(out.count) day(s) found")
        for day in out.keys.sorted() {
            print("⚙️ MechanicalLoad[\(day)] = \(Int((out[day] ?? 0).rounded()))")
        }
        #endif
        return out
    }

        private struct WorkoutDaySummary {
            var count: Double
            var minutes: Double
            var energyKcal: Double
            var workouts: [HKWorkout] = []
        }

    private func fetchDailyWorkouts(start: Date, end: Date) async throws -> [String: WorkoutDaySummary] {
        let cal = Calendar.current

        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: .strictStartDate
        )

        let sort = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate,
            ascending: true
        )

        return try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error = error {
                    cont.resume(throwing: error)
                    return
                }

                let rawWorkouts = (samples as? [HKWorkout]) ?? []

                // Dedup near-identical duplicates. Apple Watch auto-detect can emit the same
                // short workout 2–3× (same activity type, near-identical start + duration),
                // which inflates count/minutes/energy AND TRIMP (each duplicate scored
                // separately) — polluting the `load` variable the sleep-composite validation
                // controls for. Keep the first of any duplicate cluster; genuinely distinct
                // sessions (different type, or > tolerance apart) are untouched.
                func isDuplicate(_ w: HKWorkout, of kept: HKWorkout) -> Bool {
                    w.workoutActivityType == kept.workoutActivityType
                        && abs(w.startDate.timeIntervalSince(kept.startDate)) < 90
                        && abs(w.duration - kept.duration) < 90
                }
                var workouts: [HKWorkout] = []
                for w in rawWorkouts where !workouts.contains(where: { isDuplicate(w, of: $0) }) {
                    workouts.append(w)
                }

                #if DEBUG
                if workouts.count != rawWorkouts.count {
                    print("🏋️ Deduped \(rawWorkouts.count - workouts.count) duplicate workout(s) (\(rawWorkouts.count) → \(workouts.count))")
                }
                print("🏋️ Workout raw count=\(workouts.count) range=\(start) → \(end)")
                for w in workouts {
                    let localDay = cal.startOfDay(for: w.startDate)
                    let dayISO = Self.isoDayString(localDay)

                    print("""
                    🏋️ Workout[\(dayISO)] \
                    \(w.workoutActivityType) \
                    \(w.startDate) → \(w.endDate) \
                    duration=\(String(format: "%.1f", w.duration / 60.0))min \
                    source=\(w.sourceRevision.source.name) \
                    bundle=\(w.sourceRevision.source.bundleIdentifier)
                    """)
                }
                #endif

                var out: [String: WorkoutDaySummary] = [:]

                for w in workouts {
                    // Workouts belong to the local calendar day they STARTED on.
                    // This is intentionally separate from sleep/readiness, which uses wake-day/noon→noon logic.
                    let localDay = cal.startOfDay(for: w.startDate)
                    let dayISO = Self.isoDayString(localDay)

                    var cur = out[dayISO] ?? WorkoutDaySummary(
                        count: 0,
                        minutes: 0,
                        energyKcal: 0
                    )

                    cur.count += 1
                                        cur.minutes += w.duration / 60.0
                                        cur.workouts.append(w)

                                        if let e = w.totalEnergyBurned?.doubleValue(for: .kilocalorie()) {
                                            cur.energyKcal += e
                                        }

                                        out[dayISO] = cur
                }

                #if DEBUG
                for key in out.keys.sorted() {
                    if let s = out[key] {
                        print("""
                        🏋️ WorkoutSummary[\(key)] \
                        count=\(Int(s.count)) \
                        minutes=\(String(format: "%.1f", s.minutes)) \
                        kcal=\(String(format: "%.0f", s.energyKcal))
                        """)
                    }
                }
                #endif

                cont.resume(returning: out)
            }

            self.store.execute(query)
        }
    }
    
    // MARK: - Average HR within a workout window

    private struct WorkoutHRSummary {
            let avgHR: Double
            let peakHR: Double
        }

        private func fetchAverageHR(for workout: HKWorkout) async throws -> Double? {
            try await fetchWorkoutHR(for: workout)?.avgHR
        }

        private func fetchWorkoutHR(for workout: HKWorkout) async throws -> WorkoutHRSummary? {
            guard let hrType = HKObjectType.quantityType(forIdentifier: .heartRate) else { return nil }
            let predicate = HKQuery.predicateForSamples(
                withStart: workout.startDate,
                end: workout.endDate,
                options: .strictStartDate
            )
            return try await withCheckedThrowingContinuation { cont in
                let query = HKSampleQuery(
                    sampleType: hrType,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: nil
                ) { _, samples, error in
                    if let error = error { cont.resume(throwing: error); return }
                    let hrSamples = (samples as? [HKQuantitySample]) ?? []
                    guard !hrSamples.isEmpty else { cont.resume(returning: nil); return }
                    let unit = HKUnit.count().unitDivided(by: .minute())
                    let vals = hrSamples.map { $0.quantity.doubleValue(for: unit) }
                    let avg = vals.reduce(0, +) / Double(vals.count)
                    let peak = vals.max() ?? avg
                    cont.resume(returning: WorkoutHRSummary(avgHR: avg, peakHR: peak))
                }
                self.store.execute(query)
            }
        }

    // MARK: - Sleep breakdown (Apple Watch only; noon->noon)

    private struct SleepDayBreakdown {
        // EXISTING — unchanged. All current consumers (asleepHours/inBedHours) keep reading these.
        var asleepHours: Double
        var inBedHours: Double

        // ADDITIVE (Phase 2a). Per-stage minutes are merged-interval durations (same
        // overlap-safe method as asleep/inBed). Segments are RAW and unsmoothed —
        // SleepQualityEngine owns the 5-min min-bout / adjacent-merge noise floor.
        var deepMinutes: Double
        var remMinutes: Double
        var coreMinutes: Double
        var unspecifiedMinutes: Double
        var awakeMinutes: Double

        // Merged sleep-window bounds (earliest window start → latest window end) for the
        // day. Enable onset latency (windowStart → first asleep segment) and consistency
        // (bed/wake times, midpoint). Nil when no window intervals landed in the day.
        var windowStart: Date?
        var windowEnd: Date?

        // Sleep-period time (SPT): first asleep → last asleep, in minutes. This is the
        // efficiency denominator (asleep / SPT), NOT time-in-bed — so pre-onset latency and
        // post-final-wake in-bed awake don't double-penalize efficiency (they're captured as
        // latency). WASO between first and last asleep stays inside SPT and still counts.
        var sleepPeriodMinutes: Double

        // RAW ordered stage/awake segments, split at noon boundaries, clipped to the day,
        // sorted by start. NO smoothing, NO min-bout, NO adjacent-merge — persisted as
        // delivered so the engine can apply its own noise rejection.
        var segments: [SleepSegment]

        // True when granular substates (deep/REM/core) were present this night. When false
        // the per-stage split is untrustworthy (unspecified/legacy only) and the engine
        // should fall back rather than score architecture from empty stage buckets.
        var hasStagedData: Bool
    }

    private func fetchDailySleepBreakdownApple(start: Date, end: Date) async throws -> [String: SleepDayBreakdown] {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [:] }

        // ✅ Widen start so we capture the overnight period that belongs to the first "day label"
        let widenedStart = Calendar.current.date(byAdding: .day, value: -1, to: start) ?? start

        let predicate = HKQuery.predicateForSamples(withStart: widenedStart, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { [weak self] _, samples, error in
                if let error = error {
                    cont.resume(throwing: error)
                    return
                }
                guard let self else {
                    cont.resume(returning: [:])
                    return
                }

                let cal = Calendar.current
                let allSamples = (samples as? [HKCategorySample]) ?? []

                // Apple-only sources, exclude known third party
                let appleOnly = allSamples.filter { Self.isAppleSleepSource($0) }

                let hasStaged: Bool = {
                    if #available(iOS 16.0, *) {
                        return appleOnly.contains { s in
                            s.value == HKCategoryValueSleepAnalysis.asleepCore.rawValue
                            || s.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
                            || s.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue
                        }
                    } else { return false }
                }()

                // ---------- Predicates ----------
                func isAsleepValue(_ v: Int) -> Bool {
                    if #available(iOS 16.0, *) {
                        if hasStaged {
                            return v == HKCategoryValueSleepAnalysis.asleepCore.rawValue
                                || v == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
                                || v == HKCategoryValueSleepAnalysis.asleepREM.rawValue
                                || v == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                        } else {
                            return v == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                                || v == HKCategoryValueSleepAnalysis.asleep.rawValue
                        }
                    } else {
                        return v == HKCategoryValueSleepAnalysis.asleep.rawValue
                    }
                }

                // ✅ This is the key fix:
                // Window = union of inBed + awake + asleep (so it never collapses to 0 when inBed is missing).
                func isWindowValue(_ v: Int) -> Bool {
                    if #available(iOS 16.0, *) {
                        return v == HKCategoryValueSleepAnalysis.inBed.rawValue
                            || v == HKCategoryValueSleepAnalysis.awake.rawValue
                            || v == HKCategoryValueSleepAnalysis.asleepCore.rawValue
                            || v == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
                            || v == HKCategoryValueSleepAnalysis.asleepREM.rawValue
                            || v == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                            || v == HKCategoryValueSleepAnalysis.asleep.rawValue
                    } else {
                        return v == HKCategoryValueSleepAnalysis.inBed.rawValue
                            || v == HKCategoryValueSleepAnalysis.asleep.rawValue
                    }
                }

                // Stage classifier (Phase 2a). Maps a raw category value to a SleepStage,
                // or nil for non-stage values (.inBed — the window container, not a stage).
                // Legacy/unspecified "asleep" collapses to .unspecified. Awake bouts are
                // kept RAW here (micro-arousal blips included) — the engine's min-bout floor
                // decides what counts as a real awakening.
                func stageFor(_ v: Int) -> SleepStage? {
                    if #available(iOS 16.0, *) {
                        switch v {
                        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:        return .deep
                        case HKCategoryValueSleepAnalysis.asleepREM.rawValue:         return .rem
                        case HKCategoryValueSleepAnalysis.asleepCore.rawValue:        return .core
                        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: return .unspecified
                        case HKCategoryValueSleepAnalysis.asleep.rawValue:            return .unspecified
                        case HKCategoryValueSleepAnalysis.awake.rawValue:             return .awake
                        default:                                                      return nil
                        }
                    } else {
                        switch v {
                        case HKCategoryValueSleepAnalysis.asleep.rawValue: return .unspecified
                        default:                                           return nil
                        }
                    }
                }

                // ---------- Noon→Noon bucketing ----------
                func sleepWindowStart(for date: Date) -> Date {
                    let startOfDay = cal.startOfDay(for: date)
                    let noon = cal.date(byAdding: .hour, value: 12, to: startOfDay)!
                    return (date < noon) ? cal.date(byAdding: .day, value: -1, to: noon)! : noon
                }

                func sleepLabelISO(for windowStart: Date) -> String {
                    let labelDate = cal.date(byAdding: .day, value: 1, to: windowStart)!
                    return Self.isoDayString(labelDate)
                }

                func bucketIntervals(
                    _ samples: [HKCategorySample],
                    clipStart: Date,
                    predicate: (Int) -> Bool
                ) -> [String: [(Date, Date)]] {
                    var dayToIntervals: [String: [(Date, Date)]] = [:]

                    for s in samples {
                        guard predicate(s.value) else { continue }

                        // ✅ critical: clip to widenedStart (not "start")
                        var curStart = max(s.startDate, clipStart)
                        let sampleEnd = min(s.endDate, end)

                        while curStart < sampleEnd {
                            let windowStart = sleepWindowStart(for: curStart)
                            let nextBoundary = cal.date(byAdding: .day, value: 1, to: windowStart)! // next noon
                            let curEnd = min(sampleEnd, nextBoundary)

                            let key = sleepLabelISO(for: windowStart)
                            dayToIntervals[key, default: []].append((curStart, curEnd))

                            curStart = curEnd
                        }
                    }

                    return dayToIntervals
                }

                // Per-stage minutes via the SAME bucket→merge path as asleep/inBed, so a
                // stage's duration is overlap-safe (duplicate/overlapping Apple samples don't
                // double-count). Returns minutes per day for one stage.
                func stageMinutesByDay(_ target: SleepStage) -> [String: Double] {
                    let byDay = bucketIntervals(appleOnly, clipStart: widenedStart) { stageFor($0) == target }
                    var result: [String: Double] = [:]
                    for (day, ivals) in byDay {
                        result[day] = self.mergeIntervals(ivals)
                            .reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) } / 60.0
                    }
                    return result
                }

                let asleepByDay = bucketIntervals(appleOnly, clipStart: widenedStart, predicate: isAsleepValue)
                let windowByDay = bucketIntervals(appleOnly, clipStart: widenedStart, predicate: isWindowValue)

                // Per-stage merged minutes (Phase 2a).
                let deepByDay        = stageMinutesByDay(.deep)
                let remByDay         = stageMinutesByDay(.rem)
                let coreByDay        = stageMinutesByDay(.core)
                let unspecifiedByDay = stageMinutesByDay(.unspecified)
                let awakeByDay       = stageMinutesByDay(.awake)

                // RAW ordered stage/awake segments (Phase 2a). Split across noon boundaries
                // and clipped exactly like bucketIntervals, but NOT merged — each source
                // interval survives so the engine can smooth. inBed (nil stage) is skipped.
                var segmentsByDay: [String: [SleepSegment]] = [:]
                for s in appleOnly {
                    guard let stage = stageFor(s.value) else { continue }
                    var curStart = max(s.startDate, widenedStart)
                    let sampleEnd = min(s.endDate, end)
                    while curStart < sampleEnd {
                        let windowStart = sleepWindowStart(for: curStart)
                        let nextBoundary = cal.date(byAdding: .day, value: 1, to: windowStart)!
                        let curEnd = min(sampleEnd, nextBoundary)
                        let key = sleepLabelISO(for: windowStart)
                        segmentsByDay[key, default: []].append(
                            SleepSegment(stage: stage, start: curStart, end: curEnd)
                        )
                        curStart = curEnd
                    }
                }
                for key in segmentsByDay.keys {
                    segmentsByDay[key]?.sort { $0.start < $1.start }
                }

                var out: [String: SleepDayBreakdown] = [:]
                let allKeys = Set(asleepByDay.keys).union(windowByDay.keys)

                for dayISO in allKeys {
                    let asleepIntervals = asleepByDay[dayISO] ?? []
                    let windowIntervals = windowByDay[dayISO] ?? []

                    let mergedAsleep = self.mergeIntervals(asleepIntervals)
                    let mergedWindow = self.mergeIntervals(windowIntervals)

                    let asleepHours = mergedAsleep.reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) } / 3600.0
                    let windowHours = mergedWindow.reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) } / 3600.0

                    // ✅ final sanity: window should never be < asleep
                    let inBedHours = max(windowHours, asleepHours)

                    // SPT = first asleep → last asleep (excludes pre-onset + post-final-wake
                    // in-bed awake). Falls back to asleep minutes if no asleep segments.
                    let daySegs = segmentsByDay[dayISO] ?? []
                    let asleepSegs = daySegs.filter { $0.stage != .awake }
                    let sptMinutes: Double = {
                        guard let f = asleepSegs.map({ $0.start }).min(),
                              let l = asleepSegs.map({ $0.end }).max(), l > f else {
                            return asleepHours * 60.0
                        }
                        return l.timeIntervalSince(f) / 60.0
                    }()

                    out[dayISO] = SleepDayBreakdown(
                        asleepHours: asleepHours,
                        inBedHours: inBedHours,
                        deepMinutes: deepByDay[dayISO] ?? 0,
                        remMinutes: remByDay[dayISO] ?? 0,
                        coreMinutes: coreByDay[dayISO] ?? 0,
                        unspecifiedMinutes: unspecifiedByDay[dayISO] ?? 0,
                        awakeMinutes: awakeByDay[dayISO] ?? 0,
                        windowStart: mergedWindow.first?.0,
                        windowEnd: mergedWindow.last?.1,
                        sleepPeriodMinutes: sptMinutes,
                        segments: segmentsByDay[dayISO] ?? [],
                        hasStagedData: hasStaged
                    )
                }

                #if DEBUG
                let newestKey = allKeys.sorted().last
                if let k = newestKey, let newest = out[k] {
                    print("🛌 SleepWindow[\(k)] asleep=\(String(format: "%.2f", newest.asleepHours))h window=\(String(format: "%.2f", newest.inBedHours))h")
                }
                #endif

                cont.resume(returning: out)
            }

            self.store.execute(query)
        }
    }

// MARK: - Sleep-window RHR (comparison field; computed from raw HR during verified asleep states)
// TEMPORARY COMPARISON SOURCE — not wired into ReadinessEngine scoring.
//
// Apple's .restingHeartRate has been observed (via debugDumpRestingHRSamples) to
// occasionally report values well above the true overnight floor — e.g. 76/80 bpm
// reported on nights where raw 3-6am .heartRate samples showed a floor of 60.0/61.3
// bpm. Suspected cause: Apple's algorithm can draw from non-sleep, low-motion
// daytime periods rather than verified sleep. This computes our own RHR by
// averaging raw .heartRate samples that occur strictly within verified
// HKCategoryValueSleepAnalysis "asleep" intervals (asleepCore/Deep/REM/Unspecified
// on iOS 16+, falling back to legacy .asleep pre-iOS 16) — explicitly excluding
// .inBed and .awake.
private func fetchSleepWindowRHR(start: Date, end: Date) async throws -> [String: Double] {
    guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [:] }
    guard let hrType = HKObjectType.quantityType(forIdentifier: .heartRate) else { return [:] }

    let cal = Calendar.current
    // Widen back one day so we capture the overnight period belonging to the first day label,
    // same convention as fetchDailySleepBreakdownApple.
    let widenedStart = cal.date(byAdding: .day, value: -1, to: start) ?? start

    let sleepPredicate = HKQuery.predicateForSamples(withStart: widenedStart, end: end, options: .strictStartDate)
    let sleepSort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

    let sleepSamples: [HKCategorySample] = try await withCheckedThrowingContinuation { cont in
        let query = HKSampleQuery(
            sampleType: sleepType,
            predicate: sleepPredicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sleepSort]
        ) { _, samples, error in
            if let error { cont.resume(throwing: error); return }
            cont.resume(returning: (samples as? [HKCategorySample]) ?? [])
        }
        self.store.execute(query)
    }

    // Apple-only sources, same filter used for sleep duration (excludes SleepWatch/AutoSleep etc).
    let appleOnly = sleepSamples.filter { Self.isAppleSleepSource($0) }

    // Prefer granular asleep substates (iOS 16+); fall back to legacy/unspecified "asleep"
    // when staged data isn't present for this period — same hasStaged check as
    // fetchDailySleepBreakdownApple.
    let hasStaged: Bool = {
        if #available(iOS 16.0, *) {
            return appleOnly.contains { s in
                s.value == HKCategoryValueSleepAnalysis.asleepCore.rawValue
                || s.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
                || s.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue
            }
        } else { return false }
    }()

    func isAsleepValue(_ v: Int) -> Bool {
        if #available(iOS 16.0, *) {
            if hasStaged {
                // Granular substates available — explicitly EXCLUDES .inBed and .awake.
                return v == HKCategoryValueSleepAnalysis.asleepCore.rawValue
                    || v == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
                    || v == HKCategoryValueSleepAnalysis.asleepREM.rawValue
                    || v == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
            } else {
                // No staged substates this period — fall back to .asleepUnspecified / legacy .asleep.
                // Still explicitly EXCLUDES .inBed and .awake.
                return v == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                    || v == HKCategoryValueSleepAnalysis.asleep.rawValue
            }
        } else {
            // Pre-iOS 16: only the legacy .asleep value exists.
            return v == HKCategoryValueSleepAnalysis.asleep.rawValue
        }
    }

    func sleepWindowStart(for date: Date) -> Date {
        let sod = cal.startOfDay(for: date)
        let noon = cal.date(byAdding: .hour, value: 12, to: sod)!
        return (date < noon) ? cal.date(byAdding: .day, value: -1, to: noon)! : noon
    }

    func sleepLabelISO(for windowStart: Date) -> String {
        let labelDate = cal.date(byAdding: .day, value: 1, to: windowStart)!
        return Self.isoDayString(labelDate)
    }

    // Bucket asleep-only intervals by wake-day label (noon->noon) — same bucketing
    // convention as fetchDailySleepBreakdownApple / fetchSleepWindowDailyAverage.
    var asleepByDay: [String: [(Date, Date)]] = [:]
    for s in appleOnly {
        guard isAsleepValue(s.value) else { continue }

        var curStart = max(s.startDate, widenedStart)
        let sampleEnd = min(s.endDate, end)

        while curStart < sampleEnd {
            let windowStart = sleepWindowStart(for: curStart)
            let nextBoundary = cal.date(byAdding: .day, value: 1, to: windowStart)!
            let curEnd = min(sampleEnd, nextBoundary)

            let key = sleepLabelISO(for: windowStart)
            asleepByDay[key, default: []].append((curStart, curEnd))

            curStart = curEnd
        }
    }

    var mergedAsleepByDay: [String: [(Date, Date)]] = [:]
    for (day, intervals) in asleepByDay {
        mergedAsleepByDay[day] = self.mergeIntervals(intervals)
    }

    guard !mergedAsleepByDay.isEmpty else {
        #if DEBUG
        print("💓 SleepWindowRHR: no verified asleep intervals found for range \(start) → \(end)")
        #endif
        return [:]
    }

    // Single bulk heartRate fetch across the whole range, then assign each sample to
    // whichever day's merged asleep interval (if any) contains it. This matches the
    // file's existing pattern of one bulk fetch + in-memory bucketing (see
    // fetchOvernightHRV, fetchSleepWindowDailyAverage) rather than issuing a separate
    // HealthKit query per asleep interval.
    let hrPredicate = HKQuery.predicateForSamples(withStart: widenedStart, end: end, options: .strictStartDate)
    let hrSort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

    let hrSamples: [HKQuantitySample] = try await withCheckedThrowingContinuation { cont in
        let query = HKSampleQuery(
            sampleType: hrType,
            predicate: hrPredicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [hrSort]
        ) { _, samples, error in
            if let error { cont.resume(throwing: error); return }
            cont.resume(returning: (samples as? [HKQuantitySample]) ?? [])
        }
        self.store.execute(query)
    }

    let bpmUnit = HKUnit.count().unitDivided(by: .minute())
    var sumByDay: [String: Double] = [:]
    var countByDay: [String: Int] = [:]

    for s in hrSamples {
        // Apple Watch only — same source gate used for RHR (fetchDailyMostRecentApple).
        guard s.sourceRevision.source.bundleIdentifier.lowercased().hasPrefix("com.apple.") else { continue }

        let windowStart = sleepWindowStart(for: s.startDate)
        let key = sleepLabelISO(for: windowStart)

        guard let intervals = mergedAsleepByDay[key] else { continue }
        guard intervals.contains(where: { s.startDate >= $0.0 && s.startDate < $0.1 }) else { continue }

        sumByDay[key, default: 0] += s.quantity.doubleValue(for: bpmUnit)
        countByDay[key, default: 0] += 1
    }

    var out: [String: Double] = [:]
    for (day, count) in countByDay where count > 0 {
        out[day] = (sumByDay[day] ?? 0) / Double(count)
    }

    #if DEBUG
    for day in out.keys.sorted() {
        print("💓 SleepWindowRHR[\(day)] avg=\(String(format: "%.1f", out[day] ?? 0)) bpm samples=\(countByDay[day] ?? 0) asleepIntervals=\(mergedAsleepByDay[day]?.count ?? 0)")
    }
    if out.isEmpty {
        print("💓 SleepWindowRHR: no heart rate samples found within verified asleep windows")
    }
    #endif

    return out
}

// MARK: - Sleep-window HRV (comparison field; computed from raw SDNN during verified asleep states)
// TEMPORARY COMPARISON SOURCE — same architecture as fetchSleepWindowRHR above.
//
// Apple's .heartRateVariabilitySDNN is computed as an all-day average of readings
// taken roughly every 15 minutes, including while awake — mixing daytime sympathetic
// activity with overnight parasympathetic state. Raw samples confirm this: SDNN can
// range from ~7.7ms during deep sleep to ~56ms shortly after waking within the same
// calendar day. This computes our own HRV by averaging raw .heartRateVariabilitySDNN
// samples that occur strictly within verified HKCategoryValueSleepAnalysis "asleep"
// intervals (asleepCore/Deep/REM/Unspecified on iOS 16+, falling back to legacy
// .asleep pre-iOS 16) — explicitly excluding .inBed and .awake.
private func fetchSleepWindowHRV(start: Date, end: Date) async throws -> [String: Double] {
    guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [:] }
    guard let hrvType = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return [:] }

    let cal = Calendar.current
    // Widen back one day so we capture the overnight period belonging to the first day label,
    // same convention as fetchDailySleepBreakdownApple / fetchSleepWindowRHR.
    let widenedStart = cal.date(byAdding: .day, value: -1, to: start) ?? start

    let sleepPredicate = HKQuery.predicateForSamples(withStart: widenedStart, end: end, options: .strictStartDate)
    let sleepSort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

    let sleepSamples: [HKCategorySample] = try await withCheckedThrowingContinuation { cont in
        let query = HKSampleQuery(
            sampleType: sleepType,
            predicate: sleepPredicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sleepSort]
        ) { _, samples, error in
            if let error { cont.resume(throwing: error); return }
            cont.resume(returning: (samples as? [HKCategorySample]) ?? [])
        }
        self.store.execute(query)
    }

    // Apple-only sources, same filter used for sleep duration (excludes SleepWatch/AutoSleep etc).
    let appleOnly = sleepSamples.filter { Self.isAppleSleepSource($0) }

    // Prefer granular asleep substates (iOS 16+); fall back to legacy/unspecified "asleep"
    // when staged data isn't present for this period — same hasStaged check as
    // fetchDailySleepBreakdownApple / fetchSleepWindowRHR.
    let hasStaged: Bool = {
        if #available(iOS 16.0, *) {
            return appleOnly.contains { s in
                s.value == HKCategoryValueSleepAnalysis.asleepCore.rawValue
                || s.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
                || s.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue
            }
        } else { return false }
    }()

    func isAsleepValue(_ v: Int) -> Bool {
        if #available(iOS 16.0, *) {
            if hasStaged {
                // Granular substates available — explicitly EXCLUDES .inBed and .awake.
                return v == HKCategoryValueSleepAnalysis.asleepCore.rawValue
                    || v == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
                    || v == HKCategoryValueSleepAnalysis.asleepREM.rawValue
                    || v == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
            } else {
                // No staged substates this period — fall back to .asleepUnspecified / legacy .asleep.
                // Still explicitly EXCLUDES .inBed and .awake.
                return v == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                    || v == HKCategoryValueSleepAnalysis.asleep.rawValue
            }
        } else {
            // Pre-iOS 16: only the legacy .asleep value exists.
            return v == HKCategoryValueSleepAnalysis.asleep.rawValue
        }
    }

    func sleepWindowStart(for date: Date) -> Date {
        let sod = cal.startOfDay(for: date)
        let noon = cal.date(byAdding: .hour, value: 12, to: sod)!
        return (date < noon) ? cal.date(byAdding: .day, value: -1, to: noon)! : noon
    }

    func sleepLabelISO(for windowStart: Date) -> String {
        let labelDate = cal.date(byAdding: .day, value: 1, to: windowStart)!
        return Self.isoDayString(labelDate)
    }

    // Bucket asleep-only intervals by wake-day label (noon->noon) — same bucketing
    // convention as fetchDailySleepBreakdownApple / fetchSleepWindowRHR.
    var asleepByDay: [String: [(Date, Date)]] = [:]
    for s in appleOnly {
        guard isAsleepValue(s.value) else { continue }

        var curStart = max(s.startDate, widenedStart)
        let sampleEnd = min(s.endDate, end)

        while curStart < sampleEnd {
            let windowStart = sleepWindowStart(for: curStart)
            let nextBoundary = cal.date(byAdding: .day, value: 1, to: windowStart)!
            let curEnd = min(sampleEnd, nextBoundary)

            let key = sleepLabelISO(for: windowStart)
            asleepByDay[key, default: []].append((curStart, curEnd))

            curStart = curEnd
        }
    }

    var mergedAsleepByDay: [String: [(Date, Date)]] = [:]
    for (day, intervals) in asleepByDay {
        mergedAsleepByDay[day] = self.mergeIntervals(intervals)
    }

    guard !mergedAsleepByDay.isEmpty else {
        #if DEBUG
        print("💓 SleepWindowHRV: no verified asleep intervals found for range \(start) → \(end)")
        #endif
        return [:]
    }

    // Single bulk HRV fetch across the whole range, then assign each sample to
    // whichever day's merged asleep interval (if any) contains it. Same pattern
    // as fetchSleepWindowRHR — one bulk fetch + in-memory bucketing rather than
    // issuing a separate HealthKit query per asleep interval.
    let hrvPredicate = HKQuery.predicateForSamples(withStart: widenedStart, end: end, options: .strictStartDate)
    let hrvSort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

    let hrvSamples: [HKQuantitySample] = try await withCheckedThrowingContinuation { cont in
        let query = HKSampleQuery(
            sampleType: hrvType,
            predicate: hrvPredicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [hrvSort]
        ) { _, samples, error in
            if let error { cont.resume(throwing: error); return }
            cont.resume(returning: (samples as? [HKQuantitySample]) ?? [])
        }
        self.store.execute(query)
    }

    let msUnit = HKUnit.secondUnit(with: .milli)
    var sumByDay: [String: Double] = [:]
    var countByDay: [String: Int] = [:]

    for s in hrvSamples {
        // Apple Watch only — same source gate used for RHR (fetchDailyMostRecentApple / fetchSleepWindowRHR).
        guard s.sourceRevision.source.bundleIdentifier.lowercased().hasPrefix("com.apple.") else { continue }

        let windowStart = sleepWindowStart(for: s.startDate)
        let key = sleepLabelISO(for: windowStart)

        guard let intervals = mergedAsleepByDay[key] else { continue }
        guard intervals.contains(where: { s.startDate >= $0.0 && s.startDate < $0.1 }) else { continue }

        sumByDay[key, default: 0] += s.quantity.doubleValue(for: msUnit)
        countByDay[key, default: 0] += 1
    }

    var out: [String: Double] = [:]
    for (day, count) in countByDay where count > 0 {
        out[day] = (sumByDay[day] ?? 0) / Double(count)
    }

    #if DEBUG
    for day in out.keys.sorted() {
        print("💓 SleepWindowHRV[\(day)] avg=\(String(format: "%.1f", out[day] ?? 0)) ms samples=\(countByDay[day] ?? 0) asleepIntervals=\(mergedAsleepByDay[day]?.count ?? 0)")
    }
    if out.isEmpty {
        print("💓 SleepWindowHRV: no HRV samples found within verified asleep windows")
    }
    #endif

    return out
}

#if DEBUG
func debugDumpSleepSamplesForDay(_ dayISO: String) async throws {
    guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
        print("🛌 DEBUG Sleep: sleepAnalysis type unavailable")
        return
    }

    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.dateFormat = "yyyy-MM-dd"

    guard let labelDate = df.date(from: dayISO) else {
        print("🛌 DEBUG Sleep: invalid dayISO=\(dayISO)")
        return
    }

    let cal = Calendar.current

    // For a wake-day label like 2026-05-07:
    // sleep window is noon previous day -> noon label day.
    let labelStart = cal.startOfDay(for: labelDate)
    let labelNoon = cal.date(byAdding: .hour, value: 12, to: labelStart)!
    let windowStart = cal.date(byAdding: .day, value: -1, to: labelNoon)!
    let windowEnd = labelNoon

    let predicate = HKQuery.predicateForSamples(
        withStart: windowStart,
        end: windowEnd,
        options: []
    )

    let sort = NSSortDescriptor(
        key: HKSampleSortIdentifierStartDate,
        ascending: true
    )

    func sleepValueName(_ value: Int) -> String {
        if #available(iOS 16.0, *) {
            switch value {
            case HKCategoryValueSleepAnalysis.inBed.rawValue:
                return "inBed"
            case HKCategoryValueSleepAnalysis.awake.rawValue:
                return "awake"
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                return "asleepCore"
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                return "asleepDeep"
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                return "asleepREM"
            case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                return "asleepUnspecified"
            case HKCategoryValueSleepAnalysis.asleep.rawValue:
                return "asleep_legacy"
            default:
                return "unknown_\(value)"
            }
        } else {
            switch value {
            case HKCategoryValueSleepAnalysis.inBed.rawValue:
                return "inBed"
            case HKCategoryValueSleepAnalysis.asleep.rawValue:
                return "asleep_legacy"
            default:
                return "unknown_\(value)"
            }
        }
    }

    func fmtTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return f.string(from: date)
    }

    let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { cont in
        let query = HKSampleQuery(
            sampleType: sleepType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sort]
        ) { _, samples, error in
            if let error {
                cont.resume(throwing: error)
                return
            }

            cont.resume(returning: (samples as? [HKCategorySample]) ?? [])
        }

        self.store.execute(query)
    }

    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("🛌 RAW SLEEP DEBUG for wake-day \(dayISO)")
    print("Window: \(fmtTime(windowStart)) → \(fmtTime(windowEnd))")
    print("Raw sample count: \(samples.count)")

    var totalsByValue: [String: Double] = [:]
    var totalsBySource: [String: Double] = [:]
    var appleOnlyAsleepIntervals: [(Date, Date)] = []
    var allAsleepIntervals: [(Date, Date)] = []
    var appleOnlyWindowIntervals: [(Date, Date)] = []
    var allWindowIntervals: [(Date, Date)] = []

    func isAsleep(_ value: Int) -> Bool {
        if #available(iOS 16.0, *) {
            return value == HKCategoryValueSleepAnalysis.asleepCore.rawValue
                || value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
                || value == HKCategoryValueSleepAnalysis.asleepREM.rawValue
                || value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                || value == HKCategoryValueSleepAnalysis.asleep.rawValue
        } else {
            return value == HKCategoryValueSleepAnalysis.asleep.rawValue
        }
    }

    func isWindow(_ value: Int) -> Bool {
        if #available(iOS 16.0, *) {
            return value == HKCategoryValueSleepAnalysis.inBed.rawValue
                || value == HKCategoryValueSleepAnalysis.awake.rawValue
                || value == HKCategoryValueSleepAnalysis.asleepCore.rawValue
                || value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
                || value == HKCategoryValueSleepAnalysis.asleepREM.rawValue
                || value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                || value == HKCategoryValueSleepAnalysis.asleep.rawValue
        } else {
            return value == HKCategoryValueSleepAnalysis.inBed.rawValue
                || value == HKCategoryValueSleepAnalysis.asleep.rawValue
        }
    }

    for s in samples {
        let name = sleepValueName(s.value)
        let minutes = s.endDate.timeIntervalSince(s.startDate) / 60.0
        let sourceName = s.sourceRevision.source.name
        let bundle = s.sourceRevision.source.bundleIdentifier
        let isApple = Self.isAppleSleepSource(s)

        totalsByValue[name, default: 0] += minutes
        totalsBySource["\(sourceName) | \(bundle)", default: 0] += minutes

        if isAsleep(s.value) {
            allAsleepIntervals.append((s.startDate, s.endDate))
            if isApple {
                appleOnlyAsleepIntervals.append((s.startDate, s.endDate))
            }
        }

        if isWindow(s.value) {
            allWindowIntervals.append((s.startDate, s.endDate))
            if isApple {
                appleOnlyWindowIntervals.append((s.startDate, s.endDate))
            }
        }

        print("""
        🛌 sample value=\(name) minutes=\(String(format: "%.1f", minutes)) apple=\(isApple)
           \(fmtTime(s.startDate)) → \(fmtTime(s.endDate))
           source=\(sourceName)
           bundle=\(bundle)
        """)
    }

    print("— Totals by value, unmerged raw minutes —")
    for key in totalsByValue.keys.sorted() {
        print("🛌 \(key): \(String(format: "%.1f", totalsByValue[key] ?? 0)) min")
    }

    print("— Totals by source, unmerged raw minutes —")
    for key in totalsBySource.keys.sorted() {
        print("🛌 \(key): \(String(format: "%.1f", totalsBySource[key] ?? 0)) min")
    }

    let mergedAppleAsleep = mergeIntervals(appleOnlyAsleepIntervals)
    let mergedAllAsleep = mergeIntervals(allAsleepIntervals)
    let mergedAppleWindow = mergeIntervals(appleOnlyWindowIntervals)
    let mergedAllWindow = mergeIntervals(allWindowIntervals)

    let appleAsleepHours = mergedAppleAsleep.reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) } / 3600.0
    let allAsleepHours = mergedAllAsleep.reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) } / 3600.0
    let appleWindowHours = mergedAppleWindow.reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) } / 3600.0
    let allWindowHours = mergedAllWindow.reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) } / 3600.0

    print("— Merged totals —")
    print("🛌 Apple-only asleep: \(String(format: "%.2f", appleAsleepHours))h")
    print("🛌 All-source asleep: \(String(format: "%.2f", allAsleepHours))h")
    print("🛌 Apple-only window: \(String(format: "%.2f", appleWindowHours))h")
    print("🛌 All-source window: \(String(format: "%.2f", allWindowHours))h")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
}
#endif
    
    // MARK: - Utilities

    private func mergeIntervals(_ intervals: [(Date, Date)]) -> [(Date, Date)] {
        guard !intervals.isEmpty else { return [] }

        let sorted = intervals.sorted { $0.0 < $1.0 }
        var merged: [(Date, Date)] = [sorted[0]]

        for (s, e) in sorted.dropFirst() {
            var last = merged.removeLast()
            if s <= last.1 {
                last.1 = max(last.1, e)
                merged.append(last)
            } else {
                merged.append(last)
                merged.append((s, e))
            }
        }

        return merged
    }

    private static func isAppleSleepSource(_ sample: HKSample) -> Bool {
        let bundle = sample.sourceRevision.source.bundleIdentifier.lowercased()

        if !bundle.hasPrefix("com.apple.") { return false }
        if bundle.contains("sleepwatch") { return false }
        if bundle.contains("autosleep") { return false }

        return true
    }

    private static func isoDayString(_ date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 1970
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}
