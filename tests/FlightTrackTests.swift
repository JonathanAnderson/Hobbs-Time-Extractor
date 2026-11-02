import Foundation

extension GarminExtractorTests {
    static let trackStart = 1_793_448_000

    // Physical profile: ground through second 79, climb at 80, level at 120,
    // descent at 240, touchdown at 280, and stopped at 300. Samples are 1 Hz.
    static func syntheticTrack(start: Int = trackStart, count: Int = 360,
                               slowAirborne: Bool = false, spikes: Bool = false,
                               rpm: Double? = nil, fuelFlow: Double? = nil) -> [GarminRow] {
        (0..<count).map { second in
            let height: Double
            let speed: Double
            switch second {
            case ..<60:
                height = 0; speed = 0
            case 60..<80:
                height = 0; speed = Double(second - 60) * 3.5
            case 80..<120:
                height = Double(second - 80) * 10; speed = 75
            case 120..<240:
                height = 400; speed = slowAirborne && (140...200).contains(second) ? 25 : 85
            case 240..<280:
                height = Double(280 - second) * 10; speed = 60
            case 280..<300:
                height = 0; speed = Double(300 - second) * 3
            default:
                height = 0; speed = 0
            }
            var row = GarminRow(epochSec: start + second, latitude: 41.6, longitude: -87.4,
                                tas: speed, maxFFlow: fuelFlow, maxRPM: rpm)
            row.groundSpeed = speed
            row.indicatedAirspeed = speed
            row.gpsAltitude = 500 + height
            row.pressureAltitude = 450 + height
            row.indicatedAltitude = 510 + height
            row.recordedAGL = height
            row.verticalSpeed = (80..<120).contains(second) ? 600 : ((240..<280).contains(second) ? -600 : 0)
            if spikes && second == 30 {
                row.gpsAltitude = 10_000
                row.recordedAGL = 9_500
                row.groundSpeed = 150
            }
            if spikes && second == 180 {
                row.gpsAltitude = 500
                row.recordedAGL = 0
                row.groundSpeed = 0
            }
            return row
        }
    }

    static func expectSingleFlight(_ analysis: FlightTrackAnalysis, start: Int = trackStart) throws {
        try expect(analysis.flights.count == 1, "A continuous climb/cruise/descent should be one flight")
        try expect((start + 75...start + 110).contains(analysis.firstTakeoffEpoch), "Takeoff must follow the ground roll and climb")
        try expect((start + 265...start + 305).contains(analysis.lastLandingEpoch), "Landing must be near touchdown, not low-speed cruise")
    }

    static func trackSingleFlight() throws {
        let analysis = FlightTrackAnalyzer.analyze(syntheticTrack())
        try expectSingleFlight(analysis)
        try expect(analysis.points.count == 360, "A point is retained for each valid distinct sample")
        try expect(!analysis.altitudeSource.isEmpty, "The selected altitude source is identified")
    }

    static func trackNoiseAndSpikes() throws {
        let clean = FlightTrackAnalyzer.analyze(syntheticTrack())
        let noisy = FlightTrackAnalyzer.analyze(syntheticTrack(spikes: true))
        try expectSingleFlight(noisy)
        try expect(abs(noisy.firstTakeoffEpoch - clean.firstTakeoffEpoch) <= 5, "One ground altitude/speed spike must not move takeoff")
        try expect(abs(noisy.lastLandingEpoch - clean.lastLandingEpoch) <= 5, "One cruise altitude/speed drop must not move landing")
        let spikePoint = noisy.points.first { $0.epochSec == trackStart + 30 }
        try expect((spikePoint?.smoothedAltitudeFeet ?? .infinity) < 600, "Smoothing must reject an isolated 9,500 ft altitude spike")
    }

    static func trackSlowAirborne() throws {
        let analysis = FlightTrackAnalyzer.analyze(syntheticTrack(slowAirborne: true))
        try expectSingleFlight(analysis)
        try expect(analysis.flights.allSatisfy { $0.landingEpoch > trackStart + 240 }, "Sustained TAS below 40 at altitude cannot count as landing")
    }

