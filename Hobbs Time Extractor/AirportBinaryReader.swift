//
//  AirportBinaryReader.swift
//  Time Extractor
//

import Foundation

// MARK: - AirportRecord

struct AirportRecord: Identifiable, Hashable {
    let identifier: String
    let latitudeDegrees: Double
    let longitudeDegrees: Double
    let latitudeRadians: Double
    let longitudeRadians: Double
    let unitX: Double
    let unitY: Double
    let unitZ: Double

    var id: String { identifier }
}

// MARK: - Errors

enum AirportBinaryReaderError: LocalizedError {
    case fileTooSmall(actualBytes: Int)
    case badMagic(expected: String, actual: String)
    case badFileSize(expected: Int, actual: Int)
    case unreasonableAirportCount(UInt32)
    case truncatedRecord(index: Int)
    case badIdentifier(index: Int)
    case invalidNumber(index: Int, field: String, value: Double)
    case outOfRange(index: Int, field: String, value: Double)
    case badUnitVector(index: Int, lengthSquared: Double)

    var errorDescription: String? {
        switch self {
        case .fileTooSmall(let actualBytes):
            return "Airport binary file is too small: \(actualBytes) bytes"
        case .badMagic(let expected, let actual):
            return "Bad airport binary magic. Expected \(expected), got \(actual)"
        case .badFileSize(let expected, let actual):
            return "Bad airport binary file size. Expected \(expected) bytes, got \(actual) bytes"
        case .unreasonableAirportCount(let count):
            return "Airport count is suspiciously large: \(count)"
        case .truncatedRecord(let index):
            return "Airport binary file is truncated at record \(index)"
        case .badIdentifier(let index):
            return "Airport record \(index) has an invalid identifier"
        case .invalidNumber(let index, let field, let value):
            return "Airport record \(index) has invalid \(field): \(value)"
        case .outOfRange(let index, let field, let value):
            return "Airport record \(index) has out-of-range \(field): \(value)"
        case .badUnitVector(let index, let lengthSquared):
            return "Airport record \(index) has bad unit vector length squared: \(lengthSquared)"
        }
    }
}

// MARK: - AirportBinaryReader

final class AirportBinaryReader {
    static let defaultFileName = "faa_airports"
    static let defaultFileExtension = "bin"

    private static let magic = "FAAPT001"
    private static let headerSize = 12
    private static let recordSize = 64
    private static let maxReasonableAirportCount: UInt32 = 100_000
    private static let unitVectorTolerance = 1.0e-10

    static func loadFromBundle(
        fileName: String = defaultFileName,
        fileExtension: String = defaultFileExtension,
        bundle: Bundle = .main
    ) throws -> [AirportRecord] {
        guard let url = bundle.url(forResource: fileName, withExtension: fileExtension) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try load(from: url)
    }

    static func load(from url: URL) throws -> [AirportRecord] {
        let data = try Data(contentsOf: url)
        return try load(from: data)
    }

    static func load(from data: Data) throws -> [AirportRecord] {
        guard data.count >= headerSize else {
            throw AirportBinaryReaderError.fileTooSmall(actualBytes: data.count)
        }

        let magicData = data[0..<8]
        let actualMagic = String(data: magicData, encoding: .ascii) ?? ""
        guard actualMagic == magic else {
            throw AirportBinaryReaderError.badMagic(expected: magic, actual: actualMagic)
        }

        let count = try readUInt32LittleEndian(data, at: 8)
        guard count <= maxReasonableAirportCount else {
            throw AirportBinaryReaderError.unreasonableAirportCount(count)
        }

        let expectedSize = headerSize + Int(count) * recordSize
        guard data.count == expectedSize else {
            throw AirportBinaryReaderError.badFileSize(expected: expectedSize, actual: data.count)
        }

        var airports: [AirportRecord] = []
        airports.reserveCapacity(Int(count))

        for index in 0..<Int(count) {
            let offset = headerSize + index * recordSize
            guard offset + recordSize <= data.count else {
                throw AirportBinaryReaderError.truncatedRecord(index: index)
            }
            let airport = try readRecord(data, at: offset, index: index)
            try validate(airport, index: index)
            airports.append(airport)
        }

        return airports
    }

    private static func readRecord(_ data: Data, at offset: Int, index: Int) throws -> AirportRecord {
        let identifierData = data[offset..<offset + 8]
        let nulIndex = identifierData.firstIndex(of: 0) ?? identifierData.endIndex
        let trimmedIdentifierData = identifierData[identifierData.startIndex..<nulIndex]
        guard let identifier = String(data: trimmedIdentifierData, encoding: .ascii),
              !identifier.isEmpty
        else { throw AirportBinaryReaderError.badIdentifier(index: index) }

        let latitudeDegrees  = try readDoubleLittleEndian(data, at: offset + 8)
        let longitudeDegrees = try readDoubleLittleEndian(data, at: offset + 16)
        let latitudeRadians  = try readDoubleLittleEndian(data, at: offset + 24)
        let longitudeRadians = try readDoubleLittleEndian(data, at: offset + 32)
        let unitX            = try readDoubleLittleEndian(data, at: offset + 40)
        let unitY            = try readDoubleLittleEndian(data, at: offset + 48)
        let unitZ            = try readDoubleLittleEndian(data, at: offset + 56)

        return AirportRecord(
            identifier: identifier,
            latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees,
            latitudeRadians: latitudeRadians, longitudeRadians: longitudeRadians,
            unitX: unitX, unitY: unitY, unitZ: unitZ
        )
    }

