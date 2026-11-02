import Foundation

struct FlightTrackPoint: Sendable {
    let epochSec: Int
    let smoothedAltitudeFeet: Double?
    /// Height above interpolated taxi elevations, not terrain clearance en route.
    let estimatedAGLFeet: Double?
    let recordedAGLFeet: Double?
    let speedKnots: Double?
    let segmentID: Int
}

struct DetectedFlight: Sendable {
    let takeoffEpoch: Int     // 0 when the departure was not observed
    let landingEpoch: Int     // 0 when the arrival was not observed
    let startEpoch: Int       // observed airborne interval, including incomplete logs
    let endEpoch: Int
}

struct FlightTrackAnalysis: Sendable {
    let points: [FlightTrackPoint]
    let firstTakeoffEpoch: Int
    let lastLandingEpoch: Int
    let flights: [DetectedFlight]
    let note: String
    let altitudeSource: String

    static let empty = FlightTrackAnalysis(points: [], firstTakeoffEpoch: 0,
        lastLandingEpoch: 0, flights: [], note: "No flight data", altitudeSource: "Unavailable")
}

/// Offline flight estimates using only timestamp, altitude, and motion measurements.
/// Engine data is deliberately excluded from every calculation in this type.
enum FlightTrackAnalyzer {
    private static let gapSeconds = 15

