//
//  GarminExtractor.swift
//  Time Extractor
//
//  Created by Jonathan Anderson on 5/13/25.
//

import Foundation

// MARK: - Shared types

public struct Coordinate: Hashable {
    public let latitude: Double
    public let longitude: Double
}

public struct GarminRow {
    public let epochSec: Int
    public let latitude: Double?
    public let longitude: Double?
    public let tas: Double?       // True Airspeed (kt)
    public let maxFFlow: Double?  // max fuel flow across all FFlow columns (gph)
}

// MARK: - GarminTimeReader

/// Streaming iterator over a Garmin G1000 CSV. Yields one GarminRow per data line.
public class GarminTimeReader: Sequence, IteratorProtocol {
    private let fileHandle: FileHandle
    private let bufferSize: Int
    private var buffer = Data()
    private let url: URL
    private let hasAccess: Bool
    private var lineNo: Int = 0
    private let parser = GarminTimestampParser()
    private var colIndices: ColumnIndices?

    private struct ColumnIndices {
        let latitude: Int
        let longitude: Int
        let gpsFix: Int
        let hplWas: Int
        let vplWas: Int
        let tas: Int?
        let fflows: [Int]
    }

    public init?(url: URL, bufferSize: Int = 4_096) {
        let access = url.startAccessingSecurityScopedResource()
        guard access, let handle = try? FileHandle(forReadingFrom: url) else {
            if access { url.stopAccessingSecurityScopedResource() }
            return nil
        }
        self.url = url
        self.fileHandle = handle
        self.bufferSize = bufferSize
        self.hasAccess = access
    }

    deinit {
        try? fileHandle.close()
        if hasAccess { url.stopAccessingSecurityScopedResource() }
    }

    public func next() -> GarminRow? {
        while true {
            if let range = buffer.range(of: Data([0x0A])) {
                lineNo += 1
                let line = buffer[..<range.lowerBound]

                if lineNo == 1 {
                    let magic = Data("#airframe_info".utf8)
                    if buffer.subdata(in: 0..<magic.count) != magic { return nil }
                } else if lineNo == 2 {
                    let magic = Data("#yyy-mm-dd, hh:mm:ss,   hh:mm,".utf8)
                    if buffer.subdata(in: 0..<magic.count) != magic { return nil }
                } else if lineNo == 3 {
                    let magic = Data("  Lcl Date, Lcl Time, UTCOfst,".utf8)
                    if buffer.subdata(in: 0..<magic.count) != magic { return nil }
                    colIndices = parseColumnIndices(line)
                }

                if lineNo < 4 {
                    buffer.removeSubrange(0..<range.upperBound)
                    continue
                }

                let epochSec = parser.parse(buffer)
                let gps    = colIndices.flatMap { parseGPS(line, indices: $0) }
                let motion = colIndices.flatMap { parseMotion(line, indices: $0) }
                buffer.removeSubrange(0..<range.upperBound)
                return GarminRow(
                    epochSec: epochSec,
                    latitude: gps?.lat, longitude: gps?.lon,
                    tas: motion?.tas, maxFFlow: motion?.maxFFlow
                )
            } else {
                guard let chunk = try? fileHandle.read(upToCount: bufferSize),
                      !chunk.isEmpty else { return nil }
                buffer.append(chunk)
            }
        }
    }

    private func parseColumnIndices(_ line: Data) -> ColumnIndices? {
        guard let s = String(data: line, encoding: .ascii) else { return nil }
        var map: [String: Int] = [:]
        var fflowIndices: [Int] = []
        for (i, col) in s.split(separator: ",", omittingEmptySubsequences: false).enumerated() {
            let name = col.trimmingCharacters(in: .whitespaces)
            map[name] = i
            if name.contains("FFlow") { fflowIndices.append(i) }
        }
        guard let lat = map["Latitude"], let lon = map["Longitude"],
              let fix = map["GPSfix"], let hpl = map["HPLwas"], let vpl = map["VPLwas"]
        else { return nil }
        return ColumnIndices(
            latitude: lat, longitude: lon, gpsFix: fix, hplWas: hpl, vplWas: vpl,
            tas: map["TAS"], fflows: fflowIndices
        )
    }

