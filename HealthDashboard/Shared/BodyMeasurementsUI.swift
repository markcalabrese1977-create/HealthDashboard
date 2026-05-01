import SwiftUI

// MARK: - Formatting

fileprivate func fmtIn(_ v: Double?) -> String {
    guard let v else { return "--" }
    return String(format: "%.1f", v)
}

fileprivate func fmtSignedIn(_ v: Double?) -> String {
    guard let v else { return "--" }
    return String(format: "%+.1f", v)
}

fileprivate func displayDate(_ iso: String) -> String {
    if let d = ISODate.fromISO(iso) {
        return d.formatted(date: .abbreviated, time: .omitted)
    }
    return iso
}

// MARK: - Dashboard compact summary

struct BodyMeasurementsSummaryView: View {
    let entry: BodyMeasurementEntry
    let heightIn: Double
    let deltaWaist4w: Double?

    private var whtR: Double? {
        guard heightIn > 0, let w = entry.waistNavelIn else { return nil }
        return w / heightIn
    }

    private var whr: Double? {
        guard let w = entry.waistNavelIn, let h = entry.hipIn, h > 0 else { return nil }
        return w / h
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("As of: \(displayDate(entry.dateISO))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let dw = deltaWaist4w {
                    Text("4w Δ \(fmtSignedIn(dw))\" ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            let cols = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, spacing: 10) {
                MeasurementTile(title: "Waist (navel)", subtitle: "Primary", value: fmtIn(entry.waistNavelIn), unit: "in", systemImage: "circle.dashed")
                MeasurementTile(title: "Waist (narrow)", subtitle: "Secondary", value: fmtIn(entry.waistNarrowIn), unit: "in", systemImage: "circle")
                MeasurementTile(title: "Hip", subtitle: "For WHR", value: fmtIn(entry.hipIn), unit: "in", systemImage: "figure.walk")
                MeasurementTile(title: "WHtR", subtitle: "Waist/Height", value: whtR.map { String(format: "%.3f", $0) } ?? "--", unit: "", systemImage: "ruler")
                MeasurementTile(title: "WHR", subtitle: "Waist/Hip", value: whr.map { String(format: "%.3f", $0) } ?? "--", unit: "", systemImage: "chart.pie")
                MeasurementTile(title: "Arm (flexed)", subtitle: "Optional", value: fmtIn(entry.upperArmFlexedIn), unit: "in", systemImage: "dumbbell")
                MeasurementTile(title: "Thigh (mid)", subtitle: "Optional", value: fmtIn(entry.thighMidIn), unit: "in", systemImage: "figure.strengthtraining.traditional")
            }
        }
    }
}

fileprivate struct MeasurementTile: View {
    let title: String
    let subtitle: String
    let value: String
    let unit: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title3.bold())
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

// MARK: - History list + edit/delete

struct BodyMeasurementsHistoryView: View {
    @Binding var entries: [BodyMeasurementEntry]

    @State private var showForm = false
    @State private var editing: BodyMeasurementEntry?

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No measurements yet",
                    systemImage: "ruler",
                    description: Text("Add waist measurements to track body comp trends between DXA scans.")
                )
            } else {
                ForEach(entries.sorted(by: { $0.dateISO > $1.dateISO })) { e in
                    Button {
                        editing = e
                        showForm = true
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(displayDate(e.dateISO))
                                    .font(.headline)
                                Spacer()
                                Text("Waist \(fmtIn(e.waistNavelIn))\"")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 14) {
                                Text("Hip \(fmtIn(e.hipIn))\"")
                                Text("Arm \(fmtIn(e.upperArmFlexedIn))\"")
                                Text("Thigh \(fmtIn(e.thighMidIn))\"")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            SharedStore.deleteBodyMeasurement(dateISO: e.dateISO)
                            entries = SharedStore.loadBodyMeasurements()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Body Measurements")
        .toolbar {
            Button {
                editing = nil
                showForm = true
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showForm) {
            BodyMeasurementsFormView(
                initial: editing,
                onSave: { entry in
                    SharedStore.upsertBodyMeasurement(entry)
                    entries = SharedStore.loadBodyMeasurements()
                }
            )
        }
        .onAppear {
            entries = SharedStore.loadBodyMeasurements()
        }
    }
}

// MARK: - Add/Edit form

struct BodyMeasurementsFormView: View {
    @Environment(\.dismiss) private var dismiss

    let initial: BodyMeasurementEntry?
    let onSave: (BodyMeasurementEntry) -> Void

    @State private var date: Date
    @State private var waistNavelIn: String
    @State private var waistNarrowIn: String
    @State private var hipIn: String
    @State private var upperArmFlexedIn: String
    @State private var thighMidIn: String
    @State private var note: String

    init(initial: BodyMeasurementEntry?, onSave: @escaping (BodyMeasurementEntry) -> Void) {
        self.initial = initial
        self.onSave = onSave

        let d = initial.flatMap { ISODate.fromISO($0.dateISO) } ?? Date()
        _date = State(initialValue: d)

        func s(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
        _waistNavelIn = State(initialValue: s(initial?.waistNavelIn))
        _waistNarrowIn = State(initialValue: s(initial?.waistNarrowIn))
        _hipIn = State(initialValue: s(initial?.hipIn))
        _upperArmFlexedIn = State(initialValue: s(initial?.upperArmFlexedIn))
        _thighMidIn = State(initialValue: s(initial?.thighMidIn))
        _note = State(initialValue: initial?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    DatePicker("Measurement date", selection: $date, displayedComponents: .date)
                }

                Section("Core") {
                    TextField("Waist at navel (in)", text: $waistNavelIn)
                        .keyboardType(.decimalPad)
                    TextField("Waist narrowest (in)", text: $waistNarrowIn)
                        .keyboardType(.decimalPad)
                    TextField("Hips (widest glutes) (in)", text: $hipIn)
                        .keyboardType(.decimalPad)
                }

                Section("Optional") {
                    TextField("Upper arm flexed (in)", text: $upperArmFlexedIn)
                        .keyboardType(.decimalPad)
                    TextField("Thigh mid (in)", text: $thighMidIn)
                        .keyboardType(.decimalPad)
                }

                Section("Notes") {
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                }

                Section {
                    Text("Measurement rules: relaxed exhale, same tape/spot, don’t crank tight.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(initial == nil ? "Add Measurements" : "Edit Measurements")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let entry = BodyMeasurementEntry(
                            dateISO: ISODate.toISO(date),
                            waistNavelIn: Double(waistNavelIn),
                            waistNarrowIn: Double(waistNarrowIn),
                            hipIn: Double(hipIn),
                            upperArmFlexedIn: Double(upperArmFlexedIn),
                            thighMidIn: Double(thighMidIn),
                            note: note.isEmpty ? nil : note
                        )
                        onSave(entry)
                        dismiss()
                    }
                    .disabled(Double(waistNavelIn) == nil)
                }
            }
        }
    }
}
