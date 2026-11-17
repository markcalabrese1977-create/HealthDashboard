import XCTest
import CryptoKit
@testable import HealthDashboard

/// R3 changed only `sleepDelta` in the parity goldens (hand-edited, not regenerated).
/// This fails if any other golden key differs from main's golden (52dce04).
final class ReadinessParityGoldenGuardTests: XCTestCase {

    /// SHA-256 of main's golden JSON text with every `"sleepDelta": …` line removed.
    private let mainHashWithoutSleepDelta =
        "f2baaf554ae61f60a68c9ec9dc50bc45ecaf4fb024e8b23be501e6c0ae1bdddf"

    func testOnlySleepDeltaDiffersFromMainGolden() throws {
        let stripped = ReadinessParityGolden.json
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("\"sleepDelta\":") }
            .joined(separator: "\n")
        let hash = SHA256.hash(data: Data(stripped.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, mainHashWithoutSleepDelta,
                       "A golden key other than sleepDelta changed vs main — do not regenerate goldens")
    }

    func testSleepDeltaGoldensAreSleepMinusFixedNeed() throws {
        let g = try JSONSerialization.jsonObject(with: Data(ReadinessParityGolden.json.utf8))
            as! [String: [String: Any]]
        let sleep: [String: Double] = ["green_missing_signals": 7.5, "red_recovery_cluster": 5.5]
        for (name, fx) in g {
            let d = try XCTUnwrap((fx["result"] as? [String: Any])?["sleepDelta"] as? Double, name)
            XCTAssertEqual(d, (sleep[name] ?? 8.0) - ReadinessTuning.sleepNeedHours, accuracy: 1e-9, name)
        }
    }
}
