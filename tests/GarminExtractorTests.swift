import Foundation

// Standalone regression suite: tests/run.sh compiles the production parser and flight analyzer.
@main
struct GarminExtractorTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func epoch(_ iso: String) -> Int {
        Int(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970)
    }

    static func withCSV<T>(_ contents: String, _ body: (URL) throws -> T) throws -> T {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("hobbs-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("synthetic.csv")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return try body(url)
    }

    static func rows(_ contents: String, bufferSize: Int = 4_096) throws -> [GarminRow] {
        try withCSV(contents) { url in
            guard let reader = GarminTimeReader(url: url, bufferSize: bufferSize) else {
                throw Failure(description: "Reader could not open synthetic fixture")
            }
            return Array(reader).filter { $0.epochSec > 0 }
        }
    }

    static func flight(_ contents: String) throws -> FlightTime {
        try withCSV(contents) { GarminExtractor.extract(from: $0) }
    }

    static let legacy = """
    #airframe_info,log_version="1.00",aircraft_ident="TEST"
    #yyy-mm-dd, hh:mm:ss,   hh:mm,  degrees,  degrees,       ,     m,     m,   kt,   gph,   gph
      Lcl Date, Lcl Time, UTCOfst, Latitude,Longitude, GPSfix,HPLwas,VPLwas,  TAS,E1 FFlow,E2 FFlow
    2025-03-17, 09:59:11,  -05:00, 41.0,-87.0,3DDiff,10,20,0,0,0
    2025-03-17, 10:00:00,  -05:00, 41.0,-87.0,3DDiff,10,20,20,0,6
    2025-03-17, 10:01:00,  -05:00, 41.1,-87.1,3DDiff,10,20,70,4,8
    2025-03-17, 10:30:00,  -05:00, 41.2,-87.2,3DDiff,10,20,35,4,8
    2025-03-17, 10:31:00,  -05:00, 41.3,-87.3,3DDiff,10,20,0,0,0

    """

    static let gduVerboseHeader = "Date (yyyy-mm-dd),Time (hh:mm:ss),UTC Time (hh:mm:ss),UTC Offset (hh:mm),Latitude (deg),Longitude (deg),GPS Fix Status,True Airspeed (kt),RPM,Fuel Flow (gal/hour)"
    static let gduCompactHeader = "Lcl Date,Lcl Time,UTC Time,UTCOfst,Latitude,Longitude,GPSfix,TAS,E1 RPM,E1 FFlow"
    static let gduData = """
    2026-10-31,13:22:01,13:22:01,+00:00,+41.6172053,-87.4048240,3D-,0,0,0.0
    2026-10-31,13:22:02,13:22:02,+00:00,+41.6172053,-87.4048240,3D,0,200,0.0
    2026-10-31,13:22:03,13:22:03,+00:00,+41.6172053,-87.4048240,3D,0,900,2.0
    2026-10-31,13:23:00,13:23:00,+00:00,+41.6172053,-87.4048240,3DDiff,30,1500,4.0
    2026-10-31,13:24:00,13:24:00,+00:00,+41.618,-87.405,3DDiff,90,2200,8.0
    2026-10-31,13:30:00,13:30:00,+00:00,+41.620,-87.410,3DDiff,20,900,2.0
    2026-10-31,13:32:01,13:32:01,+00:00,+41.621,-87.411,3DDiff,0,0,0.0
    """

    static func legacyCompatibility() throws {
        let f = try flight(legacy)
        try expect(f.onDutyEpoch == epoch("2025-03-17T14:59:11Z"), "Legacy local time must use UTC offset")
        try expect(f.offDutyEpoch == epoch("2025-03-17T15:31:00Z"), "Legacy end time")
        try expect(f.timeOutEpoch == epoch("2025-03-17T15:00:00Z"), "Either engine's fuel flow must trigger engine start")
        try expect(f.timeInEpoch == epoch("2025-03-17T15:31:00Z"), "Legacy engine stop")
        let parsed = try rows(legacy)
        try expect(parsed[2].tas == 70 && parsed[3].tas == 35, "Legacy airspeed columns remain available to flight analysis")
        try expect(f.dt == "0.5", "Hobbs remains the rounded recording duration")
        try expect(f.firstCoordinate == Coordinate(latitude: 41, longitude: -87), "Legacy first coordinate")
        try expect(f.lastCoordinate == Coordinate(latitude: 41.3, longitude: -87.3), "Legacy last coordinate")
    }

    static func gduDualHeaders() throws {
        let text = "#airframe_info,product=\"GDU 465\"\n\(gduVerboseHeader)\n\(gduCompactHeader)\n\(gduData)\n"
        let f = try flight(text)
        try expect(f.onDutyEpoch == epoch("2026-10-31T13:22:01Z"), "GDU UTC Time column must not be read as UTC offset")
        try expect(f.offDutyEpoch == epoch("2026-10-31T13:32:01Z"), "GDU final time")
        try expect(f.timeOutEpoch == epoch("2026-10-31T13:22:03Z"), "RPM must detect idle below 5 gph, excluding cranking")
        try expect(f.timeInEpoch == epoch("2026-10-31T13:32:01Z"), "RPM must preserve engine running through low-flow taxi")
        let parsed = try rows(text)
        try expect(parsed[4].tas == 90 && parsed[5].tas == 20, "GDU airspeed works without HPL/VPL columns")
        try expect(f.dt == "0.2", "GDU Hobbs recording span")
        try expect(f.firstCoordinate == Coordinate(latitude: 41.6172053, longitude: -87.4048240), "A valid 3D fix must work without HPL/VPL")
        try expect(f.lastCoordinate == Coordinate(latitude: 41.621, longitude: -87.411), "GDU arrival coordinate")
    }

    static func verboseHeaderOnly() throws {
        let f = try flight("\(gduVerboseHeader)\n\(gduData)")
        try expect(f.onDutyEpoch == epoch("2026-10-31T13:22:01Z"), "Verbose timestamp aliases")
        try expect(f.timeOutEpoch == epoch("2026-10-31T13:22:03Z"), "Verbose RPM alias")
        let parsed = try rows("\(gduVerboseHeader)\n\(gduData)")
        try expect(parsed[4].tas == 90, "Verbose airspeed alias")
        try expect(f.lastCoordinate != nil, "Verbose GPS aliases")
    }

    static func reorderedQuotedFields() throws {
        let input = #"""
        "Note","TAS","UTCOfst","Longitude","Lcl Time","Latitude","Lcl Date","GPSfix","E1 FFlow"
        "test, ""comma""",80,-05:00,-87.4,23:59:59,41.6,2026-10-31,3D,8
        "next",30,-05:00,-87.5,00:00:01,41.7,2026-11-01,3D,0
        """#
        let parsed = try rows(input)
        try expect(parsed.count == 2, "Quoted comma/escaped quote must not shift columns")
        try expect(parsed[0].epochSec == epoch("2026-11-01T04:59:59Z"), "Reordered local timestamp and date rollover")
        try expect(parsed[1].epochSec == epoch("2026-11-01T05:00:01Z"), "Reordered timestamp after midnight")
        try expect(parsed[0].tas == 80 && parsed[0].maxFFlow == 8, "Reordered telemetry")
        try expect(parsed[0].latitude == 41.6 && parsed[0].longitude == -87.4, "Reordered GPS")
    }

    static func streamingAndLineEndings() throws {
        let input = "\u{FEFF}\r\n# metadata\r\n\r\n\(gduCompactHeader)\r\n\(gduData.replacingOccurrences(of: "\n", with: "\r\n"))"
        let tiny = try rows(input, bufferSize: 7)
        let normal = try rows(input)
        try expect(tiny.count == 7 && normal.count == 7, "BOM, blanks, CRLF, and final unterminated row")
        try expect(tiny.map(\.epochSec) == normal.map(\.epochSec), "Chunk boundaries must not change timestamps")
        try expect(tiny.last?.epochSec == epoch("2026-10-31T13:32:01Z"), "Final unterminated line must be emitted")
        try expect(tiny.last?.maxFFlow == 0, "CRLF must not corrupt last numeric field")
    }

    static func bomOnHeader() throws {
        let parsed = try rows("\u{FEFF}\(gduCompactHeader)\n\(gduData)", bufferSize: 1)
        try expect(parsed.count == 7, "BOM directly on first header must be ignored, even across byte chunks")
    }

    static func invalidUTF8InUnrelatedField() throws {
        var data = Data("Lcl Date,Lcl Time,UTCOfst,Unused Sensor,TAS,E1 FFlow\n2026-10-31,12:00:00,+00:00,OK,0,0\n2026-10-31,12:30:00,+00:00,status".utf8)
        data.append(0x80) // A legacy sensor byte that is not valid UTF-8 on its own.
        data.append(contentsOf: ",80,8".utf8)
        try withCSV("") { url in
            try data.write(to: url)
            guard let reader = GarminTimeReader(url: url, bufferSize: 7) else {
                throw Failure(description: "Reader could not open binary fixture")
            }
            let parsed = Array(reader).filter { $0.epochSec > 0 }
            try expect(parsed.count == 2, "Unrelated invalid UTF-8 must not discard a timestamped row")
            try expect(parsed.last?.tas == 80 && parsed.last?.maxFFlow == 8, "Invalid sensor bytes must not corrupt numeric motion fields")
            let f = GarminExtractor.extract(from: url)
            try expect(f.offDutyEpoch == epoch("2026-10-31T12:30:00Z"), "Final timestamp must survive invalid bytes in an unrelated field")
            try expect(f.dt == "0.5", "Unrelated invalid UTF-8 must not shorten recording duration")
        }
    }

    static func telemetryWithoutGPS() throws {
        let input = """
        Lcl Date,Lcl Time,UTCOfst,TAS,E1 FFlow
        2026-10-31,12:00:00,+00:00,0,0
        2026-10-31,12:01:00,+00:00,80,8
        2026-10-31,12:10:00,+00:00,20,0
        """
        let f = try flight(input)
        try expect(f.timeOutEpoch == epoch("2026-10-31T12:01:00Z"), "Missing GPS must not disable fuel flow")
        let parsed = try rows(input)
        try expect(parsed[1].tas == 80, "Missing GPS must not disable TAS")
        try expect(f.firstCoordinate == nil && f.lastCoordinate == nil, "Missing GPS remains unavailable")
    }

    static func timestampsWithoutTelemetry() throws {
        let f = try flight("""
        Lcl Date,Lcl Time,UTCOfst
        2026-10-31,12:00:00,+00:00
        2026-10-31,13:00:00,+00:00
        """)
        try expect(f.dt == "1.0", "Timestamp-only logs still yield recording duration")
        try expect(f.timeOutEpoch == 0 && f.timeOffEpoch == 0, "Missing telemetry must not invent events")
    }

    static func rpmSourceDoesNotSwitch() throws {
        let f = try flight("""
        Lcl Date,Lcl Time,UTCOfst,E1 RPM,E1 FFlow
        2026-10-31,12:00:00,+00:00,0,0
        2026-10-31,12:01:00,+00:00,300,8
        2026-10-31,12:02:00,+00:00,301,2
        2026-10-31,12:03:00,+00:00,,0
        2026-10-31,12:04:00,+00:00,0,0
        2026-10-31,12:05:00,+00:00,,0
        2026-10-31,12:06:00,+00:00,,9
        """)
        try expect(f.timeOutEpoch == epoch("2026-10-31T12:02:00Z"), "RPM threshold is strictly above 300, independent of fuel flow")
        try expect(f.timeInEpoch == epoch("2026-10-31T12:04:00Z"), "Blank RPM must not switch to fuel-flow detection")
        let missing = try flight("""
        Lcl Date,Lcl Time,UTCOfst,RPM,E1 FFlow
        2026-10-31,12:00:00,+00:00,,8
        2026-10-31,12:01:00,+00:00,,0
        """)
        try expect(missing.timeOutEpoch == 0, "An RPM column without samples must not silently use fuel flow")
    }

    static func coordinatesWithoutFixColumn() throws {
        let parsed = try rows("""
        Lcl Date,Lcl Time,UTCOfst,Latitude,Longitude
        2026-10-31,12:00:00,+00:00,41,-87
        2026-10-31,12:00:01,+00:00,91,-87
        """)
        try expect(parsed.count == 2, "GPS quality columns are optional")
        try expect(parsed[0].latitude == 41 && parsed[0].longitude == -87, "Finite in-range coordinates without quality columns")
        try expect(parsed[1].latitude == nil, "Missing fix column must not bypass coordinate bounds")
    }

    static func gpsValidation() throws {
        let header = "Lcl Date,Lcl Time,UTCOfst,Latitude,Longitude,GPSfix,HPLwas,VPLwas,TAS,E1 FFlow"
        let input = """
        \(header)
        2026-10-31,12:00:00,+00:00,41,-87,3D-,10,10,75,8
        2026-10-31,12:00:01,+00:00,41,-87,2D,10,10,75,8
        2026-10-31,12:00:02,+00:00,41,-87,3DDiff,100,10,75,8
        2026-10-31,12:00:03,+00:00,41,-87,3DDiff,10,100,75,8
        2026-10-31,12:00:04,+00:00,nan,-87,3DDiff,10,10,75,8
        2026-10-31,12:00:05,+00:00,91,-87,3DDiff,10,10,75,8
        2026-10-31,12:00:06,+00:00,41,181,3DDiff,10,10,75,8
        2026-10-31,12:00:07,+00:00,41,-87,3DDiff,,10,75,8
        2026-10-31,12:00:08,+00:00,41,-87,3DDiff,10,10,75,8
        """
        let parsed = try rows(input)
        try expect(parsed.count == 9, "Bad GPS must not discard valid timestamps")
        try expect(parsed.dropLast().allSatisfy { $0.latitude == nil && $0.longitude == nil }, "Invalid fixes, quality, and coordinates must not become airports")
        try expect(parsed.last?.latitude == 41, "Valid protected GPS coordinate")
        try expect(parsed.allSatisfy { $0.tas == 75 && $0.maxFFlow == 8 }, "Bad GPS must not suppress motion or engine data")
    }

    static func nonFiniteTelemetry() throws {
        let parsed = try rows("""
        Lcl Date,Lcl Time,UTCOfst,TAS,E1 FFlow
        2026-10-31,12:00:00,+00:00,nan,inf
        2026-10-31,12:00:01,+00:00,-inf,nan
        """)
        try expect(parsed.count == 2, "Nonfinite telemetry keeps valid timestamps")
        try expect(parsed.allSatisfy { $0.tas == nil && $0.maxFFlow == nil }, "NaN/infinity cannot trigger detections")
    }

    static func invalidTimestamps() throws {
        let parsed = try rows("""
        Lcl Date,Lcl Time,UTCOfst,TAS
        2026-02-29,12:00:00,+00:00,80
        2026-13-01,12:00:00,+00:00,80
        2026-10-31,25:00:00,+00:00,80
        2026-10-31,12:60:00,+00:00,80
        2026-10-31,12:00:99,+00:00,80
        2026-10-31,12:00:00,+00:99,80
        2026-10-31,12:00:00,,80
        2026-10-31,12:00:00,13:00:00,80
        2026-10-31
        2026-10-31,12:00:00,+00:00,80
        """)
        try expect(parsed.count == 1, "Malformed date/time/offset and short records must not create events")
        try expect(parsed[0].epochSec == epoch("2026-10-31T12:00:00Z"), "Continue after malformed records")
    }

    static func leapDayAndOffsets() throws {
        let positive = try flight("""
        Lcl Date,Lcl Time,UTCOfst
        2024-03-01,00:15:00,+05:30
        2024-03-01,00:45:00,+05:30
        """)
        try expect(positive.onDutyEpoch == epoch("2024-02-29T18:45:00Z"), "Positive fractional-hour offset across leap day")
        try expect(positive.date == "2024-02-29" && positive.dt == "0.5", "Display date must follow UTC")
        let negative = try flight("""
        Lcl Date,Lcl Time,UTCOfst
        2025-12-31,23:30:00,-03:30
        2026-01-01,00:30:00,-03:30
        """)
        try expect(negative.onDutyEpoch == epoch("2026-01-01T03:00:00Z"), "Negative fractional-hour offset across year")
        try expect(negative.offDutyEpoch == epoch("2026-01-01T04:00:00Z"), "Year rollover end time")
    }

    static func emptyAndUnsupported() throws {
        for text in ["", "x", "#", "#metadata\n", "Date,Description\n2026-10-31,hello\n", "\(gduCompactHeader)\n"] {
            let f = try flight(text)
            try expect(f.onDutyEpoch == 0 && f.dt.isEmpty, "Empty/unsupported/header-only input must fail safely")
        }
    }

    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("legacy G1000 compatibility", legacyCompatibility),
            ("GDU 465 dual headers and idle RPM", gduDualHeaders),
            ("verbose header aliases", verboseHeaderOnly),
            ("reordered and quoted CSV fields", reorderedQuotedFields),
            ("streaming, CRLF, and final line", streamingAndLineEndings),
            ("BOM on header", bomOnHeader),
            ("invalid UTF-8 in unrelated sensor field", invalidUTF8InUnrelatedField),
            ("telemetry without GPS", telemetryWithoutGPS),
            ("timestamps without telemetry", timestampsWithoutTelemetry),
            ("RPM threshold and fixed detection source", rpmSourceDoesNotSwitch),
            ("coordinates without fix column", coordinatesWithoutFixColumn),
            ("GPS quality and range validation", gpsValidation),
            ("nonfinite telemetry", nonFiniteTelemetry),
            ("malformed timestamps", invalidTimestamps),
            ("UTC offsets and date boundaries", leapDayAndOffsets),
            ("empty and unsupported files", emptyAndUnsupported),
        ] + trackTests
        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }
        print("\(tests.count - failures)/\(tests.count) parser and flight-track tests passed")
        if failures > 0 { exit(1) }
    }
}
