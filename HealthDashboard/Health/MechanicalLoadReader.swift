import Foundation

struct MechanicalLoadReader {

    private static let suiteName = "group.com.markcalabrese.eliteperformance"
    private static let keyPrefix  = "mechanicalLoad."

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    // MARK: – Single day

    static func read(for date: Date) -> Double {
        let key = keyPrefix + dateString(date)
        return defaults?.double(forKey: key) ?? 0
    }

    // MARK: – Date range (inclusive)

    static func readRange(from start: Date, to end: Date) -> [Date: Double] {
        guard let defaults else { return [:] }
        var result: [Date: Double] = [:]
        var cursor = Calendar.current.startOfDay(for: start)
        let terminal = Calendar.current.startOfDay(for: end)
        while cursor <= terminal {
            let key = keyPrefix + dateString(cursor)
            let value = defaults.double(forKey: key)
            if value > 0 { result[cursor] = value }
            cursor = Calendar.current.date(byAdding: .day, value: 1, to: cursor)!
        }
        return result
    }

    // MARK: – Private

    private static func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
