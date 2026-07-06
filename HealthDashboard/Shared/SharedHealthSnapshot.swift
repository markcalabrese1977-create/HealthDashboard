import Foundation
import os

// MARK: - Current Snapshot (what widget shows prominently)

struct SharedHealthSnapshot: Codable, Equatable {
    var restingHR: Int
    var hrv: Int
    var sleepHours: Double              // asleep hours (recovery signal)
    var sleepInBedHours: Double         // in-bed / sleep window estimate (sanity check)
    var updatedAt: Date

    // Today so far (load)
    var stepsToday: Int
    var activeEnergyTodayKcal: Int
    var exerciseMinutesToday: Int
    var standHoursToday: Double
    var workoutCountToday: Int
}

// MARK: - Sleep stage segments (relocated from HealthKitManager in Phase 2)
//
// Threaded through the TRANSIENT scoring path only — computed for the night(s)
// SleepQualityEngine scores in a given run, passed in, then discarded. They are
// deliberately NOT stored on DailyHealthPoint: every baseline-relative axis needs
// only the persisted per-stage scalars over the window, and putting segments on the
// 28-day history would bloat every WatchPayload.applicationContext push (size-capped
// tunnel). RAW as delivered by the extractor — SleepQualityEngine owns smoothing.

enum SleepStage: String, Codable, Equatable {
    case deep
    case rem
    case core
    case unspecified   // asleepUnspecified (iOS 16+) or legacy .asleep
    case awake
}

struct SleepSegment: Codable, Equatable {
    let stage: SleepStage
    let start: Date
    let end: Date
}

// MARK: - History (for trends + readiness)
// NOTE: UI can display last 7; storage/engine can use 28+.

struct DailyHealthPoint: Codable, Equatable, Identifiable {
    var id: String { dayISO }           // e.g. "2026-01-21"
    let dayISO: String

    // Physiology
    var restingHR: Double?              // bpm — PRIMARY signal (sleep-window RHR, falls back to Apple's restingHeartRate)
    var sleepWindowRHR: Double?          // computed from raw HR samples during verified sleepAnalysis "asleep" windows — same value feeding restingHR, kept for reference
    var appleRestingHR: Double?           // Apple's raw restingHeartRate — comparison field only, no longer the primary signal
    var hrvMS: Double?                  // milliseconds — PRIMARY signal (sleep-window HRV, falls back to Apple's heartRateVariabilitySDNN)
    var sleepWindowHRV: Double?          // computed from raw SDNN samples during verified sleepAnalysis "asleep" windows — comparison field vs. Apple's heartRateVariabilitySDNN
    var sleepHours: Double?             // hours asleep
    var sleepInBedHours: Double?        // in-bed / sleep window estimate
    var respiratoryRate: Double?        // breaths/min (sleep)
    var spo2Pct: Double?                // 0–100

    // Sleep architecture scalars (Phase 2 — derived from SleepDayBreakdown, persisted
    // across all 28 days for baseline-relative sub-scoring). Additive optionals: the
    // synthesized decoder fills them nil for history written before this schema, so no
    // migration is needed. Raw segments are intentionally NOT persisted here (see
    // SleepSegment note) — a non-staged night reads all-nil / zero stage minutes, and
    // "was this night staged?" is inferred as (deep+rem+core) > 0, not a stored flag.
    var sleepDeepMinutes: Double?       // merged minutes in asleepDeep
    var sleepREMMinutes: Double?        // merged minutes in asleepREM
    var sleepCoreMinutes: Double?       // merged minutes in asleepCore
    var sleepUnspecifiedMinutes: Double? // merged minutes in asleepUnspecified / legacy asleep
    var sleepAwakeMinutes: Double?      // merged minutes flagged awake within the window
    var sleepWindowStart: Date?         // earliest sleep-window start (bedtime) — latency + consistency
    var sleepWindowEnd: Date?           // latest sleep-window end (wake) — consistency
    var sleepPeriodMinutes: Double?     // first asleep → last asleep — the efficiency denominator (SPT)

    // Sleep Quality composite (0–100) for this night, backfilled across the window each
    // fetch (SleepQualityEngine scored with an expanding prior-only baseline). Additive
    // optional — nil for pre-backfill history or nights the engine returns .unavailable.
    // Rides the Watch payload (one Double, negligible) and restores the sparkline. Per-axis
    // sub-scores are NOT here — they live in SharedStore's sleep-axis side log to keep the
    // Watch-bound blob lean (same split rationale as raw segments).
    var sleepCompositeScore: Double?

    // Wrist Temperature (sleeping; Apple Watch)
    // Apple's appleSleepingWristTemperature delivers a value already expressed as a
    // deviation from the user's personal baseline (typically ±1–2 °C), not absolute
    // skin temperature. The field name is correct; tempBase in ReadinessEngine is the
    // median of these stored deltas (≈ 0 for a well-calibrated baseline), and the
    // engine computes d = cur − tempBase to capture drift from that personal center.
    var wristTempDeltaC: Double?        // °C deviation from Apple's personal baseline

