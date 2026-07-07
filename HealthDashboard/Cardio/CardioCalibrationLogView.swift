import SwiftUI

// MARK: - Cardio Calibration Log (VO2max capture-first slice)
//
// One screen, two regions: a FORM on top to capture/edit a single steady-state
// segment, and a HISTORY list below to delete/edit stored points. It converts
// speed→m/min and %grade→decimal, computes VO2 via the ACSM transform, and
// persists CardioCalibrationPoints to the HD App Group.
//
// HR is NOT read from a bare clock window: it's resolved from the overlapping
// HKWorkout (see HealthKitManager.resolveSteadyStateHR) because the strap only
// reaches HealthKit — attributed to "Apple Watch" — while a workout is running.
// There is deliberately NO manual HR field.
//
// This screen does NOT estimate VO2max, touch readiness, or fit a regression.

struct CardioCalibrationLogView: View {

    // Submaximal calibration band. HR should sit meaningfully below true max but
    // high enough to be metabolically informative — a submaximal steady state.
    private static let trueMaxHR = 170.0
    private static let calibrationHRFloorFraction   = 0.60   // ≈ 102 bpm
    private static let calibrationHRCeilingFraction = 0.85   // ≈ 145 bpm

    private var hrFloor: Double   { Self.trueMaxHR * Self.calibrationHRFloorFraction }
    private var hrCeiling: Double { Self.trueMaxHR * Self.calibrationHRCeilingFraction }

    // MARK: Inputs (the draft — new point, or the one being edited)
    @State private var editingID: UUID?          // nil = new point; set = editing an existing one
    @State private var editingOriginal: CardioCalibrationPoint?  // the stored point being edited (carries its provenance)
    @State private var activityType: CardioActivityType = .walk
    @State private var speedMph: Double = 3.0
    @State private var inclinePercent: Double = 0.0
    @State private var startTime: Date = Calendar.current.date(byAdding: .minute, value: -12, to: Date()) ?? Date()
    @State private var endTime: Date = Date()

    // MARK: Resolved HR + flow state
    // resolvedHR is the bpm that will be SAVED. It comes from a fresh workout-anchored
    // pull (provenance non-nil) or is carried from a point being edited (provenance nil).
    // hrSourceWindow records the [start,end] the HR corresponds to, so changing the
    // window invalidates it and forces a re-pull (see hrValidForWindow).
    @State private var resolvedHR: Double?
    @State private var provenance: HealthKitManager.SteadyStateHRResult?
    @State private var hrSourceWindow: DateInterval?
    @State private var isPulling = false
    @State private var errorText: String?
    @State private var overrideCeiling = false
    @State private var confirmation: String?

    // MARK: History + delete confirmation
    @State private var points: [CardioCalibrationPoint] = CardioCalibrationStore.loadAll()
    @State private var pendingDelete: CardioCalibrationPoint?

    // MARK: Derived
    private var speedMetersPerMin: Double { speedMph * CardioMetabolics.mphToMetersPerMin }
    private var gradeDecimal: Double { inclinePercent * CardioMetabolics.percentGradeToDecimal }
    private var durationSeconds: Double { max(0, endTime.timeIntervalSince(startTime)) }
    /// Duration to display and persist: a fresh pull's HR covers marked ∩ workout, so the
    /// resolved interval — not the wider marked window — describes the segment. Falls back
    /// to the marked-window duration before a pull (and, on a carried edit with the window
    /// unchanged, that equals the stored point's duration).
    private var effectiveDurationSeconds: Double {
        provenance?.resolvedInterval.duration ?? durationSeconds
    }
    private var markedWindow: DateInterval {
        DateInterval(start: min(startTime, endTime), end: max(startTime, endTime))
    }
    private var previewVO2: Double {
        CardioMetabolics.computeVO2(
            activityType: activityType,
            speedMetersPerMin: speedMetersPerMin,
            gradeDecimal: gradeDecimal
        )
    }

    /// True only when a resolved HR corresponds to the CURRENTLY shown window. Editing
    /// the start/end after a pull makes this false → Save disabled until a re-pull.
    private var hrValidForWindow: Bool {
        guard resolvedHR != nil, let w = hrSourceWindow else { return false }
        return w == markedWindow
    }
    private var aboveBand: Bool { (resolvedHR ?? 0) > hrCeiling && resolvedHR != nil }
    private var belowBand: Bool { (resolvedHR ?? .greatestFiniteMagnitude) < hrFloor && resolvedHR != nil }

    private var canSave: Bool {
        guard hrValidForWindow, durationSeconds > 0, speedMph > 0 else { return false }
        // Above ceiling blocks save unless the user explicitly overrides.
        return !(aboveBand && !overrideCeiling)
    }

    private var pointsNewestFirst: [CardioCalibrationPoint] {
        points.sorted { $0.date > $1.date }
    }

