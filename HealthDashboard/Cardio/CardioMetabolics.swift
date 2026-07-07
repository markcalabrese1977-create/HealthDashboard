import Foundation

// MARK: - ACSM Metabolic Conversion (pure, stateless)
//
// Deterministic physiological unit transform: (speed, grade) → gross VO2 in
// mL/kg/min via the ACSM walking/running metabolic equations. This is a UNIT
// TRANSFORM, not scoring — it does not read baselines, does not touch readiness,
// and returns the same output for the same input forever — so it is allowed in
// the capture path. No fitting, no regression here.
//
// ACSM validity ranges (guidance, NOT a hard gate — capture still records
// out-of-range segments; the estimator can weight/reject later):
//   • Walking equation:  ~1.9–3.7 mph on a treadmill.
//   • Running equation:   > 5 mph (or > 3 mph if the subject is truly jogging).
// The caller (CardioCalibrationLogView) picks walk vs run explicitly.

enum CardioMetabolics {

    // ACSM gross-VO2 coefficients (mL/kg/min per unit of m/min).
    static let walkVO2SpeedCoeff = 0.1
    static let walkVO2GradeCoeff = 1.8
    static let runVO2SpeedCoeff  = 0.2
    static let runVO2GradeCoeff  = 0.9

    /// Resting component added by both ACSM equations (mL/kg/min ≈ 1 MET).
    static let restingVO2 = 3.5

    // Unit conversions.
    static let mphToMetersPerMin    = 26.8224   // 1 mph → m/min
    static let percentGradeToDecimal = 0.01     // e.g. 3(%) → 0.03

    /// Gross VO2 (mL/kg/min) for a steady-state segment.
    /// - Parameters:
    ///   - speedMetersPerMin: horizontal speed in m/min (canonical).
    ///   - gradeDecimal: incline as a decimal fraction (e.g. 0.03 for 3%).
    static func computeVO2(
        activityType: CardioActivityType,
        speedMetersPerMin speed: Double,
        gradeDecimal grade: Double
    ) -> Double {
        switch activityType {
        case .walk:
            return (walkVO2SpeedCoeff * speed)
                 + (walkVO2GradeCoeff * speed * grade)
                 + restingVO2
        case .run:
            return (runVO2SpeedCoeff * speed)
                 + (runVO2GradeCoeff * speed * grade)
                 + restingVO2
        }
    }
}