    // Load / activity
    var steps: Double?                  // count
    var activeEnergyKcal: Double?       // kcal
    var exerciseMinutes: Double?        // minutes
    var standHours: Double?             // hours

    // Workouts
    var workoutCount: Double?           // count
        var workoutMinutes: Double?         // minutes
        var workoutEnergyKcal: Double?      // kcal
        var workoutAvgHR: Double?           // average HR across workouts (bpm)
    var dailyTrimp: Double?             // Bannister TRIMP training stress score
        var mechanicalLoad: Double?         // ElitePerformance intensity-weighted volume score

    // Body composition (smart scale via Apple Health)
    var bodyWeightLb: Double?           // pounds
    var bodyFatPct: Double?             // 0–100
    var leanMassLb: Double?             // pounds (proxy for “muscle mass”)
}

// MARK: - Manual readiness inputs (minimal)

struct ManualReadinessInputs: Codable, Equatable {
    /// 0–10. The only “body reality” input we keep.
    var painLevel: Int

    /// True only when clearly sick/systemic (feverish, aches, chest crud, heavy fatigue).
    var isSick: Bool

    static let `default` = ManualReadinessInputs(
        painLevel: 0,
        isSick: false
    )
}

// MARK: - DXA (manual body comp snapshots)

struct DXAScan: Codable, Equatable, Identifiable {
    /// Stable id for edits/updates. Use scan date (ISO) as identity.
    var id: String { dateISO }
    let dateISO: String   // "yyyy-MM-dd"

    // Scan metadata
    var device: String?
    var heightIn: Double?
    var weightLb: Double?

    // Core totals
    var totalMassLb: Double?
    var leanMassLb: Double?
    var fatMassLb: Double?
    var bodyFatPct: Double?

    // Distribution
    var androidFatPct: Double?
    var gynoidFatPct: Double?
    var androidGynoidRatio: Double?

    // Visceral (VAT)
    var vatVolumeCm3: Double?
    var vatMassLb: Double?
    var vatAreaCm2: Double?

    // Optional
    var rmrKcalPerDay: Int?
    var totalBmd: Double?
    var totalTScore: Double?
}

// MARK: - Manual body measurements (tape)

struct BodyMeasurementEntry: Codable, Equatable, Identifiable {
    /// Stable id for edits/updates. Use date (ISO) as identity.
    var id: String { dateISO }
    let dateISO: String   // "yyyy-MM-dd"

    // Core (highest signal)
    var waistNavelIn: Double?
    var waistNarrowIn: Double?
    var hipIn: Double?

    // Optional limb measurements (lean-retention proxies)
    var upperArmFlexedIn: Double?
    var thighMidIn: Double?

    // Optional notes
    var note: String?
}

// MARK: - Sleep Quality Result (Phase 2 — Option B: intrinsic composite, no autonomic axis)
//
// The composite is a weighted blend of up to five INTRINSIC axes. Autonomic recovery
// is deliberately absent (ReadinessEngine owns HRV/RHR/RR/temp), so this score can feed
// readiness later without double-counting.
//
// Everything the UI and the human message need is stored here as a COMPUTED value —
// nothing downstream re-derives a score or an input. Scalars only (segments never land
// here), so the whole struct rides ReadinessResult → WatchPayload safely.

enum SleepAxis: String, Codable, Equatable {
    case architecture       // per-stage minutes + proportions vs baseline
    case duration           // asleep vs dynamic need
    case efficiency         // efficiency / onset latency / WASO
    case fragmentation      // discrete wake bouts + interspersed awake time
    case consistency        // SD of midpoint / bed / wake over rolling window

    var title: String {
        switch self {
        case .architecture:  return "Architecture"
        case .duration:      return "Duration"
        case .efficiency:    return "Efficiency"
        case .fragmentation: return "Fragmentation"
        case .consistency:   return "Consistency"
        }
    }
}

enum SleepQualityVerdict: String, Codable, Equatable {
    case excellent
    case good
    case fair
    case poor

    var title: String {
        switch self {
        case .excellent: return "Excellent"
        case .good:      return "Good"
        case .fair:      return "Fair"
        case .poor:      return "Poor"
        }
    }
}

/// One axis of the composite. `available == false` means the axis was dropped this
/// night (e.g. architecture/fragmentation on an unstaged night); its `effectiveWeight`
/// is then 0 and it contributes nothing. `effectiveWeight` is the POST-renormalization
/// weight (available weights always sum to ~100), so `score * effectiveWeight` can be
/// summed directly to reproduce the composite with no re-derivation.
struct SleepSubScore: Codable, Equatable {
    let axis: SleepAxis
    let score: Double            // 0–100 for this axis
    let effectiveWeight: Double  // 0–100, renormalized across available axes; 0 when dropped
    let available: Bool
}

