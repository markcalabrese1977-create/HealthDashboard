import Foundation
import os

// MARK: - Cardio Calibration Store (HD-owned; read + write)
//
// Persistence for CardioCalibrationPoint, mirroring the MechanicalLoadReader
// App-Group idiom but READ + WRITE — HD owns this data (MechanicalLoadReader is
// read-only because EP owns mechanical load). Uses HD's OWN App Group
// (SharedStore.appGroupID), not EP's suite. Single key → JSON-encoded array.
// Synchronous UserDefaults; no HealthKit permission needed here.

enum CardioCalibrationStore {

    // Reuse HD's confirmed App Group (same suite SharedStore writes to).
    private static let suiteName = SharedStore.appGroupID
    static let cardioCalibrationPointsKey = "cardioCalibrationPoints"

    /// Rolling window the estimator will fit over (kept here so capture + later
    /// consumers agree on one number).
    static let calibrationWindowDays = 90

    private static let logger = Logger(
        subsystem: "com.calabrese.HealthDashboard",
        category: "CardioCalibrationStore"
    )

    private static func defaults() -> UserDefaults? {
        let d = UserDefaults(suiteName: suiteName)
        if d == nil {
            logger.log("❌ UserDefaults(suiteName:) nil for \(suiteName, privacy: .public)")
        }
        return d
    }

    // MARK: Load

    /// All stored points, chronological (oldest → newest).
    static func loadAll() -> [CardioCalibrationPoint] {
        guard
            let d = defaults(),
            let data = d.data(forKey: cardioCalibrationPointsKey),
            let decoded = try? JSONDecoder().decode([CardioCalibrationPoint].self, from: data)
        else {
            logger.log("📥 load(cardioCalibration) -> [] (no data yet)")
            return []
        }
        logger.log("📥 load(cardioCalibration) -> count=\(decoded.count)")
        return decoded.sorted { $0.date < $1.date }
    }

    // MARK: Append

    /// Decode → append → encode → write. Returns the full stored set after the append.
    @discardableResult
    static func append(_ point: CardioCalibrationPoint) -> [CardioCalibrationPoint] {
        var points = loadAll()
        points.append(point)
        points.sort { $0.date < $1.date }
        save(points)
        return points
    }

    // MARK: Edit / Delete
    //
    // The store is the dataset every downstream consumer rides on, so it must be
    // correctable. Both are id-based (the stored UUID makes this clean) and re-encode
    // the whole array, matching the append idiom. Note: a delete/edit that lands inside
    // the 90-day window intentionally changes the FUTURE regression input set — that's
    // the integrity mechanism, not a side effect.

    /// Replace the point sharing `point.id`; no-op if none matches. Returns the stored set.
    @discardableResult
    static func update(_ point: CardioCalibrationPoint) -> [CardioCalibrationPoint] {
        var points = loadAll()
        guard let idx = points.firstIndex(where: { $0.id == point.id }) else {
            logger.log("⚠️ update(cardioCalibration) -> id not found, no-op")
            return points
        }
        points[idx] = point
        points.sort { $0.date < $1.date }
        save(points)
        return points
    }

    /// Remove the point with the given `id`. Returns the stored set after the delete.
    @discardableResult
    static func delete(id: UUID) -> [CardioCalibrationPoint] {
        var points = loadAll()
        points.removeAll { $0.id == id }
        save(points)
        return points
    }

    private static func save(_ points: [CardioCalibrationPoint]) {
        guard let d = defaults() else { return }
        if let data = try? JSONEncoder().encode(points) {
            d.set(data, forKey: cardioCalibrationPointsKey)
            logger.log("📤 save(cardioCalibration) -> count=\(points.count)")
        } else {
            logger.log("❌ save(cardioCalibration) encode failed")
        }
    }

    // MARK: Rolling window helper (for the later estimator)

    /// Points whose date falls within the last `calibrationWindowDays` relative to
    /// `asOf`. Capture-only slice doesn't fit these yet — provided so the estimator
    /// and the log-screen confirmation count agree on the window definition.
    static func pointsInWindow(asOf reference: Date = Date()) -> [CardioCalibrationPoint] {
        guard let cutoff = Calendar.current.date(
            byAdding: .day, value: -calibrationWindowDays, to: reference
        ) else {
            return loadAll()
        }
        return loadAll().filter { $0.date >= cutoff && $0.date <= reference }
    }
}
