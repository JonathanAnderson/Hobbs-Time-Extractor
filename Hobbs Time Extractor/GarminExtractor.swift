//
//  GarminExtractor.swift
//  Time Extractor
//
//  Created by Jonathan Anderson on 5/13/25.
//

import Foundation

// MARK: - Shared types

struct Coordinate: Hashable, Sendable {
    let latitude: Double
    let longitude: Double
}

struct GarminRow {
    let epochSec: Int
    let latitude: Double?
    let longitude: Double?
    let tas: Double?       // True Airspeed (kt)
    let maxFFlow: Double?  // max fuel flow across all FFlow columns (gph)
    let maxRPM: Double?    // max engine speed across all RPM columns
    var groundSpeed: Double? = nil
    var indicatedAirspeed: Double? = nil
    var gpsAltitude: Double? = nil
    var pressureAltitude: Double? = nil
    var indicatedAltitude: Double? = nil
    var recordedAGL: Double? = nil
    var verticalSpeed: Double? = nil
}

// MARK: - GarminTimeReader

/// Streaming reader for Garmin logs with either compact or descriptive column names.
/// Timestamp, GPS, and engine columns are discovered independently from the header.
class GarminTimeReader: Sequence, IteratorProtocol {
    private let fileHandle: FileHandle
    private let bufferSize: Int
    private var buffer = Data()
    private let url: URL
    private let hasAccess: Bool
    private var reachedEOF = false
    private let parser = GarminTimestampParser()
    private var colIndices: ColumnIndices?
    private var hasData = false

    private(set) var engineSignal: EngineSignal = .fuelFlow

    private struct ColumnIndices {
        let date: Int
        let time: Int
        let utcOffset: Int
        let latitude: Int?
        let longitude: Int?
        let gpsFix: Int?
        let hplWas: Int?
        let vplWas: Int?
        let tas: Int?
        let fflows: [Int]
        let rpms: [Int]
        let groundSpeed: Int?
        let ias: Int?
        let gpsAltitude: Int?
        let pressureAltitude: Int?
        let indicatedAltitude: Int?
        let agl: Int?
        let verticalSpeed: Int?
    }

