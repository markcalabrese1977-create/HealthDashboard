import XCTest
@testable import HealthDashboard

final class SleepQualityEngineTests: XCTestCase {

    // MARK: - Fixtures

    private let cal = Calendar.current

    /// A Date at a fixed time-of-day on a given May-2026 day.
    private func d(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = day; c.hour = hour; c.minute = minute
        return cal.date(from: c)!
    }

    /// A segment anchored `startMin`/`endMin` minutes after `base`.
    private func seg(_ stage: SleepStage, _ startMin: Double, _ endMin: Double, from base: Date) -> SleepSegment {
        SleepSegment(stage: stage,
                     start: base.addingTimeInterval(startMin * 60),
                     end: base.addingTimeInterval(endMin * 60))
    }

    /// Baseline night carrying persisted stage scalars + window bounds (bed 23:00 → wake 07:00).
    private func stagedPoint(day: Int, sleep: Double = 8.0, inBed: Double = 8.7,
                             deep: Double = 90, rem: Double = 110, core: Double = 280,
                             trimp: Double? = nil, mech: Double? = nil) -> DailyHealthPoint {
        DailyHealthPoint(
            dayISO: String(format: "2026-05-%02d", day),
            sleepHours: sleep,
            sleepInBedHours: inBed,
            sleepDeepMinutes: deep,
            sleepREMMinutes: rem,
            sleepCoreMinutes: core,
            sleepUnspecifiedMinutes: 0,
            sleepAwakeMinutes: 15,
            sleepWindowStart: d(day - 1, 23),
            sleepWindowEnd: d(day, 7),
            sleepPeriodMinutes: sleep * 60 + 20,   // SPT baseline: asleep + ~20min WASO
            dailyTrimp: trimp,
            mechanicalLoad: mech
        )
    }

    /// Baseline night with NO window bounds and NO stage scalars (defeats consistency + arch baseline).
    private func plainPoint(day: Int, sleep: Double = 8.0, inBed: Double = 8.7) -> DailyHealthPoint {
        DailyHealthPoint(dayISO: String(format: "2026-05-%02d", day), sleepHours: sleep, sleepInBedHours: inBed)
    }

    /// The scored night's own DailyHealthPoint (history.last).
    private func todayPoint(day: Int = 28, sleep: Double = 8.0, inBed: Double = 8.7) -> DailyHealthPoint {
        DailyHealthPoint(
            dayISO: String(format: "2026-05-%02d", day),
            sleepHours: sleep,
            sleepInBedHours: inBed,
            sleepWindowStart: d(day - 1, 23),
            sleepWindowEnd: d(day, 7)
        )
    }

    /// Clean staged segments (no awake) hitting exact stage-minute sums; 0 wake bouts.
    private func cleanStaged(deep: Double = 90, rem: Double = 110, core: Double = 280, from base: Date) -> [SleepSegment] {
        var segs: [SleepSegment] = []
        var t = 0.0
        func add(_ s: SleepStage, _ dur: Double) { if dur > 0 { segs.append(seg(s, t, t + dur, from: base)); t += dur } }
        add(.core, core / 2)
        add(.deep, deep)
        add(.rem, rem)
        add(.core, core / 2)
        return segs
    }

    private func stagedHistory(today: DailyHealthPoint) -> [DailyHealthPoint] {
        (1...27).map { stagedPoint(day: $0) } + [today]
    }

    private var base: Date { d(27, 23) }   // bedtime for the day-28 night

    private func eval(_ history: [DailyHealthPoint], _ segs: [SleepSegment]) -> SleepQualityResult {
        SleepQualityEngine.evaluate(history: history, todaySegments: segs)
    }

    private func sub(_ r: SleepQualityResult, _ axis: SleepAxis) -> SleepSubScore {
        r.subScores.first { $0.axis == axis }!
    }

    // MARK: - Golden path

    func testAllGoodNightIsExcellent() {
        let r = eval(stagedHistory(today: todayPoint()), cleanStaged(from: base))
        XCTAssertEqual(r.verdict, .excellent)
        XCTAssertGreaterThanOrEqual(r.composite, 85)
        XCTAssertEqual(r.availableAxes.count, 5)
        XCTAssertTrue(r.flags.isEmpty, "A near-baseline night should raise no flags")
    }