    static func analyze(_ input: [GarminRow]) -> FlightTrackAnalysis {
        // A duplicate must not count as extra evidence or overweight the smoother.
        var rows: [GarminRow] = []
        for row in input where row.epochSec > 0 {
            if let last = rows.last, row.epochSec <= last.epochSec { continue }
            rows.append(row)
        }
        guard !rows.isEmpty else { return .empty }
        let times = rows.map(\.epochSec)
        var segmentIDs = [Int](repeating: 0, count: rows.count)
        for i in rows.indices.dropFirst() {
            segmentIDs[i] = segmentIDs[i - 1] + (times[i] - times[i - 1] > gapSeconds ? 1 : 0)
        }
        func valid(_ value: Double?, range: ClosedRange<Double>) -> Double? {
            guard let value, value.isFinite, range.contains(value) else { return nil }
            return value
        }
        let gps = rows.map { valid($0.gpsAltitude, range: -2000...65000) }
        let pressure = rows.map { valid($0.pressureAltitude, range: -2000...65000) }
        let indicated = rows.map { valid($0.indicatedAltitude, range: -2000...65000) }
        let sources = [("GPS altitude", gps), ("Pressure altitude", pressure), ("Indicated altitude", indicated)]
        // Keep a single vertical reference for the file. Switching between GPS and
        // barometric altitude sample by sample creates fictitious climbs/descents.
        let source = sources.first { $0.1.compactMap { $0 }.count >= max(3, rows.count / 2) }
            ?? sources.max { a, b in a.1.compactMap { $0 }.count < b.1.compactMap { $0 }.count }!
        let hasAltitude = source.1.contains { $0 != nil }
        let rawAGL = rows.map { valid($0.recordedAGL, range: 0...60000) }
        // An isolated sensor value is not enough to disable the speed-only fallback.
        let altitudeAvailable = !sustainedIndices(source.1.map { $0 != nil }, times: times,
            segments: segmentIDs, seconds: 8).isEmpty || !sustainedIndices(rawAGL.map { $0 != nil },
            times: times, segments: segmentIDs, seconds: 8).isEmpty
        // A long sensor outage must not turn the first recovered taxi sample into
        // a precise touchdown. Split on recovery, just as for missing timestamps.
        var lastAltitudeTime: Int?
        var segment = 0
        for i in rows.indices {
            let timeGap = i > 0 && times[i] - times[i - 1] > gapSeconds
            if timeGap { segment += 1; lastAltitudeTime = nil }
            if altitudeAvailable && (source.1[i] != nil || rawAGL[i] != nil) {
                if let lastAltitudeTime, times[i] - lastAltitudeTime > gapSeconds { segment += 1 }
                lastAltitudeTime = times[i]
            }
            segmentIDs[i] = segment
        }
        let altitude = smooth(source.1, times: times, segments: segmentIDs)
        let agl = smooth(rawAGL, times: times, segments: segmentIDs)
        let airspeed = smooth(rows.map {
            valid($0.indicatedAirspeed, range: 0...600) ?? valid($0.tas, range: 0...600)
        }, times: times, segments: segmentIDs)
        let groundSpeed = smooth(rows.map { valid($0.groundSpeed, range: 0...700) }, times: times, segments: segmentIDs)
        let speed = rows.indices.map { airspeed[$0] ?? groundSpeed[$0] }
        let rates = verticalRates(altitude, times: times, segments: segmentIDs)

        // Ground references require sustained slow motion and stable altitude, with
        // logged AGL vetoing slow flight aloft. Never assume the file starts on ground.
        let anchorCandidates = rows.indices.map { i in
            let slow = groundSpeed[i].map { $0 < 15 && (airspeed[i] ?? 0) < 35 }
                ?? (airspeed[i].map { $0 < 20 } ?? false)
            return slow && (agl[i] ?? 0) < 100 && altitude[i] != nil
                && abs(rates[i] ?? .infinity) < 150
        }
        let anchorIndices = sustainedIndices(anchorCandidates, times: times, segments: segmentIDs, seconds: 12)
        var before = [Int?](repeating: nil, count: rows.count)
        var after = before
        var anchor: Int?
        for i in rows.indices {
            if i == 0 || segmentIDs[i] != segmentIDs[i - 1] { anchor = nil }
            if anchorIndices.contains(i) { anchor = i }
            before[i] = anchor
        }
        anchor = nil
        for i in rows.indices.reversed() {
            if i == rows.count - 1 || segmentIDs[i] != segmentIDs[i + 1] { anchor = nil }
            if anchorIndices.contains(i) { anchor = i }
            after[i] = anchor
        }
        let heights: [Double?] = rows.indices.map { i in
            guard let alt = altitude[i] else { return nil }
            let reference: Double
            if let a = before[i], let b = after[i], a != b {
                let fraction = Double(times[i] - times[a]) / Double(times[b] - times[a])
                reference = altitude[a]! + fraction * (altitude[b]! - altitude[a]!)
            } else if let a = before[i] ?? after[i] {
                reference = altitude[a]!
            } else { return nil }
            return max(0, alt - reference)
        }
        let points = rows.indices.map { i in
            FlightTrackPoint(epochSec: times[i], smoothedAltitudeFeet: altitude[i],
                estimatedAGLFeet: heights[i], recordedAGLFeet: agl[i],
                speedKnots: speed[i], segmentID: segmentIDs[i])
        }

        func refineTakeoff(_ i: Int) -> Int {
            guard let referenceIndex = before[i], let reference = altitude[referenceIndex] else { return times[i] }
            var start = i
            while start > referenceIndex && times[i] - times[start - 1] <= 90 { start -= 1 }
            for j in start...i {
                if let alt = altitude[j], alt - reference >= 15,
                   (speed[j] ?? 0) > 25, (rates[j] ?? 0) > 100 { return times[j] }
            }
            return times[i]
        }
        func refineLanding(_ i: Int, lastAir: Int) -> Int {
            guard let referenceIndex = after[i] ?? before[i], let reference = altitude[referenceIndex] else { return times[i] }
            var start = i
            while start > lastAir && times[i] - times[start - 1] <= 90 { start -= 1 }
            for j in start...i {
                if let alt = altitude[j], alt - reference <= 15,
                   abs(rates[j] ?? .infinity) <= 180 { return times[j] }
            }
            return times[i]
        }

        var flights: [DetectedFlight] = []
        var airStart: Int?
        var groundStart: Int?
        var activeStart: Int?
        var takeoff = 0
        var lastAir = 0
        var groundSeen = false
        var groundEvidenceStart: Int?
        var usedSpeedOnly = false
        for i in rows.indices {
            if i > 0 && segmentIDs[i] != segmentIDs[i - 1] {
                if let start = activeStart {
                    flights.append(DetectedFlight(takeoffEpoch: takeoff, landingEpoch: 0,
                        startEpoch: times[start], endEpoch: times[i - 1]))
                }
                activeStart = nil; airStart = nil; groundStart = nil
                groundSeen = false; groundEvidenceStart = nil
            }
            if anchorIndices.contains(i) { groundSeen = true }
            let slowGround = groundSpeed[i].map { $0 < 30 && (airspeed[i] ?? 0) < 50 }
                ?? (airspeed[i].map { $0 < 35 } ?? false)
            let isAir: Bool
            let isGround: Bool
            if altitudeAvailable {
                isAir = (speed[i] ?? 0) > 25 && ((agl[i] ?? 0) >= 100 || (heights[i] ?? 0) >= 60)
                isGround = slowGround && (agl[i] ?? 0) < 100
                    && (heights[i].map { $0 <= 35 } ?? (agl[i].map { $0 <= 50 } ?? false))
            } else {
                // Explicitly lower-confidence fallback for logs without altitude.
                isAir = (speed[i] ?? 0) > 60
                isGround = (speed[i].map { $0 < 40 } ?? false)
                usedSpeedOnly = true
            }
            // Recorded AGL alone can establish ground, without an absolute-altitude
            // taxi reference. The same dwell requirement applies to the fallback.
            if isGround {
                if groundEvidenceStart == nil { groundEvidenceStart = i }
                if times[i] - times[groundEvidenceStart!] >= 12 { groundSeen = true }
            } else { groundEvidenceStart = nil }
            if activeStart == nil {
                if isAir {
                    if airStart == nil { airStart = i }
                    if times[i] - times[airStart!] >= 8 {
                        activeStart = airStart
                        takeoff = groundSeen ? refineTakeoff(airStart!) : 0
                        lastAir = i
                        groundStart = nil
                    }
                } else { airStart = nil }
            } else {
                if isAir { lastAir = i }
                if isGround {
                    if groundStart == nil { groundStart = i }
                    if times[i] - times[groundStart!] >= 12 {
                        let landing = refineLanding(groundStart!, lastAir: lastAir)
                        flights.append(DetectedFlight(takeoffEpoch: takeoff, landingEpoch: landing,
                            startEpoch: times[activeStart!], endEpoch: times[groundStart!]))
                        activeStart = nil; airStart = nil; groundStart = nil
                        groundSeen = true
                    }
                } else { groundStart = nil }
            }
        }
        if let start = activeStart {
            flights.append(DetectedFlight(takeoffEpoch: takeoff, landingEpoch: 0,
                startEpoch: times[start], endEpoch: times.last!))
        }
        var notes: [String] = []
        if flights.isEmpty { notes.append("No sustained flight detected") }
        else {
            notes.append(usedSpeedOnly ? "Estimated from smoothed motion" : "Estimated from smoothed altitude and motion")
            if flights.count > 1 { notes.append("\(flights.count) observed flight intervals; first departure and final arrival") }
            if flights.first?.takeoffEpoch == 0 { notes.append("First takeoff not observed") }
            if flights.last?.landingEpoch == 0 { notes.append("Final landing not observed") }
        }
        if usedSpeedOnly { notes.append("Speed-only estimate; altitude unavailable") }
        if (segmentIDs.last ?? 0) > 0 { notes.append("Gaps over \(gapSeconds)s split the track") }
        return FlightTrackAnalysis(points: points, firstTakeoffEpoch: flights.first?.takeoffEpoch ?? 0,
            lastLandingEpoch: flights.last?.landingEpoch ?? 0, flights: flights,
            note: notes.joined(separator: ". "), altitudeSource: hasAltitude ? source.0 : "Unavailable")
    }