/// Raw computed inputs behind each axis. Stored so the UI/message read the same numbers
/// the score was built from, and so baseline-relative axes can later be recomputed from
/// persisted scalars without touching raw segments again.
struct SleepQualityInputs: Codable, Equatable {
    // Architecture (minutes; proportions are score-time derived from these)
    var deepMinutes: Double
    var remMinutes: Double
    var coreMinutes: Double
    var unspecifiedMinutes: Double
    var awakeMinutes: Double
    var totalAsleepMinutes: Double

    // Duration vs dynamic need (hours)
    var sleepHours: Double          // asleep hours scored
    var sleepNeedHours: Double      // dynamic target = baseline + strain + debt − nap
    var baselineNeedHours: Double   // personal baseline component
    var strainAdjustHours: Double   // prior-day TRIMP + mechanical-load add-on
    var sleepDebtHours: Double      // trailing 3–4 night accumulated shortfall
    var napCreditHours: Double      // daytime nap offset

    // Efficiency / latency / WASO
    var efficiency: Double          // 0–1, asleep/inBed
    var onsetLatencyMinutes: Double // window start → first asleep segment
    var wasoMinutes: Double         // wake after sleep onset (total)
    var awakeningCount: Int         // all awakenings (pre min-bout filter)

    // Fragmentation (POST 5-min min-bout smoothing)
    var wakeBoutCount: Int              // discrete awakenings ≥ min-bout
    var interspersedAwakeMinutes: Double // awake time inside counted bouts

    // Consistency (rolling-window SDs; nil when window too short)
    var midpointSDMinutes: Double?
    var bedtimeSDMinutes: Double?
    var wakeSDMinutes: Double?
}

struct SleepQualityResult: Codable, Equatable {
    var composite: Double            // 0–100, weighted over AVAILABLE axes (renormalized)
    var verdict: SleepQualityVerdict // banded from composite (thresholds are engine constants)
    var subScores: [SleepSubScore]   // one per axis; dropped axes carry available=false, weight=0
    var inputs: SleepQualityInputs   // raw computed inputs (no downstream re-derivation)
    var flags: [String]              // short human tags, derived from subScores/inputs

    // False ⇒ no trustworthy staged data this night ⇒ architecture + fragmentation are
    // dropped and the remaining weights renormalized. `availableAxes` records exactly
    // which axes ran so the message never asserts a verdict on an axis that didn't.
    var hasStagedData: Bool
    var availableAxes: [SleepAxis]

    // Warm-up marker for validation. True ONLY when every axis ran AND architecture was
    // scored against the PERSONAL staged baseline (not reference proportions, not the
    // core-only neutral). Early backfilled days fail this — they're scored by a different
    // estimator than production, so the correlation must exclude non-matured days. Emitted
    // by the engine; never reconstructed downstream.
    var matured: Bool

    var message: String              // human verdict; MUST derive only from subScores/inputs
}

extension SleepQualityResult {
    /// Explicit "no scoreable sleep this run" placeholder (no sleep samples, or duration
    /// below the engine's floor). Distinct from `nil` on ReadinessResult, which means the
    /// sleep engine hasn't run yet. All axes unavailable; composite 0.
    static let unavailable = SleepQualityResult(
        composite: 0,
        verdict: .poor,
        subScores: [],
        inputs: SleepQualityInputs(
            deepMinutes: 0, remMinutes: 0, coreMinutes: 0, unspecifiedMinutes: 0,
            awakeMinutes: 0, totalAsleepMinutes: 0,
            sleepHours: 0, sleepNeedHours: 0, baselineNeedHours: 0,
            strainAdjustHours: 0, sleepDebtHours: 0, napCreditHours: 0,
            efficiency: 0, onsetLatencyMinutes: 0, wasoMinutes: 0, awakeningCount: 0,
            wakeBoutCount: 0, interspersedAwakeMinutes: 0,
            midpointSDMinutes: nil, bedtimeSDMinutes: nil, wakeSDMinutes: nil
        ),
        flags: [],
        hasStagedData: false,
        availableAxes: [],
        matured: false,
        message: "No sleep data to score."
    )
}

// MARK: - Sleep-axis diagnostic log (side store, NOT Watch-bound)
//
// Per-day per-axis breakdown persisted to SharedStore only — kept OFF DailyHealthPoint so
// the Watch payload stays lean. Its job: when the composite↔readiness correlation is weak,
// show WHICH axis is responsible. Written in the same backfill pass as sleepCompositeScore.

struct SleepAxisLogRecord: Codable, Equatable {
    let dateISO: String
    let composite: Double
    let matured: Bool
    let availableAxes: [SleepAxis]
    let subScores: [SleepSubScore]
}

// MARK: - Readiness Result

enum ReadinessStatus: String, Codable {
    case green
    case yellow
    case red

    var title: String {
        switch self {
        case .green: return "Green"
        case .yellow: return "Yellow"
        case .red: return "Red"
        }
    }

    var guidance: String {
        switch self {
        case .green: return "Green: train normally"
        case .yellow: return "Yellow: train with guardrails"
        case .red: return "Red: reduce cost today"
        }
    }
}

enum ReadinessConfidence: String, Codable, Equatable {
    case low
    case medium
    case high

