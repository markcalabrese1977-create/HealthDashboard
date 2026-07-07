import Foundation

// MARK: - Cardio Calibration Point (VO2max capture-first slice)
//
// One record per logged steady-state cardio segment. This is the raw calibration
// datum the 90-day rolling window accumulates NOW so the estimator/regression
// (deferred) has data to fit once enough points accrue. Deliberately a plain
// value type — NO fitting, outlier rejection, or extrapolation lives here; those
// are the estimator's job in a later slice.
//
// ID note: unlike DailyHealthPoint / DXAScan (one-per-day, keyed by a computed
// dateISO), multiple calibration segments can be logged on the same day, so a
// natural date key is not unique. A stored UUID is used instead.

enum CardioActivityType: String, Codable, Equatable {
    case walk
    case run

    var title: String {
        switch self {
        case .walk: return "Walk"
        case .run:  return "Run"
        }
    }
}

struct CardioCalibrationPoint: Codable, Equatable, Identifiable {
    let id: UUID
    let date: Date
    let activityType: CardioActivityType

    // Canonical units (SI-ish) — the log screen converts from mph / %grade on save.
    let speedMetersPerMin: Double   // m/min
    let gradeDecimal: Double        // e.g. 0.03 for a 3% incline

    let steadyStateHR: Double       // bpm, pulled from HealthKit over the segment window
    let computedVO2: Double         // mL/kg/min, from CardioMetabolics (ACSM)
    let durationSeconds: Double     // segment length (the RESOLVED marked ∩ workout window)

    // HR provenance / audit trail. OPTIONAL on purpose: synthesized Codable does NOT
    // supply defaults for missing keys, so non-optional fields would fail to decode any
    // point saved before this schema. A point with ALL-NIL provenance predates these
    // audit fields (a "pre-audit" point). workoutUUID is the key that lets a saved point
    // be re-verified against its source HKWorkout later.
    let hrSampleCount: Int?             // HR samples averaged over the resolved interval
    let hrSourceName: String?           // HKWorkout source name, e.g. "Apple Watch"
    let hrResolvedInterval: DateInterval? // window actually averaged (marked ∩ workout)
    let workoutUUID: UUID?              // uuid of the resolving HKWorkout

    init(
        id: UUID = UUID(),
        date: Date,
        activityType: CardioActivityType,
        speedMetersPerMin: Double,
        gradeDecimal: Double,
        steadyStateHR: Double,
        computedVO2: Double,
        durationSeconds: Double,
        hrSampleCount: Int? = nil,
        hrSourceName: String? = nil,
        hrResolvedInterval: DateInterval? = nil,
        workoutUUID: UUID? = nil
    ) {
        self.id = id
        self.date = date
        self.activityType = activityType
        self.speedMetersPerMin = speedMetersPerMin
        self.gradeDecimal = gradeDecimal
        self.steadyStateHR = steadyStateHR
        self.computedVO2 = computedVO2
        self.durationSeconds = durationSeconds
        self.hrSampleCount = hrSampleCount
        self.hrSourceName = hrSourceName
        self.hrResolvedInterval = hrResolvedInterval
        self.workoutUUID = workoutUUID
    }
}