    private static func validate(_ airport: AirportRecord, index: Int) throws {
        for (field, value) in [
            ("latitudeDegrees",  airport.latitudeDegrees),
            ("longitudeDegrees", airport.longitudeDegrees),
            ("latitudeRadians",  airport.latitudeRadians),
            ("longitudeRadians", airport.longitudeRadians),
            ("unitX", airport.unitX), ("unitY", airport.unitY), ("unitZ", airport.unitZ),
        ] {
            guard value.isFinite else {
                throw AirportBinaryReaderError.invalidNumber(index: index, field: field, value: value)
            }
        }
        guard (-90.0...90.0).contains(airport.latitudeDegrees) else {
            throw AirportBinaryReaderError.outOfRange(index: index, field: "latitudeDegrees", value: airport.latitudeDegrees)
        }
        guard (-180.0...180.0).contains(airport.longitudeDegrees) else {
            throw AirportBinaryReaderError.outOfRange(index: index, field: "longitudeDegrees", value: airport.longitudeDegrees)
        }
        guard (-(Double.pi / 2.0)...(Double.pi / 2.0)).contains(airport.latitudeRadians) else {
            throw AirportBinaryReaderError.outOfRange(index: index, field: "latitudeRadians", value: airport.latitudeRadians)
        }
        guard (-Double.pi...Double.pi).contains(airport.longitudeRadians) else {
            throw AirportBinaryReaderError.outOfRange(index: index, field: "longitudeRadians", value: airport.longitudeRadians)
        }
        for (field, value) in [("unitX", airport.unitX), ("unitY", airport.unitY), ("unitZ", airport.unitZ)] {
            guard (-1.0...1.0).contains(value) else {
                throw AirportBinaryReaderError.outOfRange(index: index, field: field, value: value)
            }
        }
        let lengthSquared = airport.unitX * airport.unitX + airport.unitY * airport.unitY + airport.unitZ * airport.unitZ
        guard abs(lengthSquared - 1.0) <= unitVectorTolerance else {
            throw AirportBinaryReaderError.badUnitVector(index: index, lengthSquared: lengthSquared)
        }
    }

    private static func readUInt32LittleEndian(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw AirportBinaryReaderError.fileTooSmall(actualBytes: data.count)
        }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
    }

    private static func readDoubleLittleEndian(_ data: Data, at offset: Int) throws -> Double {
        guard offset + 8 <= data.count else {
            throw AirportBinaryReaderError.fileTooSmall(actualBytes: data.count)
        }
        let bitPattern: UInt64 = data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return UInt64(bytes[offset])
                | (UInt64(bytes[offset + 1]) << 8)
                | (UInt64(bytes[offset + 2]) << 16)
                | (UInt64(bytes[offset + 3]) << 24)
                | (UInt64(bytes[offset + 4]) << 32)
                | (UInt64(bytes[offset + 5]) << 40)
                | (UInt64(bytes[offset + 6]) << 48)
                | (UInt64(bytes[offset + 7]) << 56)
        }
        return Double(bitPattern: bitPattern)
    }
}

// MARK: - Nearest airport search

struct AirportSearchResult {
    let airport: AirportRecord
    let distanceKilometers: Double
}

func unitVector(latitudeDegrees: Double, longitudeDegrees: Double) -> (x: Double, y: Double, z: Double) {
    let latRad = latitudeDegrees * .pi / 180.0
    let lonRad = longitudeDegrees * .pi / 180.0
    let cosLat = cos(latRad)
    return (x: cosLat * cos(lonRad), y: cosLat * sin(lonRad), z: sin(latRad))
}

func nearestAirport(
    latitudeDegrees: Double,
    longitudeDegrees: Double,
    airports: [AirportRecord]
) -> AirportSearchResult? {
    let current = unitVector(latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees)
    var bestAirport: AirportRecord?
    var bestChordSquared = Double.infinity

    for airport in airports {
        var dot = current.x * airport.unitX + current.y * airport.unitY + current.z * airport.unitZ
        dot = min(1.0, max(-1.0, dot))
        let chordSquared = 2.0 - 2.0 * dot
        if chordSquared < bestChordSquared {
            bestChordSquared = chordSquared
            bestAirport = airport
        }
    }

    guard let bestAirport else { return nil }
    let distanceKilometers = sqrt(bestChordSquared) * 6371.0088
    return AirportSearchResult(airport: bestAirport, distanceKilometers: distanceKilometers)
}