    var title: String {
        switch self {
        case .low: return "Low confidence"
        case .medium: return "Medium confidence"
        case .high: return "High confidence"
        }
    }
}

struct ReadinessDriver: Codable, Equatable {
    let label: String
    let impact: Int
    let isNegative: Bool
    let reason: String           // short, signal-naming text (distinct from MetricDetailView's interpretation text)
    let consecutiveDays: Int     // 0 = not an active cluster flag; 1 = first day; 2+ = sustained
}

// MARK: - Verdict History (hysteresis log)

/// One entry per day in the rolling 30-day verdict log.
/// Stores the *raw* computed values before any gating so the gate always
/// looks at underlying scores, not already-filtered output.
///
/// Cluster flags are additive on top of the original (dateISO, rawTotal, rawTruth)
/// schema. Older stored records won't have them — decodeIfPresent defaults to
/// false so existing log entries decode cleanly without migration.
struct DailyVerdictRecord: Codable, Equatable {
    let dateISO: String          // "yyyy-MM-dd"
    let rawTotal: Int            // recoveryScore + loadMod before gating

    // Load-STRIPPED recovery component (recoveryScore, before + loadMod). Logged so the
    // sleep composite can be validated against a target that does NOT already contain the
    // day's load — rawTotal does (via loadMod), which confounds composite↔readiness. Optional
    // + forward-only: nil for records written before this field existed; the validator
    // simply skips those days until enough load-stripped pairs accrue.
    let rawRecovery: Int?

    let rawTruth: ReadinessStatus

    let hrvDown10: Bool
    let hrvDownTrend: Bool
    let hrvConcern: Bool
    let rhrUp4: Bool
    let sleepShort1: Bool
    let tempUp03: Bool
    let rrUp10: Bool
    let sleepEffLow: Bool
    let sick: Bool

    init(
        dateISO: String,
        rawTotal: Int,
        rawRecovery: Int? = nil,
        rawTruth: ReadinessStatus,
        hrvDown10: Bool = false,
        hrvDownTrend: Bool = false,
        hrvConcern: Bool = false,
        rhrUp4: Bool = false,
        sleepShort1: Bool = false,
        tempUp03: Bool = false,
        rrUp10: Bool = false,
        sleepEffLow: Bool = false,
        sick: Bool = false
    ) {
        self.dateISO = dateISO
        self.rawTotal = rawTotal
        self.rawRecovery = rawRecovery
        self.rawTruth = rawTruth
        self.hrvDown10 = hrvDown10
        self.hrvDownTrend = hrvDownTrend
        self.hrvConcern = hrvConcern
        self.rhrUp4 = rhrUp4
        self.sleepShort1 = sleepShort1
        self.tempUp03 = tempUp03
        self.rrUp10 = rrUp10
        self.sleepEffLow = sleepEffLow
        self.sick = sick
    }

    private enum CodingKeys: String, CodingKey {
        case dateISO, rawTotal, rawRecovery, rawTruth
        case hrvDown10, hrvDownTrend, hrvConcern, rhrUp4, sleepShort1, tempUp03, rrUp10, sleepEffLow, sick
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dateISO = try c.decode(String.self, forKey: .dateISO)
        rawTotal = try c.decode(Int.self, forKey: .rawTotal)
        rawRecovery = try c.decodeIfPresent(Int.self, forKey: .rawRecovery)   // nil for pre-schema records
        rawTruth = try c.decode(ReadinessStatus.self, forKey: .rawTruth)

        // Additive fields: default to false for log entries written before this schema change.
        hrvDown10 = try c.decodeIfPresent(Bool.self, forKey: .hrvDown10) ?? false
        hrvDownTrend = try c.decodeIfPresent(Bool.self, forKey: .hrvDownTrend) ?? false
        hrvConcern = try c.decodeIfPresent(Bool.self, forKey: .hrvConcern) ?? false
        rhrUp4 = try c.decodeIfPresent(Bool.self, forKey: .rhrUp4) ?? false
        sleepShort1 = try c.decodeIfPresent(Bool.self, forKey: .sleepShort1) ?? false
        tempUp03 = try c.decodeIfPresent(Bool.self, forKey: .tempUp03) ?? false
        rrUp10 = try c.decodeIfPresent(Bool.self, forKey: .rrUp10) ?? false
        sleepEffLow = try c.decodeIfPresent(Bool.self, forKey: .sleepEffLow) ?? false
        sick = try c.decodeIfPresent(Bool.self, forKey: .sick) ?? false
    }
}

// MARK: - Gate-hold / load-caution copy (single source across surfaces)
//
// Hysteresis "Option A" holds a raw-green day at an amber DISPLAY for one-day confirmation.
// On such a day `action` reads green (recommendation) while `truth` reads amber (badge).
// These strings narrate that split and are authored ONCE here so both the engine-baked
// actionTitle/actionMessage (which WatchRootView reads directly) and the card presentation
// render identical copy. Worded to read gracefully on a cold start (absent yesterday) too:
// never implies recovery is provisional or suppressed when history is merely new.
enum ReadinessHoldCopy {
    static let title = "Recovery looks good — confirming"
    static let subline = "Confirming before clearing"
    static let message = "Recovery is green today. We’re confirming it with another day of data before clearing the badge to green — train normally and keep it clean, no extra cost or hero sets."
}

