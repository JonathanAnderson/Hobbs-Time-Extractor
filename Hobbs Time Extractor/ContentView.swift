//
//  ContentView.swift
//  Time Extractor
//
//  Created by Jonathan Anderson on 5/13/25.
//

import SwiftUI
import UniformTypeIdentifiers
import Foundation

// MARK: - FlightRecord

/// FlightTime paired with its nearest departure/arrival airports (nil until airport DB loads).
struct FlightRecord: Identifiable {
    let flight: FlightTime
    let departure: AirportRecord?
    let arrival: AirportRecord?
    var id: String { flight.fileName }
}

// MARK: - Sort order

enum FlightSortOrder: String, CaseIterable, Identifiable {
    case importOrder = "Added"
    case fileName    = "Name"
    case startTime   = "Date"
    case duration    = "Duration"
    var id: String { rawValue }
}

// MARK: - ContentView

struct ContentView: View {
    @State private var showImporter = false
    @State private var records: [FlightRecord] = []
    @State private var airports: [AirportRecord] = []
    @State private var errorMessage: String?
    @State private var sortOrder: FlightSortOrder = .importOrder

    private var sorted: [FlightRecord] {
        switch sortOrder {
        case .importOrder: return records
        case .fileName:    return records.sorted { $0.flight.fileName.localizedStandardCompare($1.flight.fileName) == .orderedAscending }
        case .startTime:   return records.sorted { $0.flight.start < $1.flight.start }
        case .duration:    return records.sorted { (Double($0.flight.dt) ?? 0) > (Double($1.flight.dt) ?? 0) }
        }
    }

    private var maxDuration: Double {
        records.compactMap { Double($0.flight.dt) }.max() ?? 1
    }