    func testFullAvailabilityWeightsSumTo100() {
        let r = eval(stagedHistory(today: todayPoint()), cleanStaged(from: base))
        let sum = r.subScores.reduce(0.0) { $0 + $1.effectiveWeight }
        XCTAssertEqual(sum, 100, accuracy: 0.01)
    }

    // MARK: - Signal-level

    func testLowDeepDropsArchitectureAndFlags() {
        // deep 30 vs baseline 90 → ratio 0.33 → deep sub 40.
        let segs = cleanStaged(deep: 30, rem: 110, core: 340, from: base)
        let r = eval(stagedHistory(today: todayPoint()), segs)
        XCTAssertLessThan(sub(r, .architecture).score, 80)
        XCTAssertTrue(r.flags.contains("Low deep sleep"))
    }

    func testShortDurationFlagsShortVsNeed() {
        // asleep 5.5h vs need 8h.
        let r = eval(stagedHistory(today: todayPoint(sleep: 5.5, inBed: 6.0)),
                     cleanStaged(core: 40, from: base.addingTimeInterval(0)))
        XCTAssertLessThan(sub(r, .duration).score, 70)
        XCTAssertTrue(r.flags.contains("Short vs need"))
    }

    func testLowEfficiencyFlags() {
        // 6h asleep with 2h WASO in the middle → SPT 8h → efficiency 0.75.
        let wasoNight: [SleepSegment] = [
            seg(.core, 0, 240, from: base),
            seg(.awake, 240, 360, from: base),   // 2h wake-after-sleep-onset (inside SPT)
            seg(.core, 360, 480, from: base)
        ]
        let r = eval(stagedHistory(today: todayPoint(sleep: 6.0, inBed: 8.0)), wasoNight)
        XCTAssertLessThan(sub(r, .efficiency).score, 70)
        XCTAssertTrue(r.flags.contains("Low efficiency"))
    }

    // MARK: - Couch-sleep double-penalty (reconstruction of the reported 22:05 night)

    func testPreOnsetAwakeIsLatencyNotEfficiencyPenalty() {
        // Reconstruct: 66-min awake at 22:05, then ~7.2h consolidated sleep, no mid-sleep WASO.
        let bed = d(27, 22, 5)
        let segs: [SleepSegment] = [
            seg(.awake, 0, 66, from: bed),       // pre-onset couch awake (22:05–23:11)
            seg(.core, 66, 246, from: bed),
            seg(.deep, 246, 336, from: bed),
            seg(.rem, 336, 466, from: bed),
            seg(.core, 466, 497, from: bed)      // asleep = 431min, SPT = 66→497 = 431min
        ]
        let today = DailyHealthPoint(
            dayISO: "2026-05-28",
            sleepHours: 431.0 / 60.0,
            sleepInBedHours: 497.0 / 60.0,       // in-bed includes the 66-min couch block
            sleepWindowStart: bed,
            sleepWindowEnd: bed.addingTimeInterval(497 * 60)
        )
        let r = eval((1...27).map { stagedPoint(day: $0) } + [today], segs)

        // SPT efficiency excludes the pre-onset block (asleep/SPT = 431/431 ≈ 1.0)…
        XCTAssertGreaterThan(r.inputs.efficiency, 0.95)
        XCTAssertFalse(r.flags.contains("Low efficiency"))
        // …and the block is captured ONCE, as latency.
        XCTAssertGreaterThan(r.inputs.onsetLatencyMinutes, 60)

        // Prove the removed double-penalty: the old in-bed denominator was materially lower.
        let oldInBedEff = (431.0 / 60.0) / (497.0 / 60.0)
        XCTAssertLessThan(oldInBedEff, 0.90)
        XCTAssertGreaterThan(r.inputs.efficiency, oldInBedEff)
    }