    private func parseGPS(_ line: Data, indices: ColumnIndices) -> (lat: Double, lon: Double)? {
        guard let s = String(data: line, encoding: .ascii) else { return nil }
        let cols = s.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard cols.count > indices.latitude,
              cols.count > indices.longitude,
              cols.count > indices.gpsFix,
              cols.count > indices.hplWas,
              cols.count > indices.vplWas else { return nil }
        guard cols[indices.gpsFix] == "3DDiff",
              let hpl = Double(cols[indices.hplWas]), hpl < 100,
              let vpl = Double(cols[indices.vplWas]), vpl < 100 else { return nil }
        let latStr = cols[indices.latitude], lonStr = cols[indices.longitude]
        guard !latStr.isEmpty, !lonStr.isEmpty,
              let lat = Double(latStr), let lon = Double(lonStr) else { return nil }
        return (lat, lon)
    }

    private func parseMotion(
        _ line: Data, indices: ColumnIndices
    ) -> (tas: Double?, maxFFlow: Double?)? {
        guard indices.tas != nil || !indices.fflows.isEmpty else { return nil }
        guard let s = String(data: line, encoding: .ascii) else { return nil }
        let cols = s.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        func get(_ idx: Int?) -> Double? {
            guard let idx, cols.count > idx else { return nil }
            return Double(cols[idx])
        }
        let maxFF = indices.fflows.isEmpty ? nil : indices.fflows.compactMap { get($0) }.max()
        return (tas: get(indices.tas), maxFFlow: maxFF)
    }
}

// MARK: - GarminTimestampParser

/// Parses a single Garmin G1000 CSV data row (cols 0–2) into a UTC epoch second.
/// Zero-state value type; no Calendar or DateFormatter — safe to call in tight loops.
public struct GarminTimestampParser {
    // Input layout (first 30 bytes):
    //   0123456789012345678901234567890
    //             ,         ,        ,
    //   2025-03-17, 09:59:11,  -05:00,
    public func parse(_ buffer: Data) -> Int {
        var yyyy: Int32 = 0
        var mo:   Int32 = 0
        var dd:   Int32 = 0
        var hh:   Int32 = 0
        var mi:   Int32 = 0
        var ss:   Int32 = 0
        var tzs:  Int32 = 1
        var tzh:  Int32 = 0
        var tzm:  Int32 = 0

        let skip: Set<UInt8> = [UInt8(ascii: " "), UInt8(ascii: ","), UInt8(ascii: ":")]

        for (idx, byte) in buffer.enumerated() {
            if idx >= 30 { break }
            if skip.contains(byte) { continue }
            if idx > 20 {
                if byte == UInt8(ascii: "-") { tzs = -1; continue }
                if byte == UInt8(ascii: "+") { tzs =  1; continue }
            } else if byte == UInt8(ascii: "-") { continue }

            let digit = Int32(byte) - Int32(UInt8(ascii: "0"))
            if digit < 0 || digit > 9 { return 0 }

            if idx <  4 { yyyy = yyyy * 10 + digit; continue }
            if idx <  7 { mo   = mo   * 10 + digit; continue }
            if idx < 10 { dd   = dd   * 10 + digit; continue }
            if idx < 14 { hh   = hh   * 10 + digit; continue }
            if idx < 17 { mi   = mi   * 10 + digit; continue }
            if idx < 20 { ss   = ss   * 10 + digit; continue }
            if idx < 26 { tzh  = tzh  * 10 + digit; continue }
            if idx < 29 { tzm  = tzm  * 10 + digit; continue }
        }
        if yyyy < 2020 || yyyy > 2100 { return 0 }
        let dayEpoch    = epochDay(yyyy: yyyy, mm: mo, dd: dd) * 24 * 3600
        let tzOffsetSec = Int(tzs * (tzh * 3600 + tzm * 60))
        let timeSec     = Int(hh * 3600 + mi * 60 + ss)
        return dayEpoch + timeSec - tzOffsetSec
    }