// Yellow driven purely by training/activity LOAD (no negative recovery drivers). Attributes
// the caution to load, not to recovery signals — the count==0 case the old
// `count==1 ? isolated : cluster` ternary used to misroute into the recovery-cluster copy.
enum ReadinessLoadCopy {
    static let subline = "Load is elevated"
    static let explanation = "Recovery signals look fine — today’s training and activity load is what’s pulling readiness down. Run a controlled session and avoid stacking more cost on top."
}

struct ReadinessResult: Codable, Equatable {
    var truth: ReadinessStatus          // gated/displayed truth color
    var rawTruth: ReadinessStatus       // raw computed truth (before hysteresis gate)
    var action: ReadinessStatus         // what we recommend doing today (may be softened)
    var confidence: ReadinessConfidence
    var flags: [String]                 // top drivers
    var drivers: [ReadinessDriver]
    var actionTitle: String
    var actionMessage: String
    var canPushKeyLift: Bool            // general "push permission"
    var rhrDelta: Double?               // today - baseline bpm
    var hrvDelta: Double?               // today - baseline ms
    var sleepDelta: Double?             // today - sleepTarget hours
    var tempDelta: Double?              // today - baseline °C
    var rrDelta: Double?                // today - baseline br/min
    var effDelta: Double?               // today - baseline efficiency (0–1 scale)
    var cardioLoad: Double              // TRIMP (Bannister formula)
    var mechanicalLoad: Double          // EP intensity-weighted volume (UserDefaults shared store)
    // Additive, display-only: the engine already computes this internally (recoveryScore +
    // loadMod) but previously didn't return it. Exposes the existing value for the Watch
    // verdict ring / complication ("+1", "-3") — does not change how it's computed.
    var totalScore: Int = 0

    // Sleep composite (Phase 2). Computed by SleepQualityEngine, not ReadinessEngine, and
    // assigned into the result by the pipeline (Phase 5) — same reason totalScore carries a
    // default: ReadinessEngine.evaluate() and `.empty` construct ReadinessResult without it.
    //   nil          = sleep engine hasn't run yet this session
    //   .unavailable = it ran but had no scoreable sleep
    // Scalars only, so it rides WatchPayload with no size regression.
    var sleepQuality: SleepQualityResult? = nil
}
extension ReadinessResult {
    /// Inert placeholder shown only for the instant between view creation and the
    /// first explicit ReadinessEngine.evaluate() call (onAppear with cached history).
    /// Deliberately does NOT call evaluate() — see ContentView's `readiness` @State var.
    static let empty = ReadinessResult(
        truth: .yellow,
        rawTruth: .yellow,
        action: .yellow,
        confidence: .low,
        flags: [],
        drivers: [],
        actionTitle: "",
        actionMessage: "",
        canPushKeyLift: false,
        rhrDelta: nil,
        hrvDelta: nil,
        sleepDelta: nil,
        tempDelta: nil,
        rrDelta: nil,
        effDelta: nil,
        cardioLoad: 0,
        mechanicalLoad: 0
    )

    var driverSummary: String {
        if drivers.isEmpty {
            return "No meaningful deviations"
        }

        let negatives = drivers.filter { $0.isNegative }

        if negatives.count >= 2 {
            return negatives
                .map { "\($0.label) ↓" }
                .joined(separator: ", ")
        }

        if negatives.count == 1, let d = negatives.first {
            return "\(d.label) ↓ (isolated)"
        }

        return drivers
            .map { "\($0.label) \($0.isNegative ? "↓" : "↑")" }
            .joined(separator: ", ")
    }
    var explanationSummary: String {
        if drivers.isEmpty {
            return "No major recovery concerns detected."
        }

        let negativeDrivers = drivers.filter { $0.isNegative }

        if negativeDrivers.count >= 2 {
            return "Multiple recovery signals are outside their normal range."
        }

        if negativeDrivers.contains(where: { $0.label == "HRV" }) {
            return "HRV is down, but the overall readiness decision accounts for the full recovery picture."
        }

        return "Readiness is being shaped by \(driverSummary)."
    }
}
// MARK: - App Group Store + Debug Hooks

enum SharedStore {
    static let appGroupID = "group.com.calabrese.healthdashboard"   // must match App Group in BOTH targets

    // Snapshot
    static let snapshotKey = "health.snapshot.v2"

    // History (28d preferred; fallback to legacy 7d key)
    static let historyKey7  = "health.history.7d.v1"     // legacy
    static let historyKey28 = "health.history.28d.v1"    // current

    // Manual
    static let manualKey = "health.readiness.manual.v3"

    // Body comp
    static let dxaKey = "health.bodycomp.dxa.scans.v1"
    static let measurementsKey = "health.bodycomp.measurements.v1"