    func testSubThresholdBlipIsNotAnAwakening() {
        // One real 20-min bout + one 2-min micro-arousal. Only the 20-min counts.
        var segs: [SleepSegment] = []
        segs.append(seg(.core, 0, 120, from: base))
        segs.append(seg(.awake, 120, 122, from: base))   // 2-min blip — must be dropped
        segs.append(seg(.core, 122, 240, from: base))
        segs.append(seg(.awake, 240, 260, from: base))   // 20-min real awakening
        segs.append(seg(.rem, 260, 480, from: base))
        let r = eval(stagedHistory(today: todayPoint()), segs)
        XCTAssertEqual(r.inputs.wakeBoutCount, 1, "2-min blip must not count as a bout")
    }

    func testInconsistentScheduleFlags() {
        // Baseline swings bed/wake ±3h → large midpoint SD.
        var hist: [DailyHealthPoint] = (1...27).map { day -> DailyHealthPoint in
            let shift = (day % 2 == 0) ? 3 : -3
            var p = stagedPoint(day: day)
            p.sleepWindowStart = d(day - 1, 23 + shift)
            p.sleepWindowEnd = d(day, 7 + shift)
            return p
        }
        hist.append(todayPoint())
        let r = eval(hist, cleanStaged(from: base))
        XCTAssertLessThan(sub(r, .consistency).score, 80)
        XCTAssertTrue(r.flags.contains("Inconsistent schedule"))
    }

    // MARK: - Composite / renormalization

    func testUnstagedNightRenormalizesToThreeAxes() {
        // Unstaged today, but history has window bounds → consistency survives.
        let segs = [seg(.unspecified, 0, 480, from: base)]
        let r = eval(stagedHistory(today: todayPoint()), segs)

        XCTAssertFalse(sub(r, .architecture).available)
        XCTAssertFalse(sub(r, .fragmentation).available)
        XCTAssertEqual(sub(r, .architecture).effectiveWeight, 0, accuracy: 0.001)

        XCTAssertEqual(sub(r, .duration).effectiveWeight, 25.0 / 58.0 * 100, accuracy: 0.1)
        XCTAssertEqual(sub(r, .efficiency).effectiveWeight, 20.0 / 58.0 * 100, accuracy: 0.1)
        XCTAssertEqual(sub(r, .consistency).effectiveWeight, 13.0 / 58.0 * 100, accuracy: 0.1)

        let sum = r.subScores.filter { $0.available }.reduce(0.0) { $0 + $1.effectiveWeight }
        XCTAssertEqual(sum, 100, accuracy: 0.01)
    }

    // MARK: - Renorm floor guard

    func testMaximalDropReturnsUnavailable() {
        // Unstaged today + plain history (no window bounds) → only duration + efficiency
        // survive (2 axes, weight 45) → below the floor → .unavailable, not a number.
        let hist = (1...27).map { plainPoint(day: $0) } + [todayPoint()]
        let segs = [seg(.unspecified, 0, 480, from: base)]
        let r = eval(hist, segs)
        XCTAssertEqual(r, .unavailable)
        XCTAssertTrue(r.availableAxes.isEmpty)
    }

    // MARK: - Orthogonality (both directions)

    func testOrthogonality_sameWASO_diffPattern() {
        // 2a: 1×90-min wake vs 18×5-min wakes. Same asleep/in-bed → efficiency identical.
        let oneBlock: [SleepSegment] = [
            seg(.core, 0, 120, from: base),
            seg(.awake, 120, 210, from: base),   // single 90-min block
            seg(.core, 210, 480, from: base)
        ]
        var manyBlocks: [SleepSegment] = [seg(.core, 0, 30, from: base)]
        var t = 30.0
        for _ in 0..<18 {                        // 18 × (5-min awake + 5-min sleep) = 90 WASO
            manyBlocks.append(seg(.awake, t, t + 5, from: base)); t += 5
            manyBlocks.append(seg(.core, t, t + 5, from: base)); t += 5
        }
        manyBlocks.append(seg(.core, t, 480, from: base))

        let r1 = eval(stagedHistory(today: todayPoint()), oneBlock)
        let r2 = eval(stagedHistory(today: todayPoint()), manyBlocks)

        XCTAssertEqual(sub(r1, .efficiency).score, sub(r2, .efficiency).score,
                       "Same asleep/in-bed ⇒ identical efficiency")
        XCTAssertGreaterThan(sub(r1, .fragmentation).score, sub(r2, .fragmentation).score,
                             "1 bout must fragment better than 18 bouts")
        XCTAssertEqual(r1.inputs.wakeBoutCount, 1)
        XCTAssertEqual(r2.inputs.wakeBoutCount, 18)
    }