    private func epochDay(yyyy: Int32, mm: Int32, dd: Int32) -> Int {
        var y = yyyy
        var m = mm
        if m < 3 { y -= 1; m += 9 } else { m -= 3 }
        let value = Int32(y * 1461 / 4) + Int32((m * 979 + 15) / 32) + dd - 719484
        return Int(value)
    }
}

// MARK: - FlightTime

/// Immutable result for one CSV file.
public struct FlightTime {
    public let fileName: String
    // UTC epoch seconds (0 = not detected)
    public let onDutyEpoch:  Int
    public let offDutyEpoch: Int
    public let timeOutEpoch: Int
    public let timeInEpoch:  Int
    public let timeOffEpoch: Int
    public let timeOnEpoch:  Int
    // Formatted "HH:mm" UTC display strings ("—" if not detected)
    public let onDuty:  String
    public let offDuty: String
    public let timeOut: String
    public let timeIn:  String
    public let timeOff: String
    public let timeOn:  String
    // "yyyy-MM-dd" UTC date of the On Duty event
    public let date: String
    // Hobbs = (offDuty − onDuty) / 3600, formatted "H.h"
    public let dt: String
    /// First GPS fix meeting quality criteria.
    public let firstCoordinate: Coordinate?
    /// Last GPS fix meeting quality criteria.
    public let lastCoordinate: Coordinate?
    // Debug: always populated, helps diagnose missed detections
    public let dbgMaxTas:  Double   // highest TAS seen in file (need >60 for flight)
    public let dbgFfCount: Int      // data points with FFlow seen
    public let dbgFfMax:   Double   // highest fuel flow seen (need >5 for engine)
}

// MARK: - GarminExtractor

public enum GarminExtractor {
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

    public static func extract(from url: URL) -> FlightTime {
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
                dbgMaxTas: 0, dbgFfCount: 0, dbgFfMax: 0
            )
        }

        guard let reader = GarminTimeReader(url: url) else { return na() }

        // -- Duty --
        var tOnDuty  = 0
        var tOffDuty = 0

        // -- GPS --
        var firstCoord: Coordinate? = nil
        var lastCoord:  Coordinate? = nil

        // -- Engine detection: any engine running when max FFlow > 5 gph --
        var ffCount = 0     // data points with FFlow present (debug)
        var tOut    = 0     // first engine start
        var tIn     = 0     // last engine stop (keeps updating)

        // -- Takeoff / landing detection via TAS threshold --
        var tOff = 0   // first time TAS > 60 kt
        var tOn  = 0   // first time TAS < 40 kt after takeoff

        // -- Debug accumulators --
        var dbgMaxTas = 0.0
        var dbgFfMax  = 0.0

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

            // Engine detection: > 5 gph means at least one engine is running
            if let ff = row.maxFFlow {
                ffCount += 1
                if ff > dbgFfMax { dbgFfMax = ff }
                if tOut == 0 {
                    if ff > 5.0 { tOut = t }
                } else if ff <= 5.0 {
                    tIn = t
                }
            }

            // Takeoff / landing detection via TAS
            // >60 kt → airborne; <40 kt after takeoff → landed
            if let tas = row.tas {
                if tas > dbgMaxTas { dbgMaxTas = tas }
                if tOff == 0 && tas > 60.0 {
                    tOff = t
                } else if tOff > 0 && tOn == 0 && tas < 40.0 {
                    tOn = t
                }
            }
        }

        // End-of-file fallbacks
        if tOff > 0 && tOn == 0 { tOn = tOffDuty }
        if tOut > 0 && tIn == 0 { tIn = tOffDuty }

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
            dbgMaxTas: dbgMaxTas, dbgFfCount: ffCount, dbgFfMax: dbgFfMax
        )
    }
}
