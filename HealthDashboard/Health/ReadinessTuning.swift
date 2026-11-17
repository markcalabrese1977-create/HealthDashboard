import Foundation

/// Named thresholds for the readiness engine. Each name says what the value separates.
enum ReadinessTuning {
    /// Stated nightly sleep need. The single sleep reference for score, tile, row and flags.
    static let sleepNeedHours = 7.5
    /// Short by ≤ this → sleepScore 0.
    static let sleepNoPenaltyMaxShortHours = 0.5
    /// Short by ≤ this → −1.
    static let sleepMinus1MaxShortHours = 1.5
    /// Short by ≤ this → −2; beyond → −3.
    static let sleepMinus2MaxShortHours = 2.5
    /// +1 recovery-night promotion when asleep > need + margin.
    static let sleepRecoveryNightMarginHours = 1.0
    /// sleepShort1 cluster flag when asleep ≤ need − gap.
    static let sleepShort1GapHours = 1.0
}
