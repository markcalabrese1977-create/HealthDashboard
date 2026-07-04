import SwiftUI
import WidgetKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var snapshot = SharedStore.load()
    @State private var history: [DailyHealthPoint] = SharedStore.loadHistory()
    @State private var manual = SharedStore.loadManual()
    @State private var showActionDialog = false

    // DXA (manual snapshots)
    @State private var dxaScans: [DXAScan] = SharedStore.loadDXAScans()
    @State private var showDXAForm = false

    // Body measurements (manual tape)
    @State private var bodyMeasurements: [BodyMeasurementEntry] = SharedStore.loadBodyMeasurements()
    @State private var showMeasurementsForm = false

    @State private var isRefreshing = false
        @State private var errorText: String?
    @State private var selectedMetric: HealthMetric? = nil
        @State private var selectedBodyMetric: BodyMetric? = nil

    // MARK: - Auto refresh
    private let staleThresholdSeconds: TimeInterval = 60 * 10   // 10 min
    private let visibleRefreshIntervalSeconds: TimeInterval = 60 * 5 // 5 min

    // MARK: - Readiness
    // Stored, not computed: previously this was a computed property that called
    // ReadinessEngine.evaluate() on every access, which SwiftUI triggers on every
    // view-body re-evaluation (including each of the 5 onAppear UserDefaults loads
    // before HealthKit data even arrives). Now it's set explicitly exactly when its
    // inputs change: once from cache in onAppear, once after backfill7Days()
    // completes with full history, and once when manual inputs are edited.
    @State private var readiness: ReadinessResult = .empty

        private var weeklySummary: WeeklySummary? {
            WeeklySummary.build(history: history, manual: manual)
        }
    
    private var readinessPresentation: ReadinessPresentation {
        readiness.presentation(manual: manual)
    }

    private var latestDXA: DXAScan? {
        dxaScans.max(by: { $0.dateISO < $1.dateISO })
    }

    private var latestMeasurements: BodyMeasurementEntry? {
        bodyMeasurements.max(by: { $0.dateISO < $1.dateISO })
    }

    private var assumedHeightIn: Double {
        latestDXA?.heightIn ?? 72.0
    }

    private func median(_ xs: [Double]) -> Double? {
        let s = xs.sorted()
        guard !s.isEmpty else { return nil }
        if s.count % 2 == 1 { return s[s.count / 2] }
        return (s[(s.count / 2) - 1] + s[s.count / 2]) / 2.0
    }

    private var wristTempDisplayDelta: Double? {
            // Use engine's 28-day baseline delta so displayed value and badge are consistent.
            readiness.tempDelta
        }

    // MARK: - Latest-value helpers (from 7-day history)
    private func latestNonNil<T>(_ keyPath: KeyPath<DailyHealthPoint, T?>) -> T? {
        history.last(where: { $0[keyPath: keyPath] != nil })?[keyPath: keyPath]
    }

    private var latestRespRate: Double? { latestNonNil(\.respiratoryRate) }

        private var latestSleepEff: Double? {
            guard let asleep = history.last?.sleepHours,
                  let inBed = history.last?.sleepInBedHours,
                  inBed > 0 else { return nil }
            return asleep / inBed
        }

    private var recoverySparklines: (rhr: [Double], hrv: [Double], sleep: [Double], temp: [Double], rr: [Double], eff: [Double]) {
            let pts = Array(history.suffix(7))
            return (
                rhr:   pts.compactMap { $0.restingHR.map { Double($0) } },
                hrv:   pts.compactMap { $0.hrvMS },
                sleep: pts.compactMap { $0.sleepHours },
                temp:  pts.compactMap { $0.wristTempDeltaC },
                rr:    pts.compactMap { $0.respiratoryRate },
                            eff:   pts.compactMap {
                                guard let a = $0.sleepHours, let b = $0.sleepInBedHours, b > 0 else { return nil }
                                return a / b
                            }
                        )
                    }
    private var latestSpO2: Double? { latestNonNil(\.spo2Pct) }
    
    private func fmtSigned1(_ v: Double?) -> String {
        guard let v else { return "--" }
        return String(format: "%+.1f", v)
    }

    private func fmt1(_ v: Double?, suffix: String = "") -> String {
        guard let v else { return "--" }
        return String(format: "%.1f%@", v, suffix)
    }

    private func fmtSleepHM(_ hours: Double?) -> String {
        guard let hours else { return "--" }
        let totalMinutes = Int((hours * 60).rounded())
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return "\(h)h \(m)m"
    }

    // MARK: - Body helpers
    private var latestBodyPoint: DailyHealthPoint? {
        history.last(where: { $0.bodyWeightLb != nil || $0.bodyFatPct != nil || $0.leanMassLb != nil })
    }

    private var fatMassLb: Double? {
        guard let w = latestBodyPoint?.bodyWeightLb,
              let bf = latestBodyPoint?.bodyFatPct
        else { return nil }
        return w * (bf / 100.0)
    }

    private var leanMass7dDelta: Double? {
        let last7 = Array(history.suffix(7))
        let leans = last7.compactMap { $0.leanMassLb }
        guard let first = leans.first, let last = leans.last else { return nil }
        return last - first
    }

    private var latestWeightDayISO: String? { history.last(where: { $0.bodyWeightLb != nil })?.dayISO }
    private var latestBodyFatDayISO: String? { history.last(where: { $0.bodyFatPct != nil })?.dayISO }
    private var latestLeanMassDayISO: String? { history.last(where: { $0.leanMassLb != nil })?.dayISO }

    private func fmtDay(_ iso: String?) -> String {
        guard let iso else { return "--" }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        guard let d = df.date(from: iso) else { return iso }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - Measurements deltas (keep existing behavior)
    private var waistNavelDelta4w: Double? {
        guard let latest = latestMeasurements,
              let latestWaist = latest.waistNavelIn
        else { return nil }

        let latestDate = ISODate.fromISO(latest.dateISO) ?? Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: -28, to: latestDate) ?? latestDate

        let older = bodyMeasurements
            .filter { (ISODate.fromISO($0.dateISO) ?? .distantPast) <= cutoff }
            .max(by: { $0.dateISO < $1.dateISO })

        guard let baseWaist = older?.waistNavelIn else { return nil }
        return latestWaist - baseWaist
    }

    // MARK: - Trends (7-day window)
    private var trendSummaries: [TrendSummary] {
        let last7 = Array(history.suffix(7))

        func median(_ xs: [Double]) -> Double? {
            let s = xs.sorted()
            guard !s.isEmpty else { return nil }
            if s.count % 2 == 1 { return s[s.count / 2] }
            return (s[s.count / 2 - 1] + s[s.count / 2]) / 2.0
        }

        func make(
            title: String,
            unit: String,
            systemImage: String,
            betterDirection: TrendSummary.BetterDirection,
            values: [Double?]
        ) -> TrendSummary {
            let nums = values.compactMap { $0 }
            let avg = nums.isEmpty ? nil : nums.reduce(0, +) / Double(nums.count)
            let mn = nums.min()
            let mx = nums.max()

            let nowIndex = values.lastIndex(where: { $0 != nil })
            let nowValue = nowIndex.flatMap { values[$0] }

            let baselineNums: [Double] = {
                guard let nowIndex, nowIndex > 0 else { return values.compactMap { $0 } }
                return Array(values.prefix(nowIndex)).compactMap { $0 }
            }()
            let baseline = median(baselineNums)
            let delta = (nowValue != nil && baseline != nil) ? (nowValue! - baseline!) : nil

            let nowDayISO: String? = {
                guard let nowIndex, nowIndex < last7.count else { return nil }
                return last7[nowIndex].dayISO
            }()

            return TrendSummary(
                title: title,
                unit: unit,
                systemImage: systemImage,
                values: values,
                betterDirection: betterDirection,
                avg: avg,
                min: mn,
                max: mx,
                nowValue: nowValue,
                nowIndex: nowIndex,
                nowDayISO: nowDayISO,
                baselineMedian: baseline,
                deltaVsBaseline: delta
            )
        }

        let rhrVals   = last7.map { $0.restingHR }
        let hrvVals   = last7.map { $0.hrvMS }
        let sleepVals = last7.map { $0.sleepHours }

        var out: [TrendSummary] = [
                    make(title: "Resting HR", unit: "bpm", systemImage: "heart.fill",         betterDirection: .lower,  values: rhrVals),
                    make(title: "HRV",        unit: "ms",  systemImage: "waveform.path.ecg", betterDirection: .higher, values: hrvVals),
                    make(title: "Sleep",      unit: "h",   systemImage: "bed.double.fill",   betterDirection: .higher, values: sleepVals)
                ]
                out[0].metric = .rhr
                out[1].metric = .hrv
                out[2].metric = .sleep

        let wtAbsVals = last7.map { $0.wristTempDeltaC }
                if wtAbsVals.contains(where: { $0 != nil }) {
                    // Convert absolute °C to per-day delta vs rolling baseline median
                    // so Trends shows the same signal as the Recovery Signals tile
                    let wtDeltaVals: [Double?] = wtAbsVals.enumerated().map { (i, val) in
                        guard val != nil else { return nil }
                        let priorVals = wtAbsVals.prefix(i).compactMap { $0 }
                        guard priorVals.count >= 3, let base = median(priorVals) else { return nil }
                        return val! - base
                    }
                    if wtDeltaVals.contains(where: { $0 != nil }) {
                                            out.append(make(title: "Wrist Temp Δ", unit: "°C", systemImage: "thermometer", betterDirection: .lower, values: wtDeltaVals))
                                            out[out.count - 1].metric = .wristTemp
                                        }
                }

        let rrVals = last7.map { $0.respiratoryRate }
        let spo2Vals = last7.map { $0.spo2Pct }
        if rrVals.contains(where: { $0 != nil }) {
                    out.append(make(title: "Resp Rate", unit: "br/min", systemImage: "lungs.fill", betterDirection: .lower, values: rrVals))
                    out[out.count - 1].metric = .respRate
                }
        if spo2Vals.contains(where: { $0 != nil }) {
                    out.append(make(title: "SpO2", unit: "%", systemImage: "drop.fill", betterDirection: .higher, values: spo2Vals))
                    out[out.count - 1].metric = .spo2
                }

        let stepsVals = last7.map { $0.steps }
        let energyVals = last7.map { $0.activeEnergyKcal }
        let exerciseVals = last7.map { $0.exerciseMinutes }
        let standVals = last7.map { $0.standHours }

        if stepsVals.contains(where: { $0 != nil }) {
            out.append(make(title: "Steps", unit: "", systemImage: "figure.walk", betterDirection: .neutral, values: stepsVals))
        }
        if energyVals.contains(where: { $0 != nil }) {
            out.append(make(title: "Active Energy", unit: "kcal", systemImage: "flame.fill", betterDirection: .neutral, values: energyVals))
        }
        if exerciseVals.contains(where: { $0 != nil }) {
            out.append(make(title: "Exercise", unit: "min", systemImage: "figure.run", betterDirection: .neutral, values: exerciseVals))
        }
        if standVals.contains(where: { $0 != nil }) {
            out.append(make(title: "Stand", unit: "h", systemImage: "figure.stand", betterDirection: .neutral, values: standVals))
        }

        let workoutCountVals = last7.map { $0.workoutCount }
        let workoutMinVals = last7.map { $0.workoutMinutes }
        let workoutEnergyVals = last7.map { $0.workoutEnergyKcal }

        if workoutCountVals.contains(where: { $0 != nil }) {
            out.append(make(title: "Workouts", unit: "", systemImage: "dumbbell.fill", betterDirection: .neutral, values: workoutCountVals))
        }
        if workoutMinVals.contains(where: { $0 != nil }) {
            out.append(make(title: "Workout Time", unit: "min", systemImage: "stopwatch.fill", betterDirection: .neutral, values: workoutMinVals))
        }
        if workoutEnergyVals.contains(where: { $0 != nil }) {
            out.append(make(title: "Workout Energy", unit: "kcal", systemImage: "bolt.fill", betterDirection: .neutral, values: workoutEnergyVals))
        }

        let wVals  = last7.map { $0.bodyWeightLb }
        let bfVals = last7.map { $0.bodyFatPct }
        let lmVals = last7.map { $0.leanMassLb }

        if wVals.contains(where: { $0 != nil }) {
                    out.append(make(title: "Weight", unit: "lb", systemImage: "scalemass", betterDirection: .lower, values: wVals))
                    out[out.count - 1].metric = nil
                    out[out.count - 1].bodyMetric = .weight
                }
                if bfVals.contains(where: { $0 != nil }) {
                    out.append(make(title: "Body Fat", unit: "%", systemImage: "percent", betterDirection: .lower, values: bfVals))
                    out[out.count - 1].bodyMetric = .bodyFat
                }
                if lmVals.contains(where: { $0 != nil }) {
                    out.append(make(title: "Lean Mass", unit: "lb", systemImage: "figure.strengthtraining.traditional", betterDirection: .higher, values: lmVals))
                    out[out.count - 1].bodyMetric = .leanMass
                }

        return out
    }

    // MARK: - View
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header

                    DashboardCard(
                        title: "Readiness",
                        trailing: AnyView(EmptyView())
                    ) {
                        VStack(alignment: .leading, spacing: 12) {

                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(readinessPresentation.headline)
                                        .font(.title2.weight(.bold))

                                    Text(readinessPresentation.subline)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 8) {
                                    StatusPill(title: readiness.truth.title, status: readiness.truth)

                                    Text("As of \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Text(readinessPresentation.explanation)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Text(readinessPresentation.confidenceLine)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            if !readiness.drivers.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    let displays = readiness.driverDisplays()
                                    ForEach(Array(displays.enumerated()), id: \.offset) { index, display in
                                        DriverRow(display: display, onTap: { selectedMetric = $0 })

                                        if index < displays.count - 1 {
                                            Divider().opacity(0.5)
                                        }
                                    }

                                    if let reconcile = readiness.reconciliationLine {
                                        Text(reconcile)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.top, 2)
                                    }
                                }
                            }

                            Button { showActionDialog = true } label: {
                                let iconName: String = {
                                    switch readiness.action {
                                    case .green: return "checkmark.circle.fill"
                                    case .yellow: return "exclamationmark.triangle.fill"
                                    case .red: return "cross.circle.fill"
                                    }
                                }()

                                HStack {
                                    Image(systemName: iconName)
                                    Text(readinessPresentation.guidanceButtonTitle)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                            .confirmationDialog("Today’s Action", isPresented: $showActionDialog, titleVisibility: .visible) {
                                Button("OK") {}
                            } message: {
                                Text(readiness.actionMessage)
                            }

                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Only use this when wearables miss the obvious.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text("Pain")
                                            Spacer()
                                            Text("\(manual.painLevel)/10")
                                                .foregroundStyle(.secondary)
                                        }

                                        Slider(
                                            value: Binding(
                                                get: { Double(manual.painLevel) },
                                                set: {
                                                    manual.painLevel = Int($0.rounded())
                                                    persistManual()
                                                }
                                            ),
                                            in: 0...10,
                                            step: 1
                                        )
                                    }

                                    Toggle("Sick (systemic)", isOn: Binding(
                                        get: { manual.isSick },
                                        set: {
                                            manual.isSick = $0
                                            persistManual()
                                        }
                                    ))

                                    Text("Turn on only if you’re clearly sick (feverish, body aches, chest crud, heavy fatigue).")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.top, 6)
                            } label: {
                                Label("Reality check", systemImage: "slider.horizontal.3")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    }

                    if let summary = weeklySummary {
                                            WeeklySummaryCard(summary: summary)
                                        }

                                        DashboardCard(
                                            title: "Recovery Signals",
                                            trailing: AnyView(
                                                Text("Latest / overnight")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            ),
                                            collapsible: true
                                        ) {
                        let cols = [GridItem(.flexible()), GridItem(.flexible())]

                                            LazyVGrid(columns: cols, spacing: 10) {
                                                                        MetricTile(
                                                                            title: "Resting HR",
                                                            subtitle: "Latest",
                                                            value: "\(snapshot.restingHR)",
                                                            unit: "bpm",
                                                            systemImage: "heart.fill",
                                                            sparkValues: recoverySparklines.rhr,
                                                            delta: readiness.rhrDelta,
                                                            deltaUnit: "bpm",
                                                            higherIsBetter: false,
                                                            metric: .rhr,
                                                            history: history,
                                                            readiness: readiness,
                                                                            onTap: { selectedMetric = $0 }
                                                        )

                            // TEMPORARY comparison tile — sleep-window RHR is now the primary
                            // signal (see ReadinessEngine cutover); this shows Apple's raw
                            // restingHeartRate purely for reference while we keep an eye on how
                            // far the two diverge. No delta/baseline — not wired into scoring.
                            // Remove once the Apple reference is no longer needed.
                            MetricTile(
                                title: "RHR (Apple)",
                                subtitle: "For reference only",
                                value: history.last?.appleRestingHR.map { "\(Int($0.rounded())) bpm" } ?? "—",
                                unit: "",
                                systemImage: "heart.text.square"
                            )

                            MetricTile(
                                                            title: "HRV",
                                                            subtitle: "Overnight",
                                                            value: "\(snapshot.hrv)",
                                                            unit: "ms",
                                                            systemImage: "waveform.path.ecg",
                                                            sparkValues: recoverySparklines.hrv,
                                                            delta: readiness.hrvDelta,
                                                            deltaUnit: "ms",
                                                            higherIsBetter: true,
                                                            metric: .hrv,
                                                            history: history,
                                                            readiness: readiness,
                                                            onTap: { selectedMetric = $0 }
                                                        )

                            // TEMPORARY comparison tile — sleep-window HRV is now the primary
                            // signal (see ReadinessEngine cutover); show it explicitly for the
                            // first few weeks while the 28-day baseline rebuilds from clean data.
                            // No delta/baseline — not wired into scoring. Remove once the baseline
                            // has rebuilt and this no longer adds useful context.
                            MetricTile(
                                title: "HRV (Sleep)",
                                subtitle: "Verified sleep window",
                                value: history.last?.sleepWindowHRV.map { "\(Int($0.rounded())) ms" } ?? "—",
                                unit: "",
                                systemImage: "bed.double.fill"
                            )

                            MetricTile(
                                                            title: "Sleep",
                                                            subtitle: "Asleep",
                                                            value: fmtSleepHM(snapshot.sleepHours),
                                                            unit: "",
                                                            systemImage: "bed.double.fill",
                                                            sparkValues: recoverySparklines.sleep,
                                                            delta: readiness.sleepDelta,
                                                            deltaUnit: "h",
                                                            higherIsBetter: true,
                                                            metric: .sleep,
                                                            history: history,
                                                            readiness: readiness,
                                                            onTap: { selectedMetric = $0 }
                                                        )

                            if wristTempDisplayDelta != nil {
                                MetricTile(
                                                                    title: "Wrist Temp",
                                                                    subtitle: "Δ vs baseline",
                                                                    value: fmtSigned1(wristTempDisplayDelta),
                                                                    unit: "°C",
                                                                    systemImage: "thermometer",
                                                                    sparkValues: recoverySparklines.temp,
                                                                    delta: readiness.tempDelta,
                                                                    deltaUnit: "°C",
                                                                    higherIsBetter: false,
                                                                    metric: .wristTemp,
                                                                    history: history,
                                                                    readiness: readiness,
                                                                    onTap: { selectedMetric = $0 }
                                                                )
                            } else {
                                MetricTile(
                                    title: "Updated",
                                    subtitle: "",
                                    value: snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened),
                                    unit: "",
                                    systemImage: "clock",
                                    isDateTime: true
                                )
                            }

                            if latestRespRate != nil {
                                MetricTile(
                                                                    title: "Resp Rate",
                                                                    subtitle: "Sleep avg",
                                                                    value: fmt1(latestRespRate),
                                                                    unit: "br/min",
                                                                    systemImage: "lungs.fill",
                                                                    sparkValues: recoverySparklines.rr,
                                                                    delta: readiness.rrDelta,
                                                                    deltaUnit: "br/min",
                                                                    higherIsBetter: false,
                                                                    metric: .respRate,
                                                                    history: history,
                                                                    readiness: readiness,
                                                                    onTap: { selectedMetric = $0 }
                                                                )
                            }

                            // Sleep Quality composite (Phase 5) replaces the raw efficiency
                            // gauge as the headline sleep tile. Composite is today-only (no
                            // per-day history series), so no sparkline. Falls back to the raw
                            // efficiency ratio until a composite exists (pre-first-fetch, or an
                            // unstaged night the engine returns .unavailable for).
                            if let sq = readiness.sleepQuality, sq != .unavailable {
                                MetricTile(
                                                                    title: "Sleep Quality",
                                                                    subtitle: sq.verdict.title,
                                                                    value: "\(Int(sq.composite.rounded()))",
                                                                    unit: "/100",
                                                                    systemImage: "bed.double.fill",
                                                                    sparkValues: history.suffix(7).compactMap { $0.sleepCompositeScore },
                                                                    higherIsBetter: true,
                                                                    metric: .sleepEff,
                                                                    history: history,
                                                                    readiness: readiness,
                                                                    onTap: { selectedMetric = $0 }
                                                                )
                            } else if let eff = latestSleepEff {
                                MetricTile(
                                                                    title: "Sleep Eff",
                                                                    subtitle: "Overnight",
                                                                    value: "\(Int(eff * 100))%",
                                                                    unit: "",
                                                                    systemImage: "bed.double.fill",
                                                                    sparkValues: recoverySparklines.eff,
                                                                    delta: readiness.effDelta.map { $0 * 100 },
                                                                    deltaUnit: "%",
                                                                    higherIsBetter: true,
                                                                    metric: .sleepEff,
                                                                    history: history,
                                                                    readiness: readiness,
                                                                    onTap: { selectedMetric = $0 }
                                                                )
                            }

                            if latestSpO2 != nil {
                                MetricTile(
                                                                    title: "SpO2",
                                                                    subtitle: "Sleep avg",
                                                                    value: fmt1(latestSpO2),
                                                                    unit: "%",
                                                                    systemImage: "drop.fill",
                                                                    metric: .spo2,
                                                                    history: history,
                                                                    readiness: readiness,
                                                                    onTap: { selectedMetric = $0 }
                                                                )
                            }
                        }
                    }

                    DashboardCard(
                        title: "Load Signals",
                        trailing: AnyView(
                            Button { Task { await backfill7Days() } } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                                    .font(.subheadline.weight(.semibold))
                            }
                                .disabled(isRefreshing)
                                                        ),
                                                        collapsible: true
                                                    ) {
                                                        let cols = [GridItem(.flexible()), GridItem(.flexible())]

                        LazyVGrid(columns: cols, spacing: 10) {
                            MetricTile(title: "Steps", subtitle: "Today so far", value: "\(snapshot.stepsToday)", unit: "", systemImage: "figure.walk")
                            MetricTile(title: "Active Energy", subtitle: "Today so far", value: "\(snapshot.activeEnergyTodayKcal)", unit: "kcal", systemImage: "flame.fill")
                            MetricTile(title: "Exercise", subtitle: "Today so far", value: "\(snapshot.exerciseMinutesToday)", unit: "min", systemImage: "figure.run")
                            MetricTile(title: "Stand", subtitle: "Today so far", value: String(format: "%.1f", snapshot.standHoursToday), unit: "h", systemImage: "figure.stand")

                            if snapshot.workoutCountToday > 0 {
                                                            MetricTile(title: "Workouts", subtitle: "Today", value: "\(snapshot.workoutCountToday)", unit: "", systemImage: "dumbbell.fill")
                                                        }

                                                        let trimp = history.last?.dailyTrimp ?? 0
                                                        let trimpBase: Double = {
                                                            let vals = history.dropLast().compactMap { $0.dailyTrimp }.filter { $0 > 0 }
                                                            guard !vals.isEmpty else { return 0.0 }
                                                            return vals.reduce(0, +) / Double(vals.count)
                                                        }()
                                                        let trimpDelta: Double? = (trimp > 0 && trimpBase > 0) ? trimp - trimpBase : nil
                                                        MetricTile(
                                                            title: "Training Load",
                                                            subtitle: "TRIMP score",
                                                            value: trimp > 0 ? "\(Int(trimp.rounded()))" : "—",
                                                            unit: "",
                                                            systemImage: "bolt.heart.fill",
                                                            delta: trimpDelta,
                                                                                                deltaUnit: "pts",
                                                                                                higherIsBetter: false,
                                                            metric: .trainingLoad,
                                                            onTap: { selectedMetric = $0 }
                                                        )
                            let ml = history.last?.mechanicalLoad ?? 0
                            let mlBase: Double = {
                                let vals = history.dropLast().compactMap { $0.mechanicalLoad }.filter { $0 > 0 }
                                guard !vals.isEmpty else { return 0.0 }
                                return vals.reduce(0, +) / Double(vals.count)
                            }()
                            let mlDelta: Double? = (ml > 0 && mlBase > 0) ? ml - mlBase : nil
                            MetricTile(
                                title: "Strength Load",
                                subtitle: "Volume score",
                                value: ml > 0 ? "\(Int(ml.rounded()))" : "—",
                                unit: "",
                                systemImage: "dumbbell.fill",
                                delta: mlDelta,
                                deltaUnit: "",
                                higherIsBetter: false,
                                metric: .strengthLoad,
                                onTap: { selectedMetric = $0 }
                            )
                        }

                        if let errorText {
                            Text(errorText)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.top, 6)
                        }
                    }

                    DashboardCard(
                                            title: "Body",
                                            trailing: AnyView(Text("Smart scale → Apple Health").font(.caption).foregroundStyle(.secondary)),
                                            collapsible: true
                                        ) {
                                            VStack(alignment: .leading, spacing: 10) {
                                                BodyRow(
                                                    title: "Weight",
                                                    value: latestBodyPoint?.bodyWeightLb.map { String(format: "%.1f lb", $0) } ?? "--",
                                                    footnote: "Last weigh-in",
                                                    footnoteValue: fmtDay(latestWeightDayISO),
                                                    onTap: { selectedBodyMetric = .weight }
                                                )
                                                Divider().opacity(0.6)

                                                BodyRow(
                                                    title: "Body Fat",
                                                    value: latestBodyPoint?.bodyFatPct.map { String(format: "%.1f%%", $0) } ?? "--",
                                                    footnote: "Last body fat",
                                                    footnoteValue: fmtDay(latestBodyFatDayISO),
                                                    onTap: { selectedBodyMetric = .bodyFat }
                                                )
                                                Divider().opacity(0.6)

                                                BodyRow(
                                                    title: "Lean Mass",
                                                    value: latestBodyPoint?.leanMassLb.map { String(format: "%.1f lb", $0) } ?? "--",
                                                    footnote: "Last lean mass",
                                                    footnoteValue: fmtDay(latestLeanMassDayISO),
                                                    onTap: { selectedBodyMetric = .leanMass }
                                                )
                            Divider().opacity(0.6)

                            BodyRow(
                                title: "Fat Mass",
                                value: fatMassLb.map { String(format: "%.1f lb", $0) } ?? "--",
                                footnote: "Derived (Weight × BF%)",
                                footnoteValue: ""
                            )
                            Divider().opacity(0.6)

                            BodyRow(
                                title: "Lean Mass (7d Δ)",
                                value: leanMass7dDelta.map { String(format: "%+.1f lb", $0) } ?? "--",
                                footnote: "Last 7 points",
                                footnoteValue: ""
                            )
                        }
                    }

                    DashboardCard(
                        title: "Measurements",
                        trailing: AnyView(
                            HStack(spacing: 12) {
                                Button { showMeasurementsForm = true } label: {
                                    Label("Add", systemImage: "plus")
                                        .font(.subheadline.weight(.semibold))
                                }

                                NavigationLink {
                                    BodyMeasurementsHistoryView(entries: $bodyMeasurements)
                                } label: {
                                    Label("History", systemImage: "list.bullet")
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                                                    ),
                                                    collapsible: true
                                                ) {
                                                    if let e = latestMeasurements {
                            BodyMeasurementsSummaryView(entry: e, heightIn: assumedHeightIn, deltaWaist4w: waistNavelDelta4w)
                        } else {
                            ContentUnavailableView(
                                "No measurements yet",
                                systemImage: "ruler",
                                description: Text("Add waist measurements to track body comp trends between DXA scans.")
                            )
                        }
                    }

                    DashboardCard(
                        title: "DXA",
                        trailing: AnyView(
                            HStack(spacing: 12) {
                                Button { showDXAForm = true } label: {
                                    Label("Add", systemImage: "plus")
                                        .font(.subheadline.weight(.semibold))
                                }

                                NavigationLink {
                                    DXAHistoryView(scans: $dxaScans)
                                } label: {
                                    Label("History", systemImage: "list.bullet")
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                                                    ),
                                                    collapsible: true
                                                ) {
                                                    if let s = latestDXA {
                            DXASummaryView(scan: s)
                        } else {
                            ContentUnavailableView(
                                "No DXA scans yet",
                                systemImage: "doc.text.magnifyingglass",
                                description: Text("Tap Add to enter your scan values. DXA stays separate from daily readiness, but powers body-comp trends.")
                            )
                        }
                    }

                    DashboardCard(
                        title: "Trends",
                        trailing: AnyView(
                            Button { Task { await backfill7Days() } } label: {
                                Label("Refresh", systemImage: "chart.line.uptrend.xyaxis")
                                    .font(.subheadline.weight(.semibold))
                            }
                                .disabled(isRefreshing)
                                                        ),
                                                        collapsible: true
                                                    ) {
                                                        VStack(alignment: .leading, spacing: 10) {
                                                            Text("Latest value vs median of prior available days · 7-day window")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                                            ForEach(trendSummaries) { s in
                                                                                            HDTrendRow(
                                                                                                summary: s,
                                                                                                onTap: { selectedMetric = $0 },
                                                                                                onBodyTap: { selectedBodyMetric = $0 }
                                                                                            )
                                                                                        }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 20)
            }
            .background(Color(.systemGroupedBackground))
                        .navigationTitle("Health Dashboard")
                        .navigationDestination(item: $selectedMetric) { metric in
                                        MetricDetailView(metric: metric, history: history, readiness: readiness)
                                    }
                                    .navigationDestination(item: $selectedBodyMetric) { metric in
                                        BodyMetricDetailView(metric: metric, history: history, dxaScans: dxaScans)
                                    }
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                snapshot = SharedStore.load()
                history = SharedStore.loadHistory()
                manual = SharedStore.loadManual()
                dxaScans = SharedStore.loadDXAScans()
                bodyMeasurements = SharedStore.loadBodyMeasurements()
                // One explicit evaluation from cached history — holds until the
                // post-fetch assignment in backfill7Days() replaces it.
                readiness = ReadinessEngine.evaluate(history: history, manual: manual)
            }
            .sheet(isPresented: $showDXAForm) {
                DXAFormView(initial: nil) { scan in
                    SharedStore.upsertDXAScan(scan)
                    dxaScans = SharedStore.loadDXAScans()
                }
            }
            .sheet(isPresented: $showMeasurementsForm) {
                BodyMeasurementsFormView(initial: nil) { entry in
                    SharedStore.upsertBodyMeasurement(entry)
                    bodyMeasurements = SharedStore.loadBodyMeasurements()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task { await refreshIfStale(maxAgeSeconds: staleThresholdSeconds) }
            }
            .task {
                await refreshIfStale(maxAgeSeconds: staleThresholdSeconds)
            }
            .task {
                await visibleAutoRefreshLoop()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Consolidated recovery + body metrics")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Persistence
    private func persistManual() {
        SharedStore.saveManual(manual)

        var snap = SharedStore.load()
        snap.updatedAt = Date()
        SharedStore.save(snap)
        snapshot = snap

        // Manual inputs (pain/sick) feed the engine directly — re-evaluate once,
        // explicitly, since readiness is no longer recomputed on every render.
        // Preserve the last-computed sleep composite: manual edits don't change sleep,
        // and segments aren't re-fetched here, so carry it over rather than dropping to nil.
        var reeval = ReadinessEngine.evaluate(history: history, manual: manual)
        reeval.sleepQuality = readiness.sleepQuality
        readiness = reeval

        WidgetCenter.shared.reloadTimelines(ofKind: "HealthDashboardWidget")
    }

    private func backfill7Days() async {
        // Atomic check-and-set on MainActor closes the race window between
        // refreshIfStale's staleness check and this function starting — without
        // this, .task (initial load) and .onChange(scenePhase) firing close together
        // could both pass the staleness check and launch concurrent HK fetches.
        let started = await MainActor.run { () -> Bool in
            guard !isRefreshing else { return false }
            isRefreshing = true
            errorText = nil
            return true
        }
        guard started else { return }
        defer { Task { @MainActor in isRefreshing = false } }

        do {
            try await HealthKitManager.shared.requestAuthorization()
            let points = try await HealthKitManager.shared.fetchLast28Days()

            #if DEBUG
            if let lastDay = points.last?.dayISO {
                try? await HealthKitManager.shared.debugDumpSleepSamplesForDay(lastDay)
            }
            #endif

            await MainActor.run {
                _ = SharedStore.checkAppGroupAccess(tag: "backfill7Days() pre-save")

                SharedStore.saveHistory(points)
                history = points

                // AFTER
                if let last = points.last {
                    print("🧪 Backfill last point day=\(last.dayISO) steps=\(last.steps ?? -1) kcal=\(last.activeEnergyKcal ?? -1) exercise=\(last.exerciseMinutes ?? -1) stand=\(last.standHours ?? -1) workouts=\(last.workoutCount ?? -1)")
                    var snap = SharedStore.load()
                    let cal = Calendar.current
                    let snapIsToday = cal.isDateInToday(snap.updatedAt)

                                        // On a new day, zero load values before writing fresh ones
                                        if !snapIsToday {
                                            snap.stepsToday = 0
                                            snap.activeEnergyTodayKcal = 0
                                            snap.exerciseMinutesToday = 0
                                            snap.standHoursToday = 0
                                            snap.workoutCountToday = 0
                                        }

                                        // RHR is live — always update
                                        if let rhr = last.restingHR { snap.restingHR = Int(rhr.rounded()) }

                    // HRV: lock once written today, but allow correction if value changed
                    let fetchedHRV = last.hrvMS.map { Int($0.rounded()) }
                    let hrvMismatch = fetchedHRV != nil && fetchedHRV != snap.hrv
                    if !snapIsToday || hrvMismatch {
                        if let hrv = last.hrvMS { snap.hrv = Int(hrv.rounded()) }
                    }

                    // Sleep: always write on a new day — independent of HRV
                    // During the same day, allow correction if value changed meaningfully (>5 min)
                    let fetchedSleep = last.sleepHours
                    let sleepMismatch: Bool = {
                        guard let fetched = fetchedSleep, let stored = snap.sleepHours as Double? else { return false }
                        return abs(fetched - stored) > (5.0 / 60.0)  // more than 5 minutes different
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
                    SharedStore.save(snap)
                    snapshot = snap
                }

                // Single post-fetch evaluation with the full 28-day history — the
                // only place evaluate() runs against complete data per refresh cycle.
                var evaluated = ReadinessEngine.evaluate(history: history, manual: manual)
                // Sleep composite (Phase 5): scored from the freshest history + this run's
                // transient raw segments, assigned alongside the readiness result so it rides
                // the Watch payload. Not computed by ReadinessEngine (separate engine).
                evaluated.sleepQuality = SleepQualityEngine.evaluate(
                    history: history,
                    todaySegments: HealthKitManager.shared.lastNightSegments,
                    dumpTrace: true   // headline night only — prints the scored bout list (DEBUG)
                )
                readiness = evaluated

                // Push the result to the Watch (if paired) — exactly once per refresh
                // cycle, right after the engine has run against the freshest history.
                let payload = WatchPayload(
                    result: readiness,
                    last7Days: Array(history.suffix(7).reversed()),
                    updatedAt: Date()
                )
                WatchSessionManager.shared.send(payload)
            }

            WidgetCenter.shared.reloadTimelines(ofKind: "HealthDashboardWidget")
            // Was previously dumped twice (once here, once before reloadTimelines) —
            // each debugDump() call re-reads snapshot/history/manual from UserDefaults
            // purely for logging, doubling the "load() called N times per launch" count
            // for no functional reason since reloadTimelines doesn't change the stored data.
            SharedStore.debugDump(tag: "AFTER Backfill 7 Days")

        } catch {
            await MainActor.run {
                errorText = error.localizedDescription
            }
        }
    }

    // MARK: - Auto refresh helpers
    private func refreshIfStale(maxAgeSeconds: TimeInterval) async {
        guard !isRefreshing else { return }

        await MainActor.run {
            snapshot = SharedStore.load()
            history = SharedStore.loadHistory()
            manual = SharedStore.loadManual()
        }

        let age = Date().timeIntervalSince(snapshot.updatedAt)
        guard age > maxAgeSeconds else { return }

        await backfill7Days()
    }

    private func visibleAutoRefreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(visibleRefreshIntervalSeconds * 1_000_000_000))
            await refreshIfStale(maxAgeSeconds: staleThresholdSeconds)
        }
    }
}
// MARK: - Trend models + row (Sparkline is in Shared/TrendUI.swift)

fileprivate struct TrendSummary: Identifiable {
    let id = UUID()

    let title: String
    let unit: String
    let systemImage: String
    let values: [Double?]
    var metric: HealthMetric? = nil
    var bodyMetric: BodyMetric? = nil

    enum BetterDirection { case higher, lower, neutral }
    let betterDirection: BetterDirection

    let avg: Double?
    let min: Double?
    let max: Double?

    let nowValue: Double?
    let nowIndex: Int?
    let nowDayISO: String?

    let baselineMedian: Double?
    let deltaVsBaseline: Double?
}

fileprivate func fmt(_ v: Double?, digits: Int, unit: String) -> String {
    guard let v else { return "--" }
    return String(format: "%.\(digits)f", v) + (unit.isEmpty ? "" : " \(unit)")
}

fileprivate func fmtSigned(_ v: Double?, digits: Int, unit: String) -> String {
    guard let v else { return "Δ --" }
    return "Δ " + String(format: "%+.\(digits)f", v) + (unit.isEmpty ? "" : " \(unit)")
}

fileprivate func fmtSignedPlain(_ v: Double?, digits: Int, unit: String) -> String {
    guard let v else { return "--" }

    let formatted = String(format: "%+.\(digits)f", v)
    return formatted + (unit.isEmpty ? "" : " \(unit)")
}

fileprivate struct HDTrendRow: View {
    let summary: TrendSummary
    var onTap: ((HealthMetric) -> Void)? = nil
    var onBodyTap: ((BodyMetric) -> Void)? = nil

    private var isLatestPointToday: Bool {
        summary.nowIndex == summary.values.count - 1
    }

    private var nowLabel: String {
        switch summary.title {
        case "Steps", "Active Energy", "Exercise", "Stand", "Workouts", "Workout Time", "Workout Energy":
            return isLatestPointToday ? "Today so far" : "Latest day"

        case "HRV", "Sleep", "Wrist Temp Δ", "Resp Rate", "SpO2":
            return "Latest overnight"

        case "Weight":
            return "Latest weigh-in"

        case "Body Fat", "Lean Mass":
            return "Latest reading"

        case "Resting HR":
            return "Latest"

        default:
            return "Latest"
        }
    }

    private var digits: Int {
        switch summary.title {
        case "Steps", "Active Energy", "Exercise", "Stand", "Workouts", "Workout Time", "Workout Energy":
            return 0
        case "Resting HR", "HRV":
            return 0
        default:
            return 1
        }
    }
    
    fileprivate func fmtTrendValue(_ v: Double?, digits: Int, unit: String, title: String) -> String {
        guard let v else { return "--" }

        if title == "Steps" {
            let nf = NumberFormatter()
            nf.numberStyle = .decimal
            nf.maximumFractionDigits = 0
            return nf.string(from: NSNumber(value: v)) ?? "\(Int(v.rounded()))"
        }

        let value = String(format: "%.\(digits)f", v)
        return value + (unit.isEmpty ? "" : " \(unit)")
    }

    private var deltaColor: Color {
        guard let d = summary.deltaVsBaseline else { return .secondary }
        switch summary.betterDirection {
        case .higher:  return d >= 0 ? .green : .secondary
        case .lower:   return d <= 0 ? .green : .secondary
        case .neutral: return .secondary
        }
    }

    private func fmtDay(_ iso: String?) -> String {
        guard let iso else { return "--" }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        guard let d = df.date(from: iso) else { return iso }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: summary.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(summary.title)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                HDTrendSparkline(values: summary.values)
                    .frame(width: 72, height: 28)
                    .opacity(0.85)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(nowLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(fmtTrendValue(summary.nowValue, digits: digits, unit: summary.unit, title: summary.title))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer()

                if let idx = summary.nowIndex, idx != summary.values.count - 1 {
                    Text("As of \(fmtDay(summary.nowDayISO))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("7d avg")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(fmtTrendValue(summary.avg, digits: digits, unit: summary.unit, title: summary.title))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Vs median")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(fmtSignedPlain(summary.deltaVsBaseline, digits: digits, unit: summary.unit))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(deltaColor)
                        .monospacedDigit()
                }

                if let lo = summary.min, let hi = summary.max {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Range")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text("\(fmtTrendValue(lo, digits: digits, unit: "", title: summary.title))–\(fmtTrendValue(hi, digits: digits, unit: summary.unit, title: summary.title))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
                .overlay(alignment: .trailing) {
                    if summary.metric != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .padding(.trailing, 14)
                    }
                }
                .onTapGesture {
                    if let m = summary.metric { onTap?(m) }
                }
            }
        }

// MARK: - Components (local)

fileprivate struct MetricTile: View {
    let title: String
    var subtitle: String = ""
    let value: String
    let unit: String
    let systemImage: String
    var isDateTime: Bool = false
    var sparkValues: [Double]? = nil
    var delta: Double? = nil
    var deltaUnit: String = ""
    var higherIsBetter: Bool = true
    var metric: HealthMetric? = nil
    var history: [DailyHealthPoint] = []
    var readiness: ReadinessResult? = nil

    var onTap: ((HealthMetric) -> Void)? = nil

        var body: some View {
            Group {
                if let m = metric {
                    tileContent
                        .onTapGesture { onTap?(m) }
                } else {
                    tileContent
                }
            }
        }

        private var tileContent: some View {
            VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let vals = sparkValues, vals.count >= 3 {
                    Sparkline(values: vals.map { Optional($0) })
                        .frame(width: 44, height: 18)
                        .opacity(0.5)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(isDateTime ? .subheadline.weight(.semibold) : .title2.weight(.bold))
                    .lineLimit(isDateTime ? 2 : 1)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(isDateTime ? 0.82 : 0.75)

                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let d = delta {
                let noise = abs(d) < 0.3
                let favorable = higherIsBetter ? d > 0 : d < 0
                let color: Color = noise
                    ? Color.secondary.opacity(0.6)
                    : favorable ? Color.green.opacity(0.8) : Color.orange.opacity(0.9)
                let sign = d > 0 ? "+" : ""
                let numStr = String(format: abs(d) < 10 ? "%.1f" : "%.0f", d)
                Text("\(sign)\(numStr) \(deltaUnit) vs avg")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(color)
            }
        }
        .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.systemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    if metric != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .padding(10)
                    }
                }
                
            }
        }

fileprivate struct BodyRow: View {
    let title: String
    let value: String
    let footnote: String
    let footnoteValue: String
    var onTap: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                if onTap != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }

            if !footnote.isEmpty {
                HStack {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(footnoteValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}

fileprivate func healthMetric(forDriverLabel label: String) -> HealthMetric? {
    switch label {
    case "RHR":               return .rhr
    case "HRV":                return .hrv
    case "Sleep":              return .sleep
    case "Sleep Quality":      return .sleepEff
    case "Respiratory Rate":  return .respRate
    case "Wrist Temp":         return .wristTemp
    case "SpO2":                return .spo2
    default:                    return nil   // Pain, Sick — manual inputs, no detail view
    }
}

fileprivate struct DriverRow: View {
    let display: ReadinessResult.DriverDisplay
    var onTap: ((HealthMetric) -> Void)? = nil

    private var metric: HealthMetric? { healthMetric(forDriverLabel: display.label) }

    private func ordinal(_ n: Int) -> String {
        switch n {
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(n)th"
        }
    }

    private var glyph: String {
        switch display.sentiment {
        case .positive: return "arrow.up.circle.fill"
        case .calm:     return "minus.circle"          // acknowledged, not a factor
        case .warn:     return "arrow.down.circle.fill"
        }
    }

    private var tint: Color {
        switch display.sentiment {
        case .positive: return Color.green.opacity(0.85)
        case .calm:     return Color.secondary.opacity(0.7)
        case .warn:     return Color.orange.opacity(0.85)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph)
                .font(.caption)
                .foregroundStyle(tint)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(display.label)
                        .font(.caption.weight(.semibold))

                    if display.consecutiveDays >= 2 {
                        Text("\(ordinal(display.consecutiveDays)) day")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                Text(display.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if metric != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .padding(.top, 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let m = metric { onTap?(m) }
        }
    }
}

fileprivate struct StatusPill: View {
    let title: String
    let status: ReadinessStatus

    private var bg: Color {
        switch status {
        case .green: return Color(.systemGreen).opacity(0.18)
        case .yellow: return Color(.systemOrange).opacity(0.18)
        case .red: return Color(.systemRed).opacity(0.18)
        }
    }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.bold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(bg)
            .clipShape(Capsule())
    }
}
