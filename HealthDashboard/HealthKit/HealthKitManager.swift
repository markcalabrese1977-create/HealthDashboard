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

        // Workouts
        set.insert(HKObjectType.workoutType())

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
            // If it looks like a fraction, normalize to 0–100.
            return (v <= 1.5) ? (v * 100.0) : v
        }

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
            let wCount = w?.count
            let wMinutes = w?.minutes
            let wEnergy = w?.energyKcal

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

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

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

                    #if DEBUG
                    if identifier == .restingHeartRate {
                        if let avg = stats.averageQuantity()?.doubleValue(for: unit) {
                            print("🩺 RHR avg \(dayISO) = \(String(format: "%.2f", avg))")
                        } else {
                            print("🩺 RHR avg \(dayISO) = nil (no samples in bucket)")
                        }
                    }
                    #endif

                    if let avg = stats.averageQuantity()?.doubleValue(for: unit) {
                        out[dayISO] = avg
                    }
                }

                cont.resume(returning: out)
            }

            self.store.execute(query)
        }
    }

    // MARK: - Workouts (calendar-day bucket)

    private struct WorkoutDaySummary {
        var count: Double
        var minutes: Double
        var energyKcal: Double
    }

    private func fetchDailyWorkouts(start: Date, end: Date) async throws -> [String: WorkoutDaySummary] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

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
                var out: [String: WorkoutDaySummary] = [:]

                for w in workouts {
                    let dayISO = Self.isoDayString(w.startDate)
                    var cur = out[dayISO] ?? WorkoutDaySummary(count: 0, minutes: 0, energyKcal: 0)

                    cur.count += 1
                    cur.minutes += (w.duration / 60.0)

                    if let e = w.totalEnergyBurned?.doubleValue(for: .kilocalorie()) {
                        cur.energyKcal += e
                    }

                    out[dayISO] = cur
                }

                cont.resume(returning: out)
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