    static func trackMultipleFlights() throws {
        let rows = syntheticTrack() + syntheticTrack(start: trackStart + 360)
        let analysis = FlightTrackAnalyzer.analyze(rows)
        try expect(analysis.flights.count == 2, "Two ground-separated flights must both be detected")
        try expect((trackStart + 75...trackStart + 110).contains(analysis.firstTakeoffEpoch), "Summary must use the first takeoff")
        try expect((trackStart + 625...trackStart + 665).contains(analysis.lastLandingEpoch), "Summary must use the final landing")
        try expect(analysis.lastLandingEpoch == analysis.flights.last?.landingEpoch, "Final summary must not retain the first flight's landing")
    }

    static func trackEngineIndependent() throws {
        let absent = FlightTrackAnalyzer.analyze(syntheticTrack())
        for (rpm, flow) in [(0.0, 0.0), (2_700.0, 18.0)] {
            let analysis = FlightTrackAnalyzer.analyze(syntheticTrack(rpm: rpm, fuelFlow: flow))
            try expect(analysis.firstTakeoffEpoch == absent.firstTakeoffEpoch && analysis.lastLandingEpoch == absent.lastLandingEpoch,
                       "Engine RPM/fuel flow cannot influence flight boundaries")
            try expect(analysis.flights.count == absent.flights.count, "Engine signals cannot alter the flight count")
            try expect(analysis.points.map(\.estimatedAGLFeet) == absent.points.map(\.estimatedAGLFeet), "Engine signals cannot affect altitude estimates")
        }
    }

    static func trackStationaryAltitudeChange() throws {
        let rows = (0..<360).map { second in
            var row = GarminRow(epochSec: trackStart + second, latitude: 41.6, longitude: -87.4,
                                tas: 0, maxFFlow: 18, maxRPM: 2_700)
            row.groundSpeed = 0
            row.indicatedAirspeed = 0
            // Changing altimeter setting while parked, with no usable GPS/pressure altitude.
            row.indicatedAltitude = 500 + Double(second < 180 ? second : 360 - second) * 3
            return row
        }
        let analysis = FlightTrackAnalyzer.analyze(rows)
        try expect(analysis.flights.isEmpty && analysis.firstTakeoffEpoch == 0 && analysis.lastLandingEpoch == 0,
                   "Altitude changes without motion must not create a flight")
    }

    static func trackWithoutRecordedAGL() throws {
        for pressureOnly in [false, true] {
            let rows = syntheticTrack().map { original in
                var row = original
                row.recordedAGL = nil
                if pressureOnly { row.gpsAltitude = nil }
                return row
            }
            let analysis = FlightTrackAnalyzer.analyze(rows)
            try expectSingleFlight(analysis)
            let cruise = analysis.points.first { $0.epochSec == trackStart + 180 }
            try expect((cruise?.estimatedAGLFeet ?? 0) > 300, "Height must be estimated from altitude and ground observations when recorded AGL is absent")
        }
    }

    static func trackRecordedAGLWithoutAbsoluteAltitude() throws {
        let rows = syntheticTrack().map { original in
            var row = original
            row.gpsAltitude = nil
            row.pressureAltitude = nil
            row.indicatedAltitude = nil
            return row
        }
        let analysis = FlightTrackAnalyzer.analyze(rows)
        try expectSingleFlight(analysis)
        try expect(analysis.firstTakeoffEpoch > 0 && analysis.lastLandingEpoch > 0,
                   "Sustained ground and airborne AGL must support observed boundaries without absolute altitude")
    }

