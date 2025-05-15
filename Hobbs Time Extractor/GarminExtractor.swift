//
//  GarminExtractor.swift
//  Time Extractor
//
//  Created by Jonathan Anderson on 5/13/25.
//

import Foundation

/// A fast sequence that yields one line (without the newline) at a time.
public class GarminTimeReader: Sequence, IteratorProtocol {
    private let fileHandle: FileHandle
    private let bufferSize: Int
    private var buffer = Data()
    private let url: URL
    private let hasAccess: Bool
    private var lineNo: Int = 0

    public init?(url: URL, bufferSize: Int = 4_096) {
        // Acquire security-scoped access
        let access = url.startAccessingSecurityScopedResource()
        // Ensure we have permission and can open the file
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
        if hasAccess {
            url.stopAccessingSecurityScopedResource()
        }
    }

    public func next() -> Int? {
        while true {
            if let range = buffer.range(of: Data([0x0A])) { // 0x0A == '\n'
                lineNo += 1
                if lineNo == 1 {
                    let magic = Data("#airframe_info".utf8)
                    if buffer.subdata(in: 0..<magic.count) != magic {
                        return nil
                    }
                } else if lineNo == 2 {
                    let magic = Data("#yyy-mm-dd, hh:mm:ss,   hh:mm,".utf8)
                    if buffer.subdata(in: 0..<magic.count) != magic {
                        return nil
                    }
                } else if lineNo == 3 {
                    let magic = Data("  Lcl Date, Lcl Time, UTCOfst,".utf8)
                    if buffer.subdata(in: 0..<magic.count) != magic {
                        return nil
                    }
                }
                if lineNo < 4 {
                    buffer.removeSubrange(0..<range.upperBound)
                    continue
                }
                let epochsec = epochsec_from_buffer(buffer: buffer)
                buffer.removeSubrange(0..<range.upperBound)
                return epochsec
            }
            else {
                // No newline in buffer: attempt to read more data
                guard let chunk = try? fileHandle.read(upToCount: bufferSize),
                      !chunk.isEmpty else {
                    // EOF reached or read error: end iteration
                    return nil
                }
                buffer.append(chunk)
            }
        }
    }

    private func epochsec_from_buffer(buffer: Data) -> Int {
        var yyyy: Int32 = 0
        var mo: Int32 = 0
        var dd: Int32 = 0
        var hh: Int32 = 0
        var mi: Int32 = 0
        var ss: Int32 = 0
        var tzs: Int32 = 1
        var tzh: Int32 = 0
        var tzm: Int32 = 0

        let skip: Set<UInt8> = [UInt8(ascii: " "), UInt8(ascii: ","), UInt8(ascii: ":")]

        for (idx, byte) in buffer.enumerated() {
            //0123456789012345678901234567890
            //          ,         ,        ,
            //2025-03-17, 09:59:11,  -05:00,
            if idx >= 30 { break }
            if skip.contains(byte) { continue }
            if idx > 20 {
                if byte == UInt8(ascii: "-") {
                    tzs = -1
                    continue
                } else if byte == UInt8(ascii: "+") {
                    tzs = 1
                    continue
                }
            } else if byte == UInt8(ascii: "-") { continue }

            let digit: Int32 = Int32(byte) - Int32(UInt8(ascii: "0"))
            if digit < 0 || digit > 9 { return 0 }

            if idx < 4 { // yyyy
                yyyy = yyyy * 10 + digit
                continue
            }
            if idx < 7 { // MM
                mo = mo * 10 + digit
                continue
            }
            if idx < 10 { // dd
                dd = dd * 10 + digit
                continue
            }
            if idx < 14 { // hh
                hh = hh * 10 + digit
                continue
            }
            if idx < 17 { // mi
                mi = mi * 10 + digit
                continue
            }
            if idx < 20 { // ss
                ss = ss * 10 + digit
                continue
            }
            if idx < 26 { // tzh
                tzh = tzh * 10 + digit
                continue
            }
            if idx < 29 { // tzm
                tzm = tzm * 10 + digit
                continue
            }
        }
        if yyyy < 2020 || yyyy > 2100 { return 0 }
        let epochDay: Int = epoch_from_yyyy_mm_dd(yyyy: yyyy, mm: mo, dd: dd) * 24 * 3600
        let tzOffsetSec: Int = Int(tzs * (tzh * 3600 + tzm * 60))
        let epochSec: Int = Int(hh * 3600 + mi * 60 + ss)
        return epochDay + epochSec - tzOffsetSec
    }

    private func epoch_from_yyyy_mm_dd(yyyy: Int32, mm: Int32, dd: Int32) -> Int {
        var y = yyyy
        var m = mm
        if m < 3 {
            y = y - 1
            m = m + 9
        } else {
            m  = m - 3
        }
        let value = Int32(y * 1461 / 4) + Int32((m * 979 + 15) / 32) + dd - 719484
        return Int(value)
    }
}

/// Immutable result for one CSV
public struct FlightTime {
    public let fileName: String
    public let start: String
    public let end: String
    public let dt: String
}

/// All parsing/epoch‑logic lives here; UI just calls this.
public enum GarminExtractor {
    private static let df: DateFormatter = {
        let f = DateFormatter()
        // No timezone specifier: prints in UTC but without “+0000”
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.timeZone   = TimeZone(secondsFromGMT: 0)
        return f
    }()
    /// Reads the file at `url`, skips “#” lines, pulls cols 0–2, and returns a FlightTime.
    public static func extract(from url: URL) -> FlightTime {
       // Ask the sandbox for temporary read access
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Stream-read times using the iterator protocol
        guard let reader = GarminTimeReader(url: url) else {
            return FlightTime(fileName: url.lastPathComponent, start: "N/A", end: "N/A", dt: "")
        }
        var beg: Int = 0
        var end: Int = 0
        var missingCount = 0;
        for epochsec in reader {
            guard epochsec > 24 * 3600 * 365 else {
                missingCount += 1;
                continue
            }
            if beg == 0 {
                beg = epochsec - missingCount
                end = epochsec
                continue
            }
            if epochsec > end { end = epochsec }
        }

        let begStr = df.string(from: Date(timeIntervalSince1970: TimeInterval(beg)))
        let endStr = df.string(from: Date(timeIntervalSince1970: TimeInterval(end)))
        let dt = Double(end - beg) / 3600
        let dtStr = String(format: "%.1f", dt)
        return FlightTime(fileName: url.lastPathComponent, start: begStr, end: endStr, dt: dtStr)
    }
}
