import SwiftUI

// MARK: - ISO helpers

enum ISODate {
    static let formatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    static func toISO(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func fromISO(_ iso: String) -> Date? {
        formatter.date(from: iso)
    }
}

// MARK: - Small formatting helpers

fileprivate func fmt(_ v: Double?, _ format: String) -> String {
    guard let v else { return "--" }
    return String(format: format, v)
}

// MARK: - DXA: Dashboard compact summary

struct DXASummaryView: View {
    let scan: DXAScan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Scan: \(displayDate(scan.dateISO))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let device = scan.device, !device.isEmpty {
                    Text(device)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            let cols = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, spacing: 10) {
                DXAMetricTile(title: "Body Fat", subtitle: "DXA", value: fmt(scan.bodyFatPct, "%.1f"), unit: "%", systemImage: "percent")
                DXAMetricTile(title: "Lean Mass", subtitle: "DXA", value: fmt(scan.leanMassLb, "%.1f"), unit: "lb", systemImage: "figure.strengthtraining.traditional")
                DXAMetricTile(title: "Fat Mass", subtitle: "DXA", value: fmt(scan.fatMassLb, "%.1f"), unit: "lb", systemImage: "drop")
                DXAMetricTile(title: "Weight", subtitle: "DXA", value: fmt(scan.weightLb, "%.1f"), unit: "lb", systemImage: "scalemass")

                // Visceral is the “so what” signal for your goals
                DXAMetricTile(title: "VAT Mass", subtitle: "Visceral", value: fmt(scan.vatMassLb, "%.2f"), unit: "lb", systemImage: "person.crop.circle")
                DXAMetricTile(title: "A/G Ratio", subtitle: "Distribution", value: fmt(scan.androidGynoidRatio, "%.2f"), unit: "", systemImage: "chart.pie")
            }
        }
    }

    private func displayDate(_ iso: String) -> String {
        if let d = ISODate.fromISO(iso) {
            return d.formatted(date: .abbreviated, time: .omitted)
        }
        return iso
    }
}

// MARK: - Local tile (kept separate from ContentView's fileprivate MetricTile)