    static func trackIsolatedAltitudeKeepsSpeedFallback() throws {
        let speedOnly = syntheticTrack().map { original in
            var row = original
            row.gpsAltitude = nil
            row.pressureAltitude = nil
            row.indicatedAltitude = nil
            row.recordedAGL = nil
            return row
        }
        var isolated = speedOnly
        isolated[180].gpsAltitude = 900
        let baseline = FlightTrackAnalyzer.analyze(speedOnly)
        let analysis = FlightTrackAnalyzer.analyze(isolated)
        try expectSingleFlight(baseline)
        try expectSingleFlight(analysis)
        try expect(analysis.firstTakeoffEpoch == baseline.firstTakeoffEpoch && analysis.lastLandingEpoch == baseline.lastLandingEpoch,
                   "One isolated absolute altitude sample must not disable sustained speed-only fallback")
    }

    static func trackHigherArrivalElevation() throws {
        let rows = syntheticTrack().enumerated().map { second, original in
            var row = original
            let altitude: Double
            switch second {
            case ..<80: altitude = 500
            case 80..<120: altitude = 500 + Double(second - 80) * 20
            case 120..<240: altitude = 1_300
            case 240..<280: altitude = 900 + Double(280 - second) * 10
            default: altitude = 900
            }
            row.gpsAltitude = altitude
            row.pressureAltitude = altitude - 50
            row.indicatedAltitude = altitude + 10
            row.recordedAGL = nil
            return row
        }
        let analysis = FlightTrackAnalyzer.analyze(rows)
        try expectSingleFlight(analysis)
        let arrived = analysis.points.first { $0.epochSec == trackStart + 320 }
        try expect(abs(arrived?.estimatedAGLFeet ?? .infinity) < 40,
                   "Arrival ground reference must account for an airport 400 ft above departure")
    }

    static func trackSparseGPSUsesPressure() throws {
        let rows = syntheticTrack().enumerated().map { second, original in
            var row = original
            row.gpsAltitude = second % 10 == 0 ? 50_000 : nil
            row.recordedAGL = nil
            return row
        }
        let analysis = FlightTrackAnalyzer.analyze(rows)
        try expectSingleFlight(analysis)
        try expect(analysis.points.allSatisfy { ($0.smoothedAltitudeFeet ?? 0) < 1_000 },
                   "Sparse GPS altitude must not be mixed into the selected pressure-altitude source")
    }

    static func trackSpeedOnlyFallback() throws {
        let rows = (0..<150).map { second in
            let speed: Double = (60..<90).contains(second) || second == 30 ? 80 : 0
            var row = GarminRow(epochSec: trackStart + second, latitude: nil, longitude: nil,
                                tas: speed, maxFFlow: nil, maxRPM: nil)
            row.groundSpeed = speed
            return row
        }
        let analysis = FlightTrackAnalyzer.analyze(rows)
        try expect(analysis.flights.count == 1, "Speed-only fallback must reject a single-sample speed spike")
        try expect((trackStart + 55...trackStart + 75).contains(analysis.firstTakeoffEpoch), "Speed-only fallback requires sustained high speed")
        try expect((trackStart + 85...trackStart + 110).contains(analysis.lastLandingEpoch), "Speed-only fallback requires sustained low speed")
        try expect(!analysis.note.isEmpty, "Reduced evidence in speed-only fallback must be identified")
    }

    static func trackDisorderedSamples() throws {
        let cleanRows = syntheticTrack()
        var mixed = Array(cleanRows.prefix(150))
        mixed.append(cleanRows[149]) // Duplicate timestamp.
        mixed.append(cleanRows[100]) // Old sample delivered late.
        mixed.append(contentsOf: cleanRows.dropFirst(150))
        let clean = FlightTrackAnalyzer.analyze(cleanRows)
        let analysis = FlightTrackAnalyzer.analyze(mixed)
        try expect(analysis.points.map(\.epochSec) == clean.points.map(\.epochSec), "Duplicate/backward epochs must be skipped without reordering the track")
        try expect(analysis.firstTakeoffEpoch == clean.firstTakeoffEpoch && analysis.lastLandingEpoch == clean.lastLandingEpoch,
                   "Duplicate/backward samples must not change flight boundaries")
    }