    init?(url: URL, bufferSize: Int = 4_096) {
        let access = url.startAccessingSecurityScopedResource()
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            if access { url.stopAccessingSecurityScopedResource() }
            return nil
        }
        self.url = url
        self.fileHandle = handle
        self.bufferSize = Swift.max(1, bufferSize)
        self.hasAccess = access
    }

    deinit {
        try? fileHandle.close()
        if hasAccess { url.stopAccessingSecurityScopedResource() }
    }

    private func nextLine() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            if reachedEOF {
                guard !buffer.isEmpty else { return nil }
                let line = buffer
                buffer = Data()
                return line
            }
            guard let chunk = try? fileHandle.read(upToCount: bufferSize), !chunk.isEmpty else {
                reachedEOF = true
                continue
            }
            buffer.append(chunk)
        }
    }

    func next() -> GarminRow? {
        while let line = nextLine() {
            // Some Garmin logs contain non-UTF-8 bytes in unrelated sensor fields.
            // Replace those bytes so a valid timestamp is not discarded with them.
            let text = String(decoding: line, as: UTF8.self)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let cols = Self.csvFields(trimmed) else { continue }

            // GDU logs include both descriptive and compact headers. Either works;
            // use the final recognized header before the first timestamped sample.
            if !hasData, let indices = parseColumnIndices(cols) {
                colIndices = indices
                engineSignal = indices.rpms.isEmpty ? .fuelFlow : .rpm
                continue
            }
            guard let indices = colIndices,
                  let date = field(cols, at: indices.date),
                  let time = field(cols, at: indices.time),
                  let offset = field(cols, at: indices.utcOffset) else { continue }
            let epoch = parser.parse(date: date, time: time, utcOffset: offset)
            guard epoch > 0 else { continue }
            hasData = true
            let gps = parseGPS(cols, indices: indices)
            return GarminRow(
                epochSec: epoch, latitude: gps?.latitude, longitude: gps?.longitude,
                tas: number(cols, at: indices.tas).flatMap { $0 >= 0 ? $0 : nil },
                maxFFlow: indices.fflows.compactMap { number(cols, at: $0) }.filter { $0 >= 0 }.max(),
                maxRPM: indices.rpms.compactMap { number(cols, at: $0) }.filter { $0 >= 0 }.max(),
                groundSpeed: gpsFixIsValid(cols, indices: indices) ? number(cols, at: indices.groundSpeed) : nil,
                indicatedAirspeed: number(cols, at: indices.ias),
                gpsAltitude: gpsFixIsValid(cols, indices: indices) ? number(cols, at: indices.gpsAltitude) : nil,
                pressureAltitude: number(cols, at: indices.pressureAltitude),
                indicatedAltitude: number(cols, at: indices.indicatedAltitude),
                recordedAGL: number(cols, at: indices.agl),
                verticalSpeed: number(cols, at: indices.verticalSpeed)
            )
        }
        return nil
    }

    /// Garmin fields are normally unquoted. Also accept quoted CSV exports, including
    /// embedded commas and escaped quotes; an unfinished quoted record is skipped.
    private static func csvFields(_ line: String) -> [String]? {
        if !line.contains("\"") {
            return line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        var fields: [String] = []
        var field = ""
        var quoted = false
        var index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            let next = line.index(after: index)
            if ch == "\"" {
                if quoted, next < line.endIndex, line[next] == "\"" {
                    field.append("\"")
                    index = line.index(after: next)
                    continue
                }
                quoted.toggle()
            } else if ch == "," && !quoted {
                fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                field = ""
            } else {
                field.append(ch)
            }
            index = next
        }
        guard !quoted else { return nil }
        fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
        return fields
    }

    private func parseColumnIndices(_ cols: [String]) -> ColumnIndices? {
        // Descriptive aliases include units. Supported Garmin compact headers use
        // knots for TAS and gallons/hour for FFlow.
        let names = cols.map { $0.lowercased().filter { !$0.isWhitespace } }
        func find(_ aliases: [String]) -> Int? {
            names.firstIndex { aliases.contains($0) }
        }
        func engineColumns(shortName: String, descriptiveNames: [String]) -> [Int] {
            names.indices.filter { index in
                let name = names[index]
                if name == shortName || descriptiveNames.contains(name) { return true }
                // Compact engine names: E1 FFlow, E2 FFlow, E1 RPM, etc.
                guard name.hasPrefix("e"), name.hasSuffix(shortName) else { return false }
                let engine = name.dropFirst().dropLast(shortName.count)
                return !engine.isEmpty && engine.allSatisfy { $0.isASCII && $0.isNumber }
            }
        }
        guard let date = find(["lcldate", "localdate", "date", "date(yyyy-mm-dd)"]),
              let time = find(["lcltime", "localtime", "time", "time(hh:mm:ss)"]),
              let offset = find(["utcofst", "utcoffset", "utcoffset(hh:mm)"]) else { return nil }
        return ColumnIndices(
            date: date, time: time, utcOffset: offset,
            latitude: find(["latitude", "latitude(deg)"]),
            longitude: find(["longitude", "longitude(deg)"]),
            gpsFix: find(["gpsfix", "gpsfixstatus"]),
            hplWas: find(["hplwas"]), vplWas: find(["vplwas"]),
            tas: find(["tas", "trueairspeed(kt)"]),
            fflows: engineColumns(shortName: "fflow", descriptiveNames: ["fuelflow(gal/hour)", "fuelflow(gph)"]),
            rpms: engineColumns(shortName: "rpm", descriptiveNames: ["enginespeed(rpm)"]),
            groundSpeed: find(["gndspd", "gpsgroundspeed(kt)"]),
            ias: find(["ias", "indicatedairspeed(kt)"]),
            gpsAltitude: find(["altmsl"]) ?? find(["altgps", "gpsaltitude(ft)"]),
            pressureAltitude: find(["altp", "pressurealtitude(ft)"]),
            indicatedAltitude: find(["altind", "baroaltitude(ft)"]),
            agl: find(["agl", "heightaboveground(ft)"]),
            verticalSpeed: find(["vspd", "verticalspeed(ft/min)"])
        )
    }

    private func field(_ cols: [String], at index: Int?) -> String? {
        guard let index, cols.indices.contains(index) else { return nil }
        return cols[index]
    }

    private func number(_ cols: [String], at index: Int?) -> Double? {
        guard let text = field(cols, at: index), let value = Double(text), value.isFinite else { return nil }
        return value
    }

    private func gpsFixIsValid(_ cols: [String], indices: ColumnIndices) -> Bool {
        if let index = indices.gpsFix {
            guard let fix = field(cols, at: index)?.lowercased(),
                  fix == "3ddiff" || fix == "3d" else { return false }
        }
        return true
    }

    private func gpsQualityIsValid(_ cols: [String], indices: ColumnIndices) -> Bool {
        guard gpsFixIsValid(cols, indices: indices) else { return false }
        // Older G1000 logs include protection levels; GDU 465 logs do not.
        // These limits filter airport coordinates, not the offline smoothed altitude
        // profile: crossing VPL=100 must not turn touchdown into a later taxi sample.
        for index in [indices.hplWas, indices.vplWas].compactMap({ $0 }) {
            guard let level = number(cols, at: index), level >= 0, level < 100 else { return false }
        }
        return true
    }

    private func parseGPS(_ cols: [String], indices: ColumnIndices) -> Coordinate? {
        guard gpsQualityIsValid(cols, indices: indices) else { return nil }
        guard let lat = number(cols, at: indices.latitude), (-90...90).contains(lat),
              let lon = number(cols, at: indices.longitude), (-180...180).contains(lon) else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }
}

