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

/// FlightTime paired with its nearest departure/arrival airports and distances.
struct FlightRecord: Identifiable {
    let flight: FlightTime
    let departure: AirportRecord?
    let arrival: AirportRecord?
    let departureDistanceKm: Double?
    let arrivalDistanceKm: Double?
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
        case .startTime:   return records.sorted { $0.flight.onDutyEpoch < $1.flight.onDutyEpoch }
        case .duration:    return records.sorted { (Double($0.flight.dt) ?? 0) > (Double($1.flight.dt) ?? 0) }
        }
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
                            let dep = nearestFor(ft.firstCoordinate)
                            let arr = nearestFor(ft.lastCoordinate)
                            return FlightRecord(
                                flight: ft,
                                departure: dep?.airport,
                                arrival:   arr?.airport,
                                departureDistanceKm: dep?.distanceKilometers,
                                arrivalDistanceKm:   arr?.distanceKilometers
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
                records = records.map {
                    let dep = nearestFor($0.flight.firstCoordinate)
                    let arr = nearestFor($0.flight.lastCoordinate)
                    return FlightRecord(
                        flight: $0.flight,
                        departure: dep?.airport,
                        arrival:   arr?.airport,
                        departureDistanceKm: dep?.distanceKilometers,
                        arrivalDistanceKm:   arr?.distanceKilometers
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    private func nearestFor(_ coord: Coordinate?) -> AirportSearchResult? {
        guard let coord, !airports.isEmpty else { return nil }
        return nearestAirport(
            latitudeDegrees: coord.latitude,
            longitudeDegrees: coord.longitude,
            airports: airports
        )
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
                    FlightRow(record: record)
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

    private var flight: FlightTime { record.flight }
    private var isParsed: Bool { flight.onDutyEpoch > 0 }

    private var displayName: String {
        var n = flight.fileName
        if n.lowercased().hasSuffix(".csv") { n = String(n.dropLast(4)) }
        return n
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Filename + Hobbs
            HStack(alignment: .firstTextBaseline) {
                Text(displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if isParsed {
                    VStack(alignment: .trailing, spacing: 0) {
                        HStack(alignment: .lastTextBaseline, spacing: 2) {
                            Text(flight.dt)
                                .font(.title3.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.tint)
                            Text("h")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        Text("Hobbs")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("—")
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            if isParsed {
                routeLabel
                Text(flight.date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                timeRow("Hobbs",  flight.onDuty,  flight.offDuty)
                if flight.timeOutEpoch > 0 || flight.timeInEpoch > 0 {
                    timeRow("Engine", flight.timeOut, flight.timeIn)
                } else {
                    debugRow("Engine", engineDebug)
                }
                if flight.timeOffEpoch > 0 || flight.timeOnEpoch > 0 {
                    timeRow("Flight", flight.timeOff, flight.timeOn)
                } else {
                    debugRow("Flight", flightDebug)
                }
            } else {
                Text("Could not parse file")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Debug strings

    private var engineDebug: String {
        let f = flight
        if f.dbgFfCount == 0 { return "no FFlow data" }
        return String(format: "n=%d maxFF=%.2f gph (need >5)", f.dbgFfCount, f.dbgFfMax)
    }

    private var flightDebug: String {
        let f = flight
        if f.dbgMaxTas == 0 { return "no TAS data" }
        return String(format: "maxTAS=%.0f kt (need >60)", f.dbgMaxTas)
    }

    // MARK: - Row helpers

    private func timeRow(_ label: String, _ start: String, _ end: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .frame(width: 48, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(start)
                .monospacedDigit()
            Text("→")
                .foregroundStyle(.tertiary)
            Text(end)
                .monospacedDigit()
            Text("UTC")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
    }

    private func debugRow(_ label: String, _ info: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label)
                .frame(width: 48, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(info)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.monospacedDigit())
    }

    @ViewBuilder
    private var routeLabel: some View {
        if let dep = record.departure, let arr = record.arrival {
            HStack(spacing: 4) {
                Text(dep.identifier)
                if let d = record.departureDistanceKm {
                    Text(String(format: "%.1fkm", d))
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "arrow.right")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                Text(arr.identifier)
                if let d = record.arrivalDistanceKm {
                    Text(String(format: "%.1fkm", d))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
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
            flight: FlightTime(
                fileName: "log_2025-03-17.csv",
                onDutyEpoch: 1742220000, offDutyEpoch: 1742226120,
                timeOutEpoch: 1742220300, timeInEpoch: 1742225900,
                timeOffEpoch: 1742220600, timeOnEpoch: 1742225700,
                onDuty: "14:59", offDuty: "16:42",
                timeOut: "15:04", timeIn: "16:38",
                timeOff: "15:09", timeOn: "16:35",
                date: "2025-03-17",
                dt: "1.7",
                firstCoordinate: nil, lastCoordinate: nil,
                dbgMaxTas: 145, dbgFfCount: 45, dbgFfMax: 18.3
            ),
            departure: nil, arrival: nil,
            departureDistanceKm: 1.2, arrivalDistanceKm: 0.8
        ),
        FlightRecord(
            flight: FlightTime(
                fileName: "log_2025-03-22.csv",
                onDutyEpoch: 1742642400, offDutyEpoch: 1742654100,
                timeOutEpoch: 0, timeInEpoch: 0,
                timeOffEpoch: 0, timeOnEpoch: 0,
                onDuty: "13:10", offDuty: "16:25",
                timeOut: "—", timeIn: "—",
                timeOff: "—", timeOn: "—",
                date: "2025-03-22",
                dt: "3.2",
                firstCoordinate: nil, lastCoordinate: nil,
                dbgMaxTas: 34, dbgFfCount: 12, dbgFfMax: 0.18
            ),
            departure: nil, arrival: nil,
            departureDistanceKm: nil, arrivalDistanceKm: nil
        ),
        FlightRecord(
            flight: FlightTime(
                fileName: "corrupted_file.csv",
                onDutyEpoch: 0, offDutyEpoch: 0,
                timeOutEpoch: 0, timeInEpoch: 0,
                timeOffEpoch: 0, timeOnEpoch: 0,
                onDuty: "—", offDuty: "—",
                timeOut: "—", timeIn: "—",
                timeOff: "—", timeOn: "—",
                date: "—", dt: "",
                firstCoordinate: nil, lastCoordinate: nil,
                dbgMaxTas: 0, dbgFfCount: 0, dbgFfMax: 0
            ),
            departure: nil, arrival: nil,
            departureDistanceKm: nil, arrivalDistanceKm: nil
        ),
    ]

    private var totalHours: Double { records.compactMap { Double($0.flight.dt) }.reduce(0, +) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(records) { FlightRow(record: $0) }
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