    static func trackGapDoesNotInventTransition() throws {
        let clean = syntheticTrack()
        let rows = Array(clean.prefix(60)) + Array(clean[200..<240])
        let analysis = FlightTrackAnalyzer.analyze(rows)
        try expect(Set(analysis.points.map(\.segmentID)).count == 2, "A long recording gap must split smoothing/detection segments")
        try expect(analysis.points.count == rows.count, "No samples may be interpolated across a recording gap")
        try expect(analysis.firstTakeoffEpoch == 0 && analysis.lastLandingEpoch == 0, "A ground-to-air transition hidden in a gap is unobserved")
        let beforeGap = analysis.points.first { $0.epochSec == trackStart + 59 }
        let afterGap = analysis.points.first { $0.epochSec == trackStart + 200 }
        try expect((beforeGap?.smoothedAltitudeFeet ?? .infinity) < 550, "Future airborne segment must not smooth backward across a gap")
        try expect((afterGap?.smoothedAltitudeFeet ?? 0) > 850, "Past ground segment must not smooth forward across a gap")
    }

    static func trackAltitudeOutageAtLanding() throws {
        let rows = syntheticTrack().enumerated().map { second, original in
            var row = original
            if (260..<320).contains(second) {
                row.gpsAltitude = nil
                row.pressureAltitude = nil
                row.indicatedAltitude = nil
                row.recordedAGL = nil
            }
            return row
        }
        let analysis = FlightTrackAnalyzer.analyze(rows)
        try expect(analysis.points.count == rows.count, "An altitude outage must preserve valid timestamp/motion samples")
        try expect(Set(analysis.points.map(\.segmentID)).count == 2, "A long altitude/AGL outage must split the track on sensor recovery")
        try expect(analysis.flights.count == 1 && analysis.firstTakeoffEpoch > 0, "Observed departure must survive the arrival sensor outage")
        try expect(analysis.lastLandingEpoch == 0 && analysis.flights.last?.landingEpoch == 0,
                   "Touchdown hidden by an altitude outage cannot be replaced with taxi recovery time")
        let missing = analysis.points.first { $0.epochSec == trackStart + 290 }
        try expect(missing?.smoothedAltitudeFeet == nil && missing?.recordedAGLFeet == nil,
                   "The missing touchdown altitude must not be filled across a long sensor outage")
    }

    static func trackUnfinishedFinalFlight() throws {
        let rows = syntheticTrack() + syntheticTrack(start: trackStart + 360, count: 200)
        let analysis = FlightTrackAnalyzer.analyze(rows)
        try expect(analysis.flights.count == 2, "An unfinished second flight is still a distinct flight")
        try expect(analysis.firstTakeoffEpoch > 0, "Observed first departure remains available")
        try expect(analysis.lastLandingEpoch == 0 && analysis.flights.last?.landingEpoch == 0, "An unfinished final flight must not reuse an earlier landing or invent EOF landing")
    }

    static func trackStartsAirborne() throws {
        let rows = Array(syntheticTrack().dropFirst(150))
        let analysis = FlightTrackAnalyzer.analyze(rows)
        try expect(analysis.flights.count == 1, "A log starting airborne can retain its observed arrival")
        try expect(analysis.firstTakeoffEpoch == 0 && analysis.flights.first?.takeoffEpoch == 0, "First sample already airborne is not an observed takeoff")
        try expect((trackStart + 265...trackStart + 305).contains(analysis.lastLandingEpoch), "Observed landing still works when takeoff was before the log")
    }