    func testOrthogonality_sameCount_diffWASO() {
        // 2b twin: same 3 bouts, different total WASO. Efficiency diverges (via in-bed
        // scalar), fragmentation identical (same count + same sleep-block layout).
        func threeBouts(awakeLen: Double, from base: Date) -> [SleepSegment] {
            var segs: [SleepSegment] = []
            var t = 0.0
            func sleep(_ dur: Double) { segs.append(seg(.core, t, t + dur, from: base)); t += dur }
            func wake(_ dur: Double) { segs.append(seg(.awake, t, t + dur, from: base)); t += dur }
            sleep(100); wake(awakeLen); sleep(100); wake(awakeLen); sleep(100); wake(awakeLen); sleep(80)
            return segs
        }
        // Same asleep (380 min), same bout count/layout — only WASO differs, so only the SPT
        // denominator (hence efficiency) moves; fragmentation must not.
        let sleepH = 380.0 / 60.0
        let rLow = eval(stagedHistory(today: todayPoint(sleep: sleepH, inBed: 8.0)),
                        threeBouts(awakeLen: 7, from: base))       // SPT ≈ 401 min
        let rHigh = eval(stagedHistory(today: todayPoint(sleep: sleepH, inBed: 8.0)),
                         threeBouts(awakeLen: 60, from: base))     // SPT ≈ 560 min

        XCTAssertEqual(rLow.inputs.wakeBoutCount, 3)
        XCTAssertEqual(rHigh.inputs.wakeBoutCount, 3)
        XCTAssertEqual(sub(rLow, .fragmentation).score, sub(rHigh, .fragmentation).score,
                       "Same bout count + block layout ⇒ identical fragmentation")
        XCTAssertGreaterThan(sub(rLow, .efficiency).score, sub(rHigh, .efficiency).score,
                             "More total WASO ⇒ worse efficiency (via SPT denominator)")
    }

    // MARK: - Invariance: fragmentation ignores stored-but-unscored awake magnitude

    func testFragmentationInvariantToInterspersedAwakeMinutes() {
        func twoBouts(awakeLen: Double, from base: Date) -> [SleepSegment] {
            var segs: [SleepSegment] = []
            var t = 0.0
            func sleep(_ dur: Double) { segs.append(seg(.core, t, t + dur, from: base)); t += dur }
            func wake(_ dur: Double) { segs.append(seg(.awake, t, t + dur, from: base)); t += dur }
            sleep(150); wake(awakeLen); sleep(150); wake(awakeLen); sleep(150)
            return segs
        }
        let rA = eval(stagedHistory(today: todayPoint()), twoBouts(awakeLen: 6, from: base))
        let rB = eval(stagedHistory(today: todayPoint()), twoBouts(awakeLen: 40, from: base))

        XCTAssertNotEqual(rA.inputs.interspersedAwakeMinutes, rB.inputs.interspersedAwakeMinutes,
                          "Stored awake magnitude must actually differ")
        XCTAssertEqual(sub(rA, .fragmentation).score, sub(rB, .fragmentation).score,
                       "Fragmentation must not move when only awake magnitude changes")
    }

    // MARK: - Core-only night

    func testCoreOnlyNightDegradesGracefully() {
        let segs = [seg(.core, 0, 480, from: base)]   // core only: deep 0, REM 0
        let r = eval(stagedHistory(today: todayPoint()), segs)

        let arch = sub(r, .architecture)
        XCTAssertTrue(arch.available, "Core-only night must keep architecture available")
        XCTAssertFalse(r.flags.contains("Low deep sleep"), "Must NOT emit a no-deep verdict")
        XCTAssertTrue(r.flags.contains("Limited stage detail"))
        XCTAssertTrue(r.availableAxes.contains(.architecture))
        XCTAssertTrue(r.message.lowercased().contains("core"))
        XCTAssertFalse(r.message.lowercased().contains("no deep"))
    }

    // MARK: - Messaging consistency