// MARK: - GarminTimestampParser

/// Converts named local date/time/UTC-offset fields to UTC without DateFormatter.
struct GarminTimestampParser {
    func parse(date: String, time: String, utcOffset: String) -> Int {
        let d = Array(date.utf8), t = Array(time.utf8), z = Array(utcOffset.utf8)
        guard d.count == 10, d[4] == 45, d[7] == 45,
              t.count == 8, t[2] == 58, t[5] == 58,
              z.count == 6, z[0] == 43 || z[0] == 45, z[3] == 58 else { return 0 }
        func digits(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
            var value = 0
            for i in range {
                guard (48...57).contains(bytes[i]) else { return nil }
                value = value * 10 + Int(bytes[i] - 48)
            }
            return value
        }
        guard let year = digits(d, 0..<4), (2020...2100).contains(year),
              let month = digits(d, 5..<7), (1...12).contains(month),
              let day = digits(d, 8..<10),
              let hour = digits(t, 0..<2), hour < 24,
              let minute = digits(t, 3..<5), minute < 60,
              let second = digits(t, 6..<8), second < 60,
              let zoneHour = digits(z, 1..<3), zoneHour <= 14,
              let zoneMinute = digits(z, 4..<6), zoneMinute < 60,
              zoneHour < 14 || zoneMinute == 0 else { return 0 }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let daysInMonth = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...daysInMonth[month - 1]).contains(day) else { return 0 }

        // Gregorian days since 1970-01-01, including century leap-year rules.
        let y = year - (month <= 2 ? 1 : 0)
        let era = y / 400
        let yoe = y - era * 400
        let m = month + (month > 2 ? -3 : 9)
        let doy = (153 * m + 2) / 5 + day - 1
        let days = era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468
        let offset = (zoneHour * 3600 + zoneMinute * 60) * (z[0] == 45 ? -1 : 1)
        return days * 86400 + hour * 3600 + minute * 60 + second - offset
    }
}

/// Choose one engine signal per file so missing RPM samples cannot switch to fuel flow.
enum EngineSignal: Sendable {
    case rpm
    case fuelFlow

    var threshold: Double { self == .rpm ? 300 : 5 }
    var label: String { self == .rpm ? "RPM" : "FFlow" }
    var units: String { self == .rpm ? "rpm" : "gph" }
}

// MARK: - FlightTime

/// Immutable result for one CSV file.
struct FlightTime: Sendable {
    let fileName: String
    // UTC epoch seconds (0 = not detected)
    let onDutyEpoch:  Int
    let offDutyEpoch: Int
    let timeOutEpoch: Int
    let timeInEpoch:  Int
    let timeOffEpoch: Int
    let timeOnEpoch:  Int
    // Formatted "HH:mm" UTC display strings ("—" if not detected)
    let onDuty:  String
    let offDuty: String
    let timeOut: String
    let timeIn:  String
    let timeOff: String
    let timeOn:  String
    // "yyyy-MM-dd" UTC date of the On Duty event
    let date: String
    // Hobbs = (offDuty − onDuty) / 3600, formatted "H.h"
    let dt: String
    let firstCoordinate: Coordinate?
    let lastCoordinate: Coordinate?
    // Debug: always populated, helps diagnose missed detections
    let dbgMaxTas:  Double   // highest TAS seen in file
    let engineSignal: EngineSignal
    let dbgEngineCount: Int  // samples with the selected engine signal
    let dbgEngineMax: Double // maximum RPM or fuel flow, depending on engineSignal
    var flightDetectionNote: String = ""
}