    static func trackColumnAliases() throws {
        let compact = "Lcl Date,Lcl Time,UTCOfst,Latitude,Longitude,GPSfix,GndSpd,IAS,AltGPS,AltP,AltInd,AGL,VSpd"
        let verbose = "Date (yyyy-mm-dd),Time (hh:mm:ss),UTC Offset (hh:mm),Latitude (deg),Longitude (deg),GPS Fix Status,GPS Ground Speed (kt),Indicated Airspeed (kt),GPS Altitude (ft),Pressure Altitude (ft),Baro Altitude (ft),Height Above Ground (ft),Vertical Speed (ft/min)"
        for header in [compact, verbose] {
            let parsed = try rows(header + "\n2026-10-31,12:00:00,+00:00,41.6,-87.4,3D,72,68,1250,1190,1230,400,-300")
            try expect(parsed.count == 1, "Altitude/motion alias fixture must parse")
            let row = parsed[0]
            try expect(row.groundSpeed == 72 && row.indicatedAirspeed == 68, "Groundspeed and IAS aliases must preserve knots")
            try expect(row.gpsAltitude == 1250 && row.pressureAltitude == 1190 && row.indicatedAltitude == 1230,
                       "Altitude aliases must preserve feet and source identity")
            try expect(row.recordedAGL == 400 && row.verticalSpeed == -300, "AGL and signed vertical speed aliases")
        }
        let legacyMSL = try rows("Lcl Date,Lcl Time,UTCOfst,Latitude,Longitude,GPSfix,AltMSL,AltGPS\n2026-10-31,12:00:00,+00:00,41.6,-87.4,3D,1250,4000")
        try expect(legacyMSL.first?.gpsAltitude == 1250, "Legacy GPS AltMSL is preferred when both GPS altitude columns are available")
    }

    static func trackGPSProtectionDoesNotDiscardMotion() throws {
        let parsed = try rows("""
        Lcl Date,Lcl Time,UTCOfst,Latitude,Longitude,GPSfix,HPLwas,VPLwas,AltMSL,GndSpd
        2026-10-31,12:00:00,+00:00,41.6,-87.4,3DDiff,10,100,1250,72
        2026-10-31,12:00:01,+00:00,41.6,-87.4,3D-,10,10,1250,72
        """)
        try expect(parsed.count == 2, "Protection-level fixtures must retain valid timestamps")
        try expect(parsed[0].latitude == nil && parsed[0].longitude == nil, "VPL 100 still rejects route coordinates")
        try expect(parsed[0].gpsAltitude == 1250 && parsed[0].groundSpeed == 72,
                   "A valid 3D fix retains flight altitude/groundspeed despite the stricter route VPL limit")
        try expect(parsed[1].gpsAltitude == nil && parsed[1].groundSpeed == nil,
                   "An invalid GPS fix must still reject GPS motion and altitude")
    }

    static var trackTests: [(String, () throws -> Void)] {
        [
            ("track single observed flight", trackSingleFlight),
            ("track rejects isolated altitude/speed spikes", trackNoiseAndSpikes),
            ("track slow airborne is not a landing", trackSlowAirborne),
            ("track first takeoff and final landing", trackMultipleFlights),
            ("track detection ignores engine signals", trackEngineIndependent),
            ("track stationary altimeter changes", trackStationaryAltitudeChange),
            ("track estimates AGL without recorded height", trackWithoutRecordedAGL),
            ("track AGL without absolute altitude", trackRecordedAGLWithoutAbsoluteAltitude),
            ("track isolated altitude keeps speed fallback", trackIsolatedAltitudeKeepsSpeedFallback),
            ("track higher-elevation arrival", trackHigherArrivalElevation),
            ("track selects a stable altitude source", trackSparseGPSUsesPressure),
            ("track sustained speed-only fallback", trackSpeedOnlyFallback),
            ("track duplicate and backward timestamps", trackDisorderedSamples),
            ("track gap boundaries", trackGapDoesNotInventTransition),
            ("track altitude outage during touchdown", trackAltitudeOutageAtLanding),
            ("track unfinished final flight", trackUnfinishedFinalFlight),
            ("track starts already airborne", trackStartsAirborne),
            ("altitude and motion column aliases", trackColumnAliases),
            ("GPS protection limits preserve motion", trackGPSProtectionDoesNotDiscardMotion),
        ]
    }
}