    // Verdict history (hysteresis gate)
    static let verdictLogKey = "health.readiness.verdictLog.v1"
    private static let verdictLogMaxDays = 30

    // Sleep-axis diagnostic log (side store for validation; not Watch-bound)
    static let sleepAxisLogKey = "health.sleep.axisLog.v1"
    private static let sleepAxisLogMaxDays = 30

    // Signal cutover (one-time baseline reset when a primary signal source changes —
    // e.g. RHR/HRV moving from Apple's all-day algorithms to sleep-window-derived values).
    static let signalCutoverVersionKey = "health.signal.version.v1"
    static let currentSignalVersion = 1

    static let debugEnabled: Bool = true
    private static let logger = Logger(subsystem: "com.calabrese.HealthDashboard", category: "SharedStore")

    private static func log(_ message: String) {
        guard debugEnabled else { return }
        logger.log("\(message, privacy: .public)")
    }

    private static func defaults() -> UserDefaults? {
        let d = UserDefaults(suiteName: appGroupID)
        if d == nil {
            log("❌ UserDefaults(suiteName:) returned nil for appGroupID=\(appGroupID)")
        }
        return d
    }

    static func checkAppGroupAccess(tag: String = "") -> Bool {
        let ok = (UserDefaults(suiteName: appGroupID) != nil)
        log("🔎 checkAppGroupAccess \(tag.isEmpty ? "" : "[\(tag)]") -> \(ok ? "OK" : "FAIL")")
        return ok
    }

    // MARK: Snapshot

    static func load() -> SharedHealthSnapshot {
        guard
            let d = defaults(),
            let data = d.data(forKey: snapshotKey),
            let decoded = try? JSONDecoder().decode(SharedHealthSnapshot.self, from: data)
        else {
            log("📥 load(snapshot) -> default (no data yet)")
            return SharedHealthSnapshot(
                restingHR: 65,
                hrv: 25,
                sleepHours: 8.9,
                sleepInBedHours: 0,
                updatedAt: .distantPast,
                stepsToday: 0,
                activeEnergyTodayKcal: 0,
                exerciseMinutesToday: 0,
                standHoursToday: 0,
                workoutCountToday: 0
            )
        }

        log("📥 load(snapshot) -> RHR=\(decoded.restingHR) HRV=\(decoded.hrv) Sleep=\(String(format: "%.1f", decoded.sleepHours)) InBed=\(String(format: "%.1f", decoded.sleepInBedHours)) updatedAt=\(decoded.updatedAt)")
        return decoded
    }

    static func save(_ snapshot: SharedHealthSnapshot) {
        guard let d = defaults() else { return }

        if let data = try? JSONEncoder().encode(snapshot) {
            d.set(data, forKey: snapshotKey)
            log("📤 save(snapshot) -> RHR=\(snapshot.restingHR) HRV=\(snapshot.hrv) Sleep=\(String(format: "%.1f", snapshot.sleepHours)) InBed=\(String(format: "%.1f", snapshot.sleepInBedHours)) updatedAt=\(snapshot.updatedAt)")
        } else {
            log("❌ save(snapshot) encode failed")
        }
    }

    // MARK: History

    static func loadHistory() -> [DailyHealthPoint] {
        guard let d = defaults() else {
            log("📥 load(history) -> [] (no data yet)")
            return []
        }

        // Prefer 28d storage; fallback to legacy 7d key
        let data28 = d.data(forKey: historyKey28)
        let data7  = d.data(forKey: historyKey7)

        if let data = data28, let decoded = try? JSONDecoder().decode([DailyHealthPoint].self, from: data) {
            let first = decoded.first?.dayISO ?? "nil"
            let last  = decoded.last?.dayISO ?? "nil"
            log("📥 load(history28) -> count=\(decoded.count) range=\(first)...\(last)")
            return decoded
        }

        if let data = data7, let decoded = try? JSONDecoder().decode([DailyHealthPoint].self, from: data) {
            let first = decoded.first?.dayISO ?? "nil"
            let last  = decoded.last?.dayISO ?? "nil"
            log("📥 load(history7) -> count=\(decoded.count) range=\(first)...\(last)")
            return decoded
        }

        log("📥 load(history) -> [] (no data yet)")
        return []
    }

    static func saveHistory(_ history: [DailyHealthPoint]) {
        guard let d = defaults() else { return }

        if let data = try? JSONEncoder().encode(history) {
            d.set(data, forKey: historyKey28)
            let first = history.first?.dayISO ?? "nil"
            let last  = history.last?.dayISO ?? "nil"
            log("📤 save(history28) -> count=\(history.count) range=\(first)...\(last)")
        } else {
            log("❌ save(history) encode failed")
        }
    }

    // MARK: Signal Cutover (one-time baseline reset)