    /// Centered median removes isolated spikes; a second short centered mean smooths
    /// the profile without the phase delay of a causal filter. Windows use seconds.
    private static func smooth(_ values: [Double?], times: [Int], segments: [Int]) -> [Double?] {
        func pass(_ input: [Double?], median: Bool) -> [Double?] {
            var result = [Double?](repeating: nil, count: input.count)
            var lo = 0, hi = 0
            for i in input.indices {
                while lo < i && (times[i] - times[lo] > 2 || segments[lo] != segments[i]) { lo += 1 }
                hi = max(hi, i)
                while hi + 1 < input.count && times[hi + 1] - times[i] <= 2 && segments[hi + 1] == segments[i] { hi += 1 }
                let available = input[lo...hi].compactMap { $0 }.sorted()
                guard !available.isEmpty else { continue }
                if median {
                    let mid = available.count / 2
                    result[i] = available.count.isMultiple(of: 2) ? (available[mid - 1] + available[mid]) / 2 : available[mid]
                } else { result[i] = available.reduce(0, +) / Double(available.count) }
            }
            return result
        }
        return pass(pass(values, median: true), median: false)
    }

    private static func verticalRates(_ altitudes: [Double?], times: [Int], segments: [Int]) -> [Double?] {
        var rates = [Double?](repeating: nil, count: times.count)
        for i in times.indices {
            var a = i, b = i
            while a > 0 && times[i] - times[a - 1] <= 5 && segments[a - 1] == segments[i] { a -= 1 }
            while b + 1 < times.count && times[b + 1] - times[i] <= 5 && segments[b + 1] == segments[i] { b += 1 }
            if a < b, let first = altitudes[a], let last = altitudes[b] {
                rates[i] = (last - first) * 60 / Double(times[b] - times[a])
            }
        }
        return rates
    }

    private static func sustainedIndices(_ flags: [Bool], times: [Int], segments: [Int], seconds: Int) -> Set<Int> {
        var result = Set<Int>()
        var start: Int?
        func finish(_ end: Int) {
            if let start, times[end] - times[start] >= seconds { result.formUnion(start...end) }
        }
        for i in flags.indices {
            if i > 0 && segments[i] != segments[i - 1] { finish(i - 1); start = nil }
            if flags[i] { if start == nil { start = i } }
            else if start != nil { finish(i - 1); start = nil }
        }
        if start != nil { finish(flags.count - 1) }
        return result
    }
}