    private var totalHours: Double {
        records.compactMap { Double($0.flight.dt) }.reduce(0, +)
    }

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    emptyState
                } else {
                    flightList
                }
            }
            .navigationTitle("Hobbs Time")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showImporter.toggle() } label: {
                        Image(systemName: "plus.circle.fill")
                            .imageScale(.large)
                    }
                }
                if !records.isEmpty {
                    ToolbarItem(placement: .automatic) {
                        Menu {
                            Picker("Sort by", selection: $sortOrder) {
                                ForEach(FlightSortOrder.allCases) { order in
                                    Label(order.rawValue, systemImage: sortIcon(for: order))
                                        .tag(order)
                                }
                            }
                            Divider()
                            Button(role: .destructive) {
                                withAnimation { records.removeAll() }
                            } label: {
                                Label("Clear All", systemImage: "trash")
                            }
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                        }
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [UTType.commaSeparatedText],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    errorMessage = nil
                    let existing = Set(records.map { $0.flight.fileName })
                    let new = urls
                        .filter { !existing.contains($0.lastPathComponent) }
                        .map { url -> FlightRecord in
                            let ft = GarminExtractor.extract(from: url)
                            return FlightRecord(
                                flight: ft,
                                departure: airportFor(ft.firstCoordinate),
                                arrival:   airportFor(ft.lastCoordinate)
                            )
                        }
                    withAnimation { records.append(contentsOf: new) }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .alert("Import Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                guard airports.isEmpty,
                      let loaded = try? AirportBinaryReader.loadFromBundle()
                else { return }
                airports = loaded
                // Backfill any records imported before airports finished loading
                records = records.map {
                    FlightRecord(
                        flight: $0.flight,
                        departure: airportFor($0.flight.firstCoordinate),
                        arrival:   airportFor($0.flight.lastCoordinate)
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    private func airportFor(_ coord: Coordinate?) -> AirportRecord? {
        guard let coord, !airports.isEmpty else { return nil }
        return nearestAirport(
            latitudeDegrees: coord.latitude,
            longitudeDegrees: coord.longitude,
            airports: airports
        )?.airport
    }

    private func sortIcon(for order: FlightSortOrder) -> String {
        switch order {
        case .importOrder: return "clock"
        case .fileName:    return "textformat.abc"
        case .startTime:   return "calendar"
        case .duration:    return "timer"
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "airplane.circle")
                .font(.system(size: 72))
                .foregroundStyle(.quaternary)
            Text("No Flights")
                .font(.title2.weight(.semibold))
            Text("Import one or more Garmin G1000\nCSV export files to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showImporter.toggle()
            } label: {
                Label("Import CSVs", systemImage: "plus.circle.fill")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var flightList: some View {
        List {
            Section {
                ForEach(sorted) { record in
                    FlightRow(record: record, maxDuration: maxDuration)
                }
                .onDelete { indexSet in
                    let items = sorted
                    let ids = Set(indexSet.map { items[$0].id })
                    withAnimation { records.removeAll { ids.contains($0.id) } }
                }
            }

            Section {
                HStack {
                    Text("\(records.count) flight\(records.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f h total", totalHours))
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
            }
        }
        .listStyle(.inset)
    }
}

// MARK: - FlightRow

struct FlightRow: View {
    let record: FlightRecord
    let maxDuration: Double

    private var flight: FlightTime { record.flight }

    private var displayName: String {
        var n = flight.fileName
        if n.lowercased().hasSuffix(".csv") { n = String(n.dropLast(4)) }
        return n
    }

    private var timeRange: String {
        guard flight.start != "N/A" else { return "Could not parse file" }
        let s = flight.start, e = flight.end
        let sd = String(s.prefix(10)), ed = String(e.prefix(10))
        let st = s.count >= 16 ? String(s.dropFirst(11).prefix(5)) : ""
        let et = e.count >= 16 ? String(e.dropFirst(11).prefix(5)) : ""
        return sd == ed
            ? "\(sd)  \(st)–\(et) UTC"
            : "\(String(s.prefix(16)))–\(String(e.prefix(16))) UTC"
    }

    private var isParsed: Bool { flight.start != "N/A" && !flight.dt.isEmpty }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                routeLabel

                Text(timeRange)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 8)

            if isParsed {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(flight.dt)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.tint)
                    Text("h")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("—")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var routeLabel: some View {
        if let dep = record.departure, let arr = record.arrival {
            if dep.identifier == arr.identifier {
                Text(dep.identifier)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            } else {
                HStack(spacing: 4) {
                    Text(dep.identifier)
                    Image(systemName: "arrow.right")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                    Text(arr.identifier)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            }
        }
    }
}

// MARK: - Previews

#Preview("Empty") {
    ContentView()
}

#Preview("Flights") {
    FlightListPreview()
}

private struct FlightListPreview: View {
    @State private var records: [FlightRecord] = [
        FlightRecord(
            flight: FlightTime(fileName: "log_2025-03-17.csv",
                               start: "2025-03-17 14:59:11", end: "2025-03-17 16:42:08",
                               dt: "1.7", firstCoordinate: nil, lastCoordinate: nil),
            departure: nil, arrival: nil
        ),
        FlightRecord(
            flight: FlightTime(fileName: "log_2025-03-22.csv",
                               start: "2025-03-22 13:10:00", end: "2025-03-22 16:25:00",
                               dt: "3.2", firstCoordinate: nil, lastCoordinate: nil),
            departure: nil, arrival: nil
        ),
        FlightRecord(
            flight: FlightTime(fileName: "corrupted_file.csv",
                               start: "N/A", end: "N/A",
                               dt: "", firstCoordinate: nil, lastCoordinate: nil),
            departure: nil, arrival: nil
        ),
    ]

    private var maxDuration: Double { records.compactMap { Double($0.flight.dt) }.max() ?? 1 }
    private var totalHours: Double  { records.compactMap { Double($0.flight.dt) }.reduce(0, +) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(records) { FlightRow(record: $0, maxDuration: maxDuration) }
                    .onDelete { records.remove(atOffsets: $0) }
                }
                Section {
                    HStack {
                        Text("\(records.count) flights").foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f h total", totalHours)).fontWeight(.semibold)
                    }
                    .font(.subheadline)
                }
            }
            .listStyle(.inset)
            .navigationTitle("Hobbs Time")
        }
    }
}