    func testMessageOnlyNamesAvailableAxes() {
        // Unstaged night: architecture + fragmentation dropped. Message must never name them.
        let segs = [seg(.unspecified, 0, 480, from: base)]
        let r = eval(stagedHistory(today: todayPoint(sleep: 5.0, inBed: 8.0)), segs)
        let m = r.message.lowercased()
        // A "not scored" disclaimer may name them; a DRIVER claim ("held back by …") must not.
        XCTAssertFalse(m.contains("by architecture"), "Unavailable axis must never be a named driver")
        XCTAssertFalse(m.contains("by fragmentation"), "Unavailable axis must never be a named driver")
    }

    func testMessageVerdictMatchesComposite() {
        let r = eval(stagedHistory(today: todayPoint()), cleanStaged(from: base))
        XCTAssertTrue(r.message.hasPrefix(r.verdict.title),
                      "Message must open with the same verdict the composite banded to")
    }

    func testWeakAxisSurfacesInMessage() {
        // Force a weak-but-available duration axis.
        let r = eval(stagedHistory(today: todayPoint(sleep: 5.0, inBed: 5.4)),
                     cleanStaged(core: 20, from: base))
        XCTAssertTrue(sub(r, .duration).score < 70)
        XCTAssertTrue(r.message.lowercased().contains("duration"),
                      "A weak available axis should be named in the message")
    }

    // MARK: - Duration monotonicity (inversion bug-check)

    func testDurationMonotonicHighForAtNeedLowForShort() {
        // Closes the "is the sign an inversion bug?" branch: a long at-need night must score
        // HIGH and a short night LOW on the duration axis. Same staged history (need ≈ 8h).
        let atNeed = eval(stagedHistory(today: todayPoint(sleep: 8.0, inBed: 8.7)), cleanStaged(from: base))
        let short  = eval(stagedHistory(today: todayPoint(sleep: 5.5, inBed: 6.0)), cleanStaged(from: base))

        XCTAssertGreaterThanOrEqual(sub(atNeed, .duration).score, 88, "At-need night scores HIGH")
        XCTAssertLessThan(sub(short, .duration).score, 70, "Short night scores LOW")
        XCTAssertGreaterThan(sub(atNeed, .duration).score, sub(short, .duration).score,
                             "Duration must be monotone: more sleep vs need ⇒ higher score (no inversion)")
    }

    // MARK: - Matured flag (warm-up exclusion)

    func testMaturedTrueOnRichStagedNight() {
        // 27 staged baseline nights → architecture on personal baseline; all axes present.
        let r = eval(stagedHistory(today: todayPoint()), cleanStaged(from: base))
        XCTAssertEqual(r.availableAxes.count, 5)
        XCTAssertTrue(r.matured, "Full staged history + all axes ⇒ matured")
    }

    func testMaturedFalseOnThinBaseline() {
        // Only 3 staged baseline nights (< minStagedBaselineNights) → architecture falls back
        // to reference proportions → not the production estimator → not matured.
        let hist = [stagedPoint(day: 25), stagedPoint(day: 26), stagedPoint(day: 27), todayPoint()]
        let r = eval(hist, cleanStaged(from: base))
        XCTAssertNotEqual(r, .unavailable, "Should still produce a composite")
        XCTAssertFalse(r.matured, "Reference-scored architecture must not be matured")
    }

    func testMaturedFalseWhenAxisDropped() {
        // Unstaged night → architecture + fragmentation drop → fewer than 5 axes → not matured.
        let segs = [seg(.unspecified, 0, 480, from: base)]
        let r = eval(stagedHistory(today: todayPoint()), segs)
        XCTAssertNotEqual(r, .unavailable)
        XCTAssertLessThan(r.availableAxes.count, 5)
        XCTAssertFalse(r.matured)
    }

    func testMaturedFalseOnCoreOnlyNight() {
        let segs = [seg(.core, 0, 480, from: base)]
        let r = eval(stagedHistory(today: todayPoint()), segs)
        XCTAssertTrue(sub(r, .architecture).available)
        XCTAssertFalse(r.matured, "Core-only architecture is neutral, not personal-baseline ⇒ not matured")
    }
}
