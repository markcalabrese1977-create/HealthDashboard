import XCTest
@testable import HealthDashboard

// Pain/sick (ManualReadinessInputs) are valid only on the calendar day they were entered.
// Expiry is enforced in SharedStore.loadManual; evaluate() is not involved.
final class ManualExpiryTests: XCTestCase {

    private var suite: UserDefaults? { UserDefaults(suiteName: SharedStore.appGroupID) }
    private var saved: Data?

    override func setUp() {
        super.setUp()
        saved = suite?.data(forKey: SharedStore.manualKey)
        suite?.removeObject(forKey: SharedStore.manualKey)
    }

    override func tearDown() {
        if let saved { suite?.set(saved, forKey: SharedStore.manualKey) }
        else { suite?.removeObject(forKey: SharedStore.manualKey) }
        super.tearDown()
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    private var raw: Data? { suite?.data(forKey: SharedStore.manualKey) }

    // 1. Undated legacy value is EXPIRED: .default returned, key removed (not stamped).
    func testUndatedLegacyBlobIsExpiredAndKeyRemoved() {
        suite?.set(Data(#"{"painLevel":5,"isSick":true}"#.utf8), forKey: SharedStore.manualKey)

        let m = SharedStore.loadManual(now: day(2001, 3, 4))

        XCTAssertEqual(m, .default)
        XCTAssertNil(raw, "an expired key is removed")
    }

    // 2. Same-day load keeps the values, and loading writes nothing.
    func testSameDayLoadKeepsValuesWithoutWriting() {
        let d = day(2001, 3, 4)
        SharedStore.saveManual(ManualReadinessInputs(painLevel: 6, isSick: true), now: d)
        let before = raw
        XCTAssertNotNil(before)

        let m = SharedStore.loadManual(now: d)

        XCTAssertEqual(m.painLevel, 6)
        XCTAssertTrue(m.isSick)
        XCTAssertEqual(m.enteredDateISO, "2001-03-04")
        XCTAssertEqual(raw, before, "a valid load must not write")
    }

    // 3. Next calendar day: expired, default returned, key removed.
    func testNextDayLoadExpiresAndRemovesKey() {
        SharedStore.saveManual(ManualReadinessInputs(painLevel: 6, isSick: true), now: day(2001, 3, 4))

        let m = SharedStore.loadManual(now: day(2001, 3, 5))

        XCTAssertEqual(m, .default)
        XCTAssertNil(raw)
    }

    // 4. saveManual stamps the day it is called, overriding any date the caller carried.
    func testSaveStampsTodayAndOverridesCarriedDate() throws {
        var carried = ManualReadinessInputs(painLevel: 2, isSick: false)
        carried.enteredDateISO = "1999-01-01"

        SharedStore.saveManual(carried, now: day(2001, 3, 4))

        let decoded = try JSONDecoder().decode(ManualReadinessInputs.self, from: XCTUnwrap(raw))
        XCTAssertEqual(decoded.enteredDateISO, "2001-03-04")
        XCTAssertEqual(SharedStore.loadManual(now: day(2001, 3, 4)).painLevel, 2)
        XCTAssertEqual(SharedStore.loadManual(now: day(2001, 3, 5)), .default)
    }

    // 5. Decode safety: an old-schema blob decodes (date nil); malformed data yields .default
    //    without any write.
    func testOldSchemaDecodesAndMalformedDataIsNotRemoved() throws {
        let old = try JSONDecoder().decode(ManualReadinessInputs.self,
                                           from: Data(#"{"painLevel":1,"isSick":false}"#.utf8))
        XCTAssertNil(old.enteredDateISO)
        XCTAssertEqual(ManualReadinessInputs(painLevel: 1, isSick: false), old)

        let junk = Data("not json".utf8)
        suite?.set(junk, forKey: SharedStore.manualKey)
        XCTAssertEqual(SharedStore.loadManual(now: day(2001, 3, 4)), .default)
        XCTAssertEqual(raw, junk, "undecodable data is left alone; only an expired key is removed")
    }
}