    /// Checks whether the stored signal version matches `currentSignalVersion`. If not,
    /// the existing 28-day history is contaminated by the old signal source and is cleared
    /// so the baseline rebuilds from clean data. Idempotent — once the version is bumped,
    /// subsequent calls are a no-op until `currentSignalVersion` changes again.
    static func performSignalCutoverIfNeeded() {
        guard let d = defaults() else { return }

        let storedVersion = d.integer(forKey: signalCutoverVersionKey)
        guard storedVersion != currentSignalVersion else { return }

        d.removeObject(forKey: historyKey28)
        d.set(currentSignalVersion, forKey: signalCutoverVersionKey)

        log("🔄 Signal cutover: cleared contaminated history, baseline will rebuild over 28 days")
    }

    // MARK: Manual

    static func loadManual() -> ManualReadinessInputs {
        guard
            let d = defaults(),
            let data = d.data(forKey: manualKey),
            let decoded = try? JSONDecoder().decode(ManualReadinessInputs.self, from: data)
        else {
            log("📥 load(manual) -> default")
            return .default
        }

        log("📥 load(manual) -> pain=\(decoded.painLevel) sick=\(decoded.isSick)")
        return decoded
    }

    static func saveManual(_ manual: ManualReadinessInputs) {
        guard let d = defaults() else { return }

        if let data = try? JSONEncoder().encode(manual) {
            d.set(data, forKey: manualKey)
            log("📤 save(manual) -> pain=\(manual.painLevel) sick=\(manual.isSick)")
        } else {
            log("❌ save(manual) encode failed")
        }
    }

    // MARK: DXA

    static func loadDXAScans() -> [DXAScan] {
        guard
            let d = defaults(),
            let data = d.data(forKey: dxaKey),
            let decoded = try? JSONDecoder().decode([DXAScan].self, from: data)
        else {
            log("📥 load(dxa) -> [] (no data yet)")
            return []
        }

        let first = decoded.first?.dateISO ?? "nil"
        let last  = decoded.last?.dateISO ?? "nil"
        log("📥 load(dxa) -> count=\(decoded.count) range=\(first)...\(last)")
        return decoded
    }

    static func saveDXAScans(_ scans: [DXAScan]) {
        guard let d = defaults() else { return }

        if let data = try? JSONEncoder().encode(scans) {
            d.set(data, forKey: dxaKey)
            let first = scans.first?.dateISO ?? "nil"
            let last  = scans.last?.dateISO ?? "nil"
            log("📤 save(dxa) -> count=\(scans.count) range=\(first)...\(last)")
        } else {
            log("❌ save(dxa) encode failed")
        }
    }

    static func upsertDXAScan(_ scan: DXAScan) {
        var scans = loadDXAScans()
        if let idx = scans.firstIndex(where: { $0.dateISO == scan.dateISO }) {
            scans[idx] = scan
        } else {
            scans.append(scan)
        }
        scans.sort { $0.dateISO < $1.dateISO }
        saveDXAScans(scans)
    }

    static func deleteDXAScan(dateISO: String) {
        var scans = loadDXAScans()
        scans.removeAll(where: { $0.dateISO == dateISO })
        saveDXAScans(scans)
    }

    // MARK: Body Measurements

    static func loadBodyMeasurements() -> [BodyMeasurementEntry] {
        guard
            let d = defaults(),
            let data = d.data(forKey: measurementsKey),
            let decoded = try? JSONDecoder().decode([BodyMeasurementEntry].self, from: data)
        else {
            log("📥 load(measurements) -> [] (no data yet)")
            return []
        }

        let first = decoded.first?.dateISO ?? "nil"
        let last  = decoded.last?.dateISO ?? "nil"
        log("📥 load(measurements) -> count=\(decoded.count) range=\(first)...\(last)")
        return decoded
    }

    static func saveBodyMeasurements(_ entries: [BodyMeasurementEntry]) {
        guard let d = defaults() else { return }

        if let data = try? JSONEncoder().encode(entries) {
            d.set(data, forKey: measurementsKey)
            let first = entries.first?.dateISO ?? "nil"
            let last  = entries.last?.dateISO ?? "nil"
            log("📤 save(measurements) -> count=\(entries.count) range=\(first)...\(last)")
        } else {
            log("❌ save(measurements) encode failed")
        }
    }