    var body: some View {
        Form {
            Section(editingID == nil ? "New segment" : "Editing segment") {
                Picker("Activity", selection: $activityType) {
                    Text(CardioActivityType.walk.title).tag(CardioActivityType.walk)
                    Text(CardioActivityType.run.title).tag(CardioActivityType.run)
                }
                .pickerStyle(.segmented)

                Stepper(value: $speedMph, in: 0.5...12.0, step: 0.1) {
                    LabeledContent("Speed", value: String(format: "%.1f mph", speedMph))
                }
                Stepper(value: $inclinePercent, in: 0.0...20.0, step: 0.5) {
                    LabeledContent("Incline", value: String(format: "%.1f%%", inclinePercent))
                }

                DatePicker("Start", selection: $startTime, displayedComponents: [.date, .hourAndMinute])
                DatePicker("End", selection: $endTime, displayedComponents: [.date, .hourAndMinute])
            }

            Section("Steady-state HR") {
                Button {
                    Task { await pullHR() }
                } label: {
                    if isPulling {
                        HStack { ProgressView(); Text("Pulling…") }
                    } else {
                        Label("Pull HR from workout", systemImage: "heart.fill")
                    }
                }
                .disabled(isPulling || durationSeconds <= 0)

                if let hr = resolvedHR {
                    // Provenance line the user can eyeball before saving.
                    if let p = provenance {
                        Text(provenanceLine(p))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else if let orig = editingOriginal {
                        // Carried edit (no re-pull): reconstruct the real attribution from the
                        // point's stored provenance, or a neutral label for a pre-audit point.
                        Text(storedProvenanceLine(orig))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(format: "%.0f bpm", hr))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Text(String(format: "Calibration band ≈ %.0f–%.0f bpm", hrFloor, hrCeiling))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !hrValidForWindow {
                        Text("Window changed since this HR was resolved — pull HR again.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if aboveBand {
                        Text("Above the submaximal calibration band — this segment is too hard to be a clean calibration point. Saving is blocked unless you override.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Toggle("Save anyway (override)", isOn: $overrideCeiling)
                    } else if belowBand {
                        Text("Below the calibration band — likely too easy to be informative. You can still save it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Computed") {
                LabeledContent("VO₂ (ACSM)", value: String(format: "%.1f mL/kg/min", previewVO2))
                LabeledContent("Duration", value: String(format: "%.0f s", effectiveDurationSeconds))
            }

            if let confirmation {
                Section {
                    Text(confirmation)
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
            }

            Section {
                Button(editingID == nil ? "Save calibration point" : "Save changes") { save() }
                    .disabled(!canSave)
                if editingID != nil {
                    Button("Cancel edit", role: .cancel) { resetDraft() }
                }
            }

            Section("Logged points") {
                if pointsNewestFirst.isEmpty {
                    Text("No calibration points yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pointsNewestFirst) { p in
                        Button { beginEdit(p) } label: { pointRow(p) }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = p } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Cardio Calibration")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete this calibration point?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { p in
            Button("Delete", role: .destructive) { performDelete(p) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This changes the calibration set the future regression will fit.")
        }
    }

    // MARK: Row

    @ViewBuilder
    private func pointRow(_ p: CardioCalibrationPoint) -> some View {
        let mph = p.speedMetersPerMin / CardioMetabolics.mphToMetersPerMin
        let pct = p.gradeDecimal / CardioMetabolics.percentGradeToDecimal
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(p.activityType.title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(p.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(String(
                format: "%.1f mph • %.1f%% • %.0f bpm • VO₂ %.1f",
                mph, pct, p.steadyStateHR, p.computedVO2
            ))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    // MARK: Actions

    private func pullHR() async {
        errorText = nil
        confirmation = nil
        overrideCeiling = false
        isPulling = true
        defer { isPulling = false }

        do {
            try await HealthKitManager.shared.requestAuthorization()
            let resolution = try await HealthKitManager.shared.resolveSteadyStateHR(from: startTime, to: endTime)
            switch resolution {
            case .resolved(let r):
                resolvedHR = r.averageBPM
                provenance = r
                hrSourceWindow = markedWindow
            case .noWorkout:
                resolvedHR = nil
                provenance = nil
                hrSourceWindow = nil
                errorText = "No Apple Workout found for this window — record the steady segment as a Workout with the strap paired, then pull again."
            case .insufficientSamples(let count):
                resolvedHR = nil
                provenance = nil
                hrSourceWindow = nil
                errorText = "Too few HR samples (\(count)) in that window — need at least \(HealthKitManager.minSteadyStateHRSampleCount). Widen the window or re-record the segment as a strap-paired Workout."
            }
        } catch {
            resolvedHR = nil
            provenance = nil
            hrSourceWindow = nil
            errorText = "Couldn’t read HR: \(error.localizedDescription)"
        }
    }

    private func save() {
        guard let hr = resolvedHR, hrValidForWindow else { return }

        // Provenance + duration source:
        //  • fresh pull → take everything from the resolved result (duration = the resolved
        //    marked ∩ workout interval, NOT the wider marked window).
        //  • carried edit (no re-pull) → preserve the original point's provenance and its
        //    stored durationSeconds untouched.
        let sampleCount: Int?
        let sourceName: String?
        let resolvedInterval: DateInterval?
        let workoutUUID: UUID?
        let duration: Double
        if let p = provenance {
            sampleCount = p.sampleCount
            sourceName = p.workoutSourceName
            resolvedInterval = p.resolvedInterval
            workoutUUID = p.workoutUUID
            duration = p.resolvedInterval.duration
        } else if let orig = editingOriginal {
            sampleCount = orig.hrSampleCount
            sourceName = orig.hrSourceName
            resolvedInterval = orig.hrResolvedInterval
            workoutUUID = orig.workoutUUID
            duration = orig.durationSeconds
        } else {
            sampleCount = nil; sourceName = nil; resolvedInterval = nil; workoutUUID = nil
            duration = durationSeconds
        }

        let point = CardioCalibrationPoint(
            id: editingID ?? UUID(),          // preserve id on edit; fresh id on new
            date: startTime,
            activityType: activityType,
            speedMetersPerMin: speedMetersPerMin,
            gradeDecimal: gradeDecimal,
            steadyStateHR: hr,
            computedVO2: previewVO2,
            durationSeconds: duration,
            hrSampleCount: sampleCount,
            hrSourceName: sourceName,
            hrResolvedInterval: resolvedInterval,
            workoutUUID: workoutUUID
        )

        let wasEditing = editingID != nil
        if wasEditing {
            CardioCalibrationStore.update(point)
        } else {
            CardioCalibrationStore.append(point)
        }
        points = CardioCalibrationStore.loadAll()
        let windowCount = CardioCalibrationStore.pointsInWindow().count

        confirmation = String(
            format: "%@ · VO₂ %.1f mL/kg/min @ %.0f bpm · %d point%@ in the last %d days.",
            wasEditing ? "Updated" : "Saved",
            point.computedVO2, hr,
            windowCount, windowCount == 1 ? "" : "s",
            CardioCalibrationStore.calibrationWindowDays
        )
        resetDraft(keepConfirmation: true)
    }

    private func beginEdit(_ p: CardioCalibrationPoint) {
        editingID = p.id
        editingOriginal = p              // retain stored provenance for a no-re-pull save
        activityType = p.activityType
        speedMph = p.speedMetersPerMin / CardioMetabolics.mphToMetersPerMin
        inclinePercent = p.gradeDecimal / CardioMetabolics.percentGradeToDecimal
        startTime = p.date
        endTime = p.date.addingTimeInterval(p.durationSeconds)
        // Carry the stored HR as already-valid for its window; provenance is unknown
        // (never persisted). Changing speed/grade recomputes VO2 without a re-pull;
        // changing the window invalidates this via hrValidForWindow → forces a re-pull.
        resolvedHR = p.steadyStateHR
        provenance = nil
        hrSourceWindow = DateInterval(start: min(startTime, endTime), end: max(startTime, endTime))
        overrideCeiling = false
        errorText = nil
        confirmation = nil
    }

    private func performDelete(_ p: CardioCalibrationPoint) {
        CardioCalibrationStore.delete(id: p.id)
        points = CardioCalibrationStore.loadAll()
        pendingDelete = nil
        // If the deleted point was the one being edited, drop back to new-point mode.
        if editingID == p.id { resetDraft() }
    }

    private func resetDraft(keepConfirmation: Bool = false) {
        editingID = nil
        editingOriginal = nil
        resolvedHR = nil
        provenance = nil
        hrSourceWindow = nil
        overrideCeiling = false
        errorText = nil
        if !keepConfirmation { confirmation = nil }
    }

    // MARK: Formatting

    private func provenanceLine(_ p: HealthKitManager.SteadyStateHRResult) -> String {
        let lo = p.resolvedInterval.start.formatted(date: .omitted, time: .shortened)
        let hi = p.resolvedInterval.end.formatted(date: .omitted, time: .shortened)
        return String(
            format: "%.0f bpm • %d samples • %@ • %@–%@",
            p.averageBPM, p.sampleCount, p.workoutSourceName, lo, hi
        )
    }

    /// Reconstructs the provenance line for an edited point from its STORED fields. A
    /// pre-audit point (all-nil provenance) gets a neutral label rather than a fabricated one.
    private func storedProvenanceLine(_ p: CardioCalibrationPoint) -> String {
        guard
            let count = p.hrSampleCount,
            let source = p.hrSourceName,
            let interval = p.hrResolvedInterval
        else {
            return String(format: "%.0f bpm • no provenance (pre-audit point)", p.steadyStateHR)
        }
        let lo = interval.start.formatted(date: .omitted, time: .shortened)
        let hi = interval.end.formatted(date: .omitted, time: .shortened)
        return String(
            format: "%.0f bpm • %d samples • %@ • %@–%@",
            p.steadyStateHR, count, source, lo, hi
        )
    }
}

#Preview {
    NavigationStack { CardioCalibrationLogView() }
}
