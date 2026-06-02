import Foundation
import HealthKit

final class HealthKitManager {
    static let shared = HealthKitManager()
    private let store = HKHealthStore()
    private init() {}

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

        // AFTER
        async let hrvSecondsDict = fetchOvernightHRV(start: start, end: end)

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
        async let workoutSummaryDict = fetchDailyWorkouts(start: start, end: end)

        let (
            rhr,
            hrvSeconds,
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
            workoutSummary
        ) = try await (
            rhrDict,
            hrvSecondsDict,
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
            workoutSummaryDict
        )

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

                        // Use observed peak HR (not avg) to estimate personal maxHR — floor 170
        let observedPeakHR = workoutHRDict.values.map { $0.peakHR }.max() ?? 0
                        // Assume observed peak ≈ 85% of true max for recreational athletes
                        // Floor of 155 handles cases with insufficient high-intensity data
                        let estimatedMaxHR = max(observedPeakHR / 0.85, 155.0)

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
            let hrvMS = hrvSeconds[dayISO].map { $0 * 1000.0 }

            let rr = respRate[dayISO]
            let wristAbsC = wristTemp[dayISO]

            let spo2PctVal = normalizePercent(spo2Raw[dayISO])

            let stepsVal = steps[dayISO]
            let energyVal = energy[dayISO]
            let exerciseVal = exerciseMin[dayISO]
            let standHoursVal = standMin[dayISO].map { $0 / 60.0 }

            let sleepVal = sleepDictResolved[dayISO]?.asleepHours
            let inBedVal = sleepDictResolved[dayISO]?.inBedHours

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
                    restingHR: rhrVal,
                    hrvMS: hrvMS,
                    sleepHours: sleepVal,
                    sleepInBedHours: inBedVal,
                    respiratoryRate: rr,
                    spo2Pct: spo2PctVal,
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
                                        bodyWeightLb: weightLb,
                    bodyFatPct: bodyFatPctVal,
                    leanMassLb: leanLb
                )
            )
        }

        return points
    }

    /// UI can still display 7; engine can use 28.
    func fetchLast7Days() async throws -> [DailyHealthPoint] {
        try await fetchLastNDays(7)
    }

    func fetchLast28Days() async throws -> [DailyHealthPoint] {
        try await fetchLastNDays(28)
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

                let workouts = (samples as? [HKWorkout]) ?? []

                #if DEBUG
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
        var asleepHours: Double
        var inBedHours: Double
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

                let asleepByDay = bucketIntervals(appleOnly, clipStart: widenedStart, predicate: isAsleepValue)
                let windowByDay = bucketIntervals(appleOnly, clipStart: widenedStart, predicate: isWindowValue)

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

                    out[dayISO] = SleepDayBreakdown(asleepHours: asleepHours, inBedHours: inBedHours)
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