fileprivate struct DXAMetricTile: View {
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

// MARK: - DXA: History list + edit/delete

struct DXAHistoryView: View {
    @Binding var scans: [DXAScan]

    @State private var showForm = false
    @State private var editing: DXAScan?

    var body: some View {
        List {
            if scans.isEmpty {
                ContentUnavailableView("No DXA scans yet", systemImage: "doc.text.magnifyingglass", description: Text("Add your first DXA scan to start trends."))
            } else {
                ForEach(scans.sorted(by: { $0.dateISO > $1.dateISO })) { s in
                    Button {
                        editing = s
                        showForm = true
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(displayDate(s.dateISO))
                                    .font(.headline)
                                Spacer()
                                Text("BF \(fmt(s.bodyFatPct, "%.1f"))%")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 14) {
                                Text("Lean \(fmt(s.leanMassLb, "%.1f")) lb")
                                Text("Fat \(fmt(s.fatMassLb, "%.1f")) lb")
                                Text("VAT \(fmt(s.vatMassLb, "%.2f")) lb")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            SharedStore.deleteDXAScan(dateISO: s.dateISO)
                            scans = SharedStore.loadDXAScans()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("DXA Scans")
        .toolbar {
            Button {
                editing = nil
                showForm = true
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showForm) {
            DXAFormView(
                initial: editing,
                onSave: { scan in
                    SharedStore.upsertDXAScan(scan)
                    scans = SharedStore.loadDXAScans()
                }
            )
        }
        .onAppear {
            scans = SharedStore.loadDXAScans()
        }
    }

    private func displayDate(_ iso: String) -> String {
        if let d = ISODate.fromISO(iso) {
            return d.formatted(date: .abbreviated, time: .omitted)
        }
        return iso
    }
}

// MARK: - DXA: Add/Edit form (manual entry; stable)

struct DXAFormView: View {
    @Environment(\.dismiss) private var dismiss

    let initial: DXAScan?
    let onSave: (DXAScan) -> Void

    @State private var date: Date
    @State private var device: String
    @State private var heightIn: String
    @State private var weightLb: String
    @State private var totalMassLb: String
    @State private var leanMassLb: String
    @State private var fatMassLb: String
    @State private var bodyFatPct: String
    @State private var androidFatPct: String
    @State private var gynoidFatPct: String
    @State private var androidGynoidRatio: String
    @State private var vatVolumeCm3: String
    @State private var vatMassLb: String
    @State private var vatAreaCm2: String
    @State private var rmrKcalPerDay: String
    @State private var totalBmd: String
    @State private var totalTScore: String

    init(initial: DXAScan?, onSave: @escaping (DXAScan) -> Void) {
        self.initial = initial
        self.onSave = onSave

        let d = initial.flatMap { ISODate.fromISO($0.dateISO) } ?? Date()
        _date = State(initialValue: d)
        _device = State(initialValue: initial?.device ?? "")

        func s(_ v: Double?, _ f: String = "%.1f") -> String { v.map { String(format: f, $0) } ?? "" }
        _heightIn = State(initialValue: s(initial?.heightIn))
        _weightLb = State(initialValue: s(initial?.weightLb))
        _totalMassLb = State(initialValue: s(initial?.totalMassLb))
        _leanMassLb = State(initialValue: s(initial?.leanMassLb))
        _fatMassLb = State(initialValue: s(initial?.fatMassLb))
        _bodyFatPct = State(initialValue: s(initial?.bodyFatPct))
        _androidFatPct = State(initialValue: s(initial?.androidFatPct))
        _gynoidFatPct = State(initialValue: s(initial?.gynoidFatPct))
        _androidGynoidRatio = State(initialValue: s(initial?.androidGynoidRatio, "%.2f"))
        _vatVolumeCm3 = State(initialValue: s(initial?.vatVolumeCm3, "%.1f"))
        _vatMassLb = State(initialValue: s(initial?.vatMassLb, "%.2f"))
        _vatAreaCm2 = State(initialValue: s(initial?.vatAreaCm2, "%.2f"))
        _rmrKcalPerDay = State(initialValue: initial?.rmrKcalPerDay.map { String($0) } ?? "")
        _totalBmd = State(initialValue: s(initial?.totalBmd, "%.3f"))
        _totalTScore = State(initialValue: s(initial?.totalTScore, "%.1f"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Scan") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Device (optional)", text: $device)
                }

                Section("Core") {
                    numField("Height (in)", text: $heightIn)
                    numField("Weight (lb)", text: $weightLb)
                    numField("Total Mass (lb)", text: $totalMassLb)
                    numField("Lean Mass (lb)", text: $leanMassLb)
                    numField("Fat Mass (lb)", text: $fatMassLb)
                    numField("Body Fat (%)", text: $bodyFatPct)
                }

                Section("Visceral (VAT)") {
                    numField("VAT Mass (lb)", text: $vatMassLb)
                    numField("VAT Area (cm²)", text: $vatAreaCm2)
                    numField("VAT Volume (cm³)", text: $vatVolumeCm3)
                }

                Section("Distribution") {
                    numField("Android Fat (%)", text: $androidFatPct)
                    numField("Gynoid Fat (%)", text: $gynoidFatPct)
                    numField("Android/Gynoid Ratio", text: $androidGynoidRatio)
                }

                Section("Optional") {
                    TextField("RMR (kcal/day)", text: $rmrKcalPerDay)
                        .keyboardType(.numberPad)
                    numField("Total BMD", text: $totalBmd)
                    numField("Total T-Score", text: $totalTScore)
                }
            }
            .navigationTitle(initial == nil ? "Add DXA" : "Edit DXA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let scan = buildScan()
                        onSave(scan)
                        dismiss()
                    }
                }
            }
        }
    }

    private func numField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .keyboardType(.decimalPad)
    }

    private func d(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    private func i(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Int(trimmed)
    }

    private func buildScan() -> DXAScan {
        DXAScan(
            dateISO: ISODate.toISO(date),
            device: device.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : device,
            heightIn: d(heightIn),
            weightLb: d(weightLb),
            totalMassLb: d(totalMassLb),
            leanMassLb: d(leanMassLb),
            fatMassLb: d(fatMassLb),
            bodyFatPct: d(bodyFatPct),
            androidFatPct: d(androidFatPct),
            gynoidFatPct: d(gynoidFatPct),
            androidGynoidRatio: d(androidGynoidRatio),
            vatVolumeCm3: d(vatVolumeCm3),
            vatMassLb: d(vatMassLb),
            vatAreaCm2: d(vatAreaCm2),
            rmrKcalPerDay: i(rmrKcalPerDay),
            totalBmd: d(totalBmd),
            totalTScore: d(totalTScore)
        )
    }
}