    static func upsertBodyMeasurement(_ entry: BodyMeasurementEntry) {
        var entries = loadBodyMeasurements()
        if let idx = entries.firstIndex(where: { $0.dateISO == entry.dateISO }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        entries.sort { $0.dateISO < $1.dateISO }
        saveBodyMeasurements(entries)
    }

    static func deleteBodyMeasurement(dateISO: String) {
        var entries = loadBodyMeasurements()
        entries.removeAll(where: { $0.dateISO == dateISO })
        saveBodyMeasurements(entries)
    }

    // MARK: Verdict Log (hysteresis)

    /// Returns the stored log sorted oldest → newest.
    static func loadVerdictLog() -> [DailyVerdictRecord] {
        guard
            let d = defaults(),
            let data = d.data(forKey: verdictLogKey),
            let decoded = try? JSONDecoder().decode([DailyVerdictRecord].self, from: data)
        else {
            log("📥 load(verdictLog) -> [] (no data yet)")
            return []
        }

        log("📥 load(verdictLog) -> count=\(decoded.count) last=\(decoded.last?.dateISO ?? "nil")")
        return decoded
    }

    /// Upserts today's record and trims the log to the most recent 30 days.
    /// Always call with the *raw* computed verdict before the hysteresis gate is applied.
    static func appendVerdictLog(_ record: DailyVerdictRecord) {
        guard let d = defaults() else { return }

        var log_ = loadVerdictLog()

        // Upsert: replace existing entry for the same date, or append.
        if let idx = log_.firstIndex(where: { $0.dateISO == record.dateISO }) {
            log_[idx] = record
        } else {
            log_.append(record)
        }

        // Keep sorted oldest → newest; trim to cap.
        log_.sort { $0.dateISO < $1.dateISO }
        if log_.count > verdictLogMaxDays {
            log_ = Array(log_.suffix(verdictLogMaxDays))
        }

        if let data = try? JSONEncoder().encode(log_) {
            d.set(data, forKey: verdictLogKey)
            log("📤 save(verdictLog) -> count=\(log_.count) today=\(record.dateISO) rawTruth=\(record.rawTruth.rawValue) rawTotal=\(record.rawTotal)")
        } else {
            log("❌ save(verdictLog) encode failed")
        }
    }

    private static let verdictDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Walks backward day-by-day from `dateISO` (inclusive) counting how many
    /// consecutive days the given cluster flag was true. Stops at the first
    /// false or missing day. Returns 0 if `dateISO` itself isn't true.
    static func consecutiveDaysActive(
        flag keyPath: KeyPath<DailyVerdictRecord, Bool>,
        asOf dateISO: String,
        maxLookback: Int = 30
    ) -> Int {
        let byDate = Dictionary(uniqueKeysWithValues: loadVerdictLog().map { ($0.dateISO, $0) })

        guard let today = byDate[dateISO], today[keyPath: keyPath] else { return 0 }
        guard var cursor = verdictDayFormatter.date(from: dateISO) else { return 0 }

        let cal = Calendar.current
        var count = 0

        for _ in 0..<maxLookback {
            let iso = verdictDayFormatter.string(from: cursor)
            guard let record = byDate[iso], record[keyPath: keyPath] else { break }
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }

        log("🔢 consecutiveDaysActive(asOf: \(dateISO)) -> \(count)")
        return count
    }

    // MARK: Sleep-axis diagnostic log

    /// Returns the stored sleep-axis log sorted oldest → newest.
    static func loadSleepAxisLog() -> [SleepAxisLogRecord] {
        guard
            let d = defaults(),
            let data = d.data(forKey: sleepAxisLogKey),
            let decoded = try? JSONDecoder().decode([SleepAxisLogRecord].self, from: data)
        else {
            log("📥 load(sleepAxisLog) -> [] (no data yet)")
            return []
        }
        log("📥 load(sleepAxisLog) -> count=\(decoded.count) last=\(decoded.last?.dateISO ?? "nil")")
        return decoded
    }

    /// Replaces the whole log with `records` (the backfill recomputes every day each run),
    /// sorted oldest → newest and trimmed to the cap.
    static func saveSleepAxisLog(_ records: [SleepAxisLogRecord]) {
        guard let d = defaults() else { return }
        var sorted = records.sorted { $0.dateISO < $1.dateISO }
        if sorted.count > sleepAxisLogMaxDays {
            sorted = Array(sorted.suffix(sleepAxisLogMaxDays))
        }
        if let data = try? JSONEncoder().encode(sorted) {
            d.set(data, forKey: sleepAxisLogKey)
            log("📤 save(sleepAxisLog) -> count=\(sorted.count) last=\(sorted.last?.dateISO ?? "nil")")
        } else {
            log("❌ save(sleepAxisLog) encode failed")
        }
    }

    // MARK: Debug Dump

    static func debugDump(tag: String = "") {
        guard debugEnabled else { return }

        let snap = load()
        let hist = loadHistory()
        let man  = loadManual()

        let first = hist.first?.dayISO ?? "nil"
        let last  = hist.last?.dayISO ?? "nil"

        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        log("🧾 DEBUG DUMP \(tag.isEmpty ? "" : "[\(tag)]")")
        log("AppGroup=\(appGroupID)")
        log("Snapshot: RHR=\(snap.restingHR) HRV=\(snap.hrv) Sleep=\(String(format: "%.1f", snap.sleepHours)) InBed=\(String(format: "%.1f", snap.sleepInBedHours)) updatedAt=\(snap.updatedAt)")
        log("History: count=\(hist.count) range=\(first)...\(last)")
        if let newest = hist.last {
            log("Newest day=\(newest.dayISO) RHR=\(newest.restingHR ?? -1) HRV=\(newest.hrvMS ?? -1) Sleep=\(newest.sleepHours ?? -1) InBed=\(newest.sleepInBedHours ?? -1) WristC=\(newest.wristTempDeltaC ?? -999)")
        }
        log("Manual: pain=\(man.painLevel) sick=\(man.isSick)")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }
}
