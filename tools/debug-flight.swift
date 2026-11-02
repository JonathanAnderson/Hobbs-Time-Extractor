import Foundation

/// Developer-only export. Keep engine readings out of the exported schema.
@main
struct DebugFlight {
    struct Sample: Encodable {
        let epochSec: Int
        let trueAirspeedKnots: Double?
        let groundSpeedKnots: Double?
        let indicatedAirspeedKnots: Double?
        let gpsAltitudeFeet: Double?
        let pressureAltitudeFeet: Double?
        let indicatedAltitudeFeet: Double?
        let recordedAGLFeet: Double?
        let verticalSpeedFeetPerMinute: Double?

        init(_ row: GarminRow) {
            epochSec = row.epochSec
            trueAirspeedKnots = row.tas
            groundSpeedKnots = row.groundSpeed
            indicatedAirspeedKnots = row.indicatedAirspeed
            gpsAltitudeFeet = row.gpsAltitude
            pressureAltitudeFeet = row.pressureAltitude
            indicatedAltitudeFeet = row.indicatedAltitude
            recordedAGLFeet = row.recordedAGL
            verticalSpeedFeetPerMinute = row.verticalSpeed
        }
    }

    struct Point: Encodable {
        let epochSec: Int
        let smoothedAltitudeFeet: Double?
        let estimatedAGLFeet: Double?
        let recordedAGLFeet: Double?
        let speedKnots: Double?
        let segmentID: Int

        init(_ point: FlightTrackPoint) {
            epochSec = point.epochSec
            smoothedAltitudeFeet = point.smoothedAltitudeFeet
            estimatedAGLFeet = point.estimatedAGLFeet
            recordedAGLFeet = point.recordedAGLFeet
            speedKnots = point.speedKnots
            segmentID = point.segmentID
        }
    }

    struct Flight: Encodable {
        let startEpoch: Int
        let endEpoch: Int
        let takeoffEpoch: Int
        let landingEpoch: Int
    }

    struct Export: Encodable {
        let schemaVersion = 1
        let fileName: String
        let firstTakeoffEpoch: Int
        let lastLandingEpoch: Int
        let flights: [Flight]
        let note: String
        let altitudeSource: String
        let samples: [Sample]
        let points: [Point]
    }

    struct UsageError: Error, CustomStringConvertible {
        let description: String
    }

    static let usage = """
    Usage: tools/debug-flight.sh [-o OUTPUT_DIRECTORY] LOG.csv [LOG.csv ...]

    Exports timestamped motion and altitude readings, smoothed values, and detected
    flight boundaries as JSON. Engine readings are not exported. The default output
    directory is debug/flights/ in the repository. Requires the macOS Swift toolchain.
    """

    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        var outputDirectory = URL(fileURLWithPath: "debug/flights", isDirectory: true)
        var paths: [String] = []
        var arguments = Array(CommandLine.arguments.dropFirst())[...]
        var acceptOptions = true
        while let argument = arguments.popFirst() {
            if acceptOptions && (argument == "-h" || argument == "--help") {
                print(usage)
                return
            } else if acceptOptions && (argument == "-o" || argument == "--output-dir") {
                guard let path = arguments.popFirst() else {
                    throw UsageError(description: "\(argument) needs a directory.\n\(usage)")
                }
                outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
            } else if acceptOptions && argument == "--" {
                acceptOptions = false
            } else if acceptOptions && argument.hasPrefix("-") {
                throw UsageError(description: "Unknown option: \(argument)\n\(usage)")
            } else {
                paths.append(argument)
            }
        }
        guard !paths.isEmpty else { throw UsageError(description: usage) }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var outputNames: Set<String> = []
        for path in paths {
            let input = URL(fileURLWithPath: path)
            guard let reader = GarminTimeReader(url: input) else {
                throw UsageError(description: "Could not open \(input.path)")
            }
            let rows = Array(reader)
            guard !rows.isEmpty else {
                throw UsageError(description: "No valid timestamped rows in \(input.path)")
            }
            let analysis = FlightTrackAnalyzer.analyze(rows)
            let document = Export(
                fileName: input.lastPathComponent,
                firstTakeoffEpoch: analysis.firstTakeoffEpoch,
                lastLandingEpoch: analysis.lastLandingEpoch,
                flights: analysis.flights.map {
                    Flight(startEpoch: $0.startEpoch, endEpoch: $0.endEpoch,
                           takeoffEpoch: $0.takeoffEpoch, landingEpoch: $0.landingEpoch)
                },
                note: analysis.note,
                altitudeSource: analysis.altitudeSource,
                samples: rows.map(Sample.init),
                points: analysis.points.map(Point.init)
            )
            let stem = input.deletingPathExtension().lastPathComponent
            var name = "\(stem).flight.json"
            var duplicate = 2
            while !outputNames.insert(name).inserted {
                name = "\(stem)-\(duplicate).flight.json"
                duplicate += 1
            }
            let output = outputDirectory.appendingPathComponent(name)
            try encoder.encode(document).write(to: output, options: .atomic)
            print(output.path)
        }
    }
}
