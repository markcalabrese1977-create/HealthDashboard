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

// MARK: - History (for trends + readiness)
// NOTE: UI can display last 7; storage/engine can use 28+.

struct DailyHealthPoint: Codable, Equatable, Identifiable {
    var id: String { dayISO }           // e.g. "2026-01-21"
    let dayISO: String

    // Physiology
    var restingHR: Double?              // bpm
    var hrvMS: Double?                  // milliseconds
    var sleepHours: Double?             // hours asleep
    var sleepInBedHours: Double?        // in-bed / sleep window estimate
    var respiratoryRate: Double?        // breaths/min (sleep)
    var spo2Pct: Double?                // 0–100

    // Wrist Temperature (sleeping; Apple Watch)
    // Stored as absolute °C in our history; UI/engine computes Δ vs baseline.
    // (Naming legacy: kept as wristTempDeltaC to avoid migrations)
    var wristTempDeltaC: Double?        // absolute °C

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

struct ReadinessDriver: Equatable {
    let label: String
    let impact: Int
    let isNegative: Bool
}

struct ReadinessResult: Equatable {
    var truth: ReadinessStatus          // metrics truth color
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
}
extension ReadinessResult {
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
            return "Multiple recovery signals are under baseline."
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
