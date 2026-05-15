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

/// One data row yielded by GarminTimeReader.
public struct GarminRow {
    public let epochSec: Int
    /// Latitude in decimal degrees, present only when GPSfix=="3DDiff", HPLwas<100, VPLwas<100.
    public let latitude: Double?
    public let longitude: Double?
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
                let gps = colIndices.flatMap { parseGPS(line, indices: $0) }
                buffer.removeSubrange(0..<range.upperBound)
                return GarminRow(epochSec: epochSec, latitude: gps?.lat, longitude: gps?.lon)
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
        for (i, col) in s.split(separator: ",", omittingEmptySubsequences: false).enumerated() {
            map[col.trimmingCharacters(in: .whitespaces)] = i
        }
        guard let lat = map["Latitude"], let lon = map["Longitude"],
              let fix = map["GPSfix"],  let hpl = map["HPLwas"], let vpl = map["VPLwas"]
        else { return nil }
        return ColumnIndices(latitude: lat, longitude: lon, gpsFix: fix, hplWas: hpl, vplWas: vpl)
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

    // Proleptic Gregorian calendar → days since Unix epoch.
    // Uses integer arithmetic only; avoids Calendar overhead in the hot path.
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
    public let start: String
    public let end: String
    public let dt: String
    /// First GPS fix meeting quality criteria (GPSfix==3DDiff, HPL<100, VPL<100).
    public let firstCoordinate: Coordinate?
    /// Last GPS fix meeting quality criteria.
    public let lastCoordinate: Coordinate?
}

// MARK: - GarminExtractor

/// All parsing logic lives here; UI just calls extract(from:).
public enum GarminExtractor {
    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.timeZone   = TimeZone(secondsFromGMT: 0)
        return f
    }()

    public static func extract(from url: URL) -> FlightTime {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        guard let reader = GarminTimeReader(url: url) else {
            return FlightTime(fileName: url.lastPathComponent,
                              start: "N/A", end: "N/A", dt: "",
                              firstCoordinate: nil, lastCoordinate: nil)
        }

        var beg = 0, end = 0, missingCount = 0
        var firstCoord: Coordinate? = nil
        var lastCoord:  Coordinate? = nil

        for row in reader {
            guard row.epochSec > 24 * 3600 * 365 else { missingCount += 1; continue }
            if beg == 0 {
                beg = row.epochSec - missingCount
                end = row.epochSec
            } else if row.epochSec > end {
                end = row.epochSec
            }
            if let lat = row.latitude, let lon = row.longitude {
                if firstCoord == nil { firstCoord = Coordinate(latitude: lat, longitude: lon) }
                lastCoord = Coordinate(latitude: lat, longitude: lon)
            }
        }

        let begStr = df.string(from: Date(timeIntervalSince1970: TimeInterval(beg)))
        let endStr = df.string(from: Date(timeIntervalSince1970: TimeInterval(end)))
        let dtStr  = String(format: "%.1f", Double(end - beg) / 3600)
        return FlightTime(fileName: url.lastPathComponent,
                          start: begStr, end: endStr, dt: dtStr,
                          firstCoordinate: firstCoord, lastCoordinate: lastCoord)
    }
}
