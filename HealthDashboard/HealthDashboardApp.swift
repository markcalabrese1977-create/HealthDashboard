import SwiftUI
import SwiftData
import HealthKit
import WidgetKit

@main
struct HealthDashboardApp: App {

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Item.self])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    private let store = HKHealthStore()

    init() {
        setupHealthKitBackgroundDelivery()
        _ = WatchSessionManager.shared   // activate WCSession early so it's ready by the first backfill
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }

    private func setupHealthKitBackgroundDelivery() {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let quantityTypes: [HKQuantityTypeIdentifier] = [
            .heartRateVariabilitySDNN,
            .restingHeartRate,
            .oxygenSaturation,
            .respiratoryRate
        ]

        var sampleTypes: [HKSampleType] = quantityTypes.compactMap {
            HKObjectType.quantityType(forIdentifier: $0)
        }
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            sampleTypes.append(sleepType)
        }

        for type in sampleTypes {
            // Register for background delivery
            store.enableBackgroundDelivery(for: type, frequency: .immediate) { success, error in
                if let error {
                    print("⚠️ Background delivery failed for \(type): \(error)")
                }
            }

            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completionHandler, error in
                guard error == nil else {
                    completionHandler()
                    return
                }

                // ✅ Call completionHandler immediately — iOS requires this within ~10 seconds
                // or it will permanently stop background delivery for this type.
                // The actual fetch work happens independently in a detached task.
                completionHandler()

                Task.detached(priority: .utility) {
                    do {
                        try await HealthKitManager.shared.requestAuthorization()
                        let points = try await HealthKitManager.shared.fetchLast28Days()

                        guard let last = points.last else { return }

                        var snap = await SharedStore.load()
                        let cal = Calendar.current
                        let snapIsToday = cal.isDateInToday(snap.updatedAt)
                        let fetchedHRV = last.hrvMS.map { Int($0.rounded()) }
                        let hrvMismatch = fetchedHRV != nil && fetchedHRV != snap.hrv

                        // On a new day, zero load values before writing fresh ones
                                                if !snapIsToday {
                                                    snap.stepsToday = 0
                                                    snap.activeEnergyTodayKcal = 0
                                                    snap.exerciseMinutesToday = 0
                                                    snap.standHoursToday = 0
                                                    snap.workoutCountToday = 0
                                                }

                                                // RHR is always live
                                                if let rhr = last.restingHR { snap.restingHR = Int(rhr.rounded()) }

                        // HRV: lock once written today, allow correction if value changed
                        if !snapIsToday || hrvMismatch {
                            if let hrv = last.hrvMS { snap.hrv = Int(hrv.rounded()) }
                        }

                        // Sleep: always write on a new day — independent of HRV
                        let fetchedSleep = last.sleepHours
                        let sleepMismatch: Bool = {
                            guard let fetched = fetchedSleep else { return false }
                            return abs(fetched - snap.sleepHours) > (5.0 / 60.0)
                        }()
                        if !snapIsToday || sleepMismatch {
                            if let sleep = last.sleepHours { snap.sleepHours = sleep }
                            if let inBed = last.sleepInBedHours { snap.sleepInBedHours = inBed }
                        }

                        if let steps = last.steps { snap.stepsToday = Int(steps.rounded()) }
                        if let kcal = last.activeEnergyKcal { snap.activeEnergyTodayKcal = Int(kcal.rounded()) }
                        if let ex = last.exerciseMinutes { snap.exerciseMinutesToday = Int(ex.rounded()) }
                        if let st = last.standHours { snap.standHoursToday = st }
                        if let wc = last.workoutCount { snap.workoutCountToday = Int(wc.rounded()) }
                        snap.updatedAt = Date()

                        await SharedStore.save(snap)
                        await SharedStore.saveHistory(points)
                        WidgetCenter.shared.reloadTimelines(ofKind: "HealthDashboardWidget")

                    } catch {
                        print("⚠️ Background HealthKit fetch failed: \(error)")
                    }
                }
            }

            store.execute(query)
        }
    }
}