// MARK: - GarminExtractor

enum GarminExtractor {
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.timeZone   = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.timeZone   = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static func fmt(_ epoch: Int) -> String {
        guard epoch > 0 else { return "—" }
        return timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    private static func fmtDate(_ epoch: Int) -> String {
        guard epoch > 0 else { return "—" }
        return dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    static func extract(from url: URL) -> FlightTime {
        func na() -> FlightTime {
            FlightTime(
                fileName: url.lastPathComponent,
                onDutyEpoch: 0, offDutyEpoch: 0,
                timeOutEpoch: 0, timeInEpoch: 0,
                timeOffEpoch: 0, timeOnEpoch: 0,
                onDuty: "—", offDuty: "—",
                timeOut: "—", timeIn: "—",
                timeOff: "—", timeOn: "—",
                date: "—", dt: "",
                firstCoordinate: nil, lastCoordinate: nil,
                dbgMaxTas: 0, engineSignal: .fuelFlow, dbgEngineCount: 0, dbgEngineMax: 0
            )
        }

        guard let reader = GarminTimeReader(url: url) else { return na() }

        // -- Duty --
        var tOnDuty  = 0
        var tOffDuty = 0

        // -- GPS --
        var firstCoord: Coordinate? = nil
        var lastCoord:  Coordinate? = nil

        // -- Engine detection: RPM > 300 where available, otherwise FFlow > 5 gph --
        var engineCount = 0 // samples with the selected signal (debug)
        var tOut    = 0     // first engine start
        var tIn     = 0     // last engine stop (keeps updating)

        // Motion/altitude samples for the offline, engine-independent detector.
        var flightRows: [GarminRow] = []

        // -- Debug accumulators --
        var dbgMaxTas = 0.0
        var dbgEngineMax = 0.0

        for row in reader {
            guard row.epochSec > 24 * 3600 * 365 else { continue }
            let t = row.epochSec

            if tOnDuty == 0 { tOnDuty = t }
            tOffDuty = t

            // GPS
            if let lat = row.latitude, let lon = row.longitude {
                if firstCoord == nil { firstCoord = Coordinate(latitude: lat, longitude: lon) }
                lastCoord = Coordinate(latitude: lat, longitude: lon)
            }

            // RPM distinguishes low-idle running from fuel priming in piston logs.
            let engineValue = reader.engineSignal == .rpm ? row.maxRPM : row.maxFFlow
            if let value = engineValue {
                engineCount += 1
                dbgEngineMax = max(dbgEngineMax, value)
                if tOut == 0 {
                    if value > reader.engineSignal.threshold { tOut = t }
                } else if value <= reader.engineSignal.threshold {
                    tIn = t
                }
            }

            flightRows.append(row)
            if let tas = row.tas { dbgMaxTas = max(dbgMaxTas, tas) }
        }

        // Engine fallback is separate; never invent a landing at the end of a log.
        if tOut > 0 && tIn == 0 { tIn = tOffDuty }
        let flight = FlightTrackAnalyzer.analyze(flightRows)
        let tOff = flight.firstTakeoffEpoch
        let tOn = flight.lastLandingEpoch

        guard tOnDuty > 0 else { return na() }

        let dtHours = tOffDuty > tOnDuty ? Double(tOffDuty - tOnDuty) / 3600.0 : 0.0

        return FlightTime(
            fileName: url.lastPathComponent,
            onDutyEpoch: tOnDuty,   offDutyEpoch: tOffDuty,
            timeOutEpoch: tOut,     timeInEpoch:  tIn,
            timeOffEpoch: tOff,     timeOnEpoch:  tOn,
            onDuty:  fmt(tOnDuty),  offDuty: fmt(tOffDuty),
            timeOut: fmt(tOut),     timeIn:  fmt(tIn),
            timeOff: fmt(tOff),     timeOn:  fmt(tOn),
            date: fmtDate(tOnDuty),
            dt: String(format: "%.1f", dtHours),
            firstCoordinate: firstCoord, lastCoordinate: lastCoord,
            dbgMaxTas: dbgMaxTas, engineSignal: reader.engineSignal,
            dbgEngineCount: engineCount, dbgEngineMax: dbgEngineMax,
            flightDetectionNote: flight.note
        )
    }
}
