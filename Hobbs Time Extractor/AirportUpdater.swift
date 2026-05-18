//
//  AirportUpdater.swift
//  Hobbs Time Extractor
//

import Foundation
import CryptoKit

enum AirportUpdater {
    // Raw GitHub URL for faa_airports.bin — update this when you move the file.
    private static let remoteURL = URL(string: "https://raw.githubusercontent.com/JonathanAnderson/Hobbs-Time-Extractor/main/Hobbs%20Time%20Extractor/faa_airports.bin")!

    private static let lastModifiedKey = "faa_airports_last_modified"

    private static var cachedURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("faa_airports.bin")
    }

    /// Loads airports from the cached download if present and valid, otherwise falls back to the bundle.
    static func load() -> [AirportRecord] {
        if FileManager.default.fileExists(atPath: cachedURL.path),
           let airports = try? AirportBinaryReader.load(from: cachedURL) {
            return airports
        }
        return (try? AirportBinaryReader.loadFromBundle()) ?? []
    }

    /// Checks GitHub for a newer binary using If-Modified-Since.
    /// Downloads, verifies checksum, validates binary format, then saves.
    /// Returns true if a new file was downloaded and saved.
    @discardableResult
    static func checkForUpdate() async -> Bool {
        var request = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if let lastModified = UserDefaults.standard.string(forKey: lastModifiedKey) {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200
        else { return false }

        // Fetch and verify SHA-256 checksum
        let checksumURL = remoteURL.deletingPathExtension().appendingPathExtension("sha256")
        guard let (checksumData, _) = try? await URLSession.shared.data(from: checksumURL),
              let expectedHex = String(data: checksumData, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }

        let computed = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        guard computed == expectedHex else { return false }

        // Validate binary format before replacing cached copy
        guard (try? AirportBinaryReader.load(from: data)) != nil else { return false }

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? data.write(to: cachedURL)) != nil else { return false }

        if let lm = http.value(forHTTPHeaderField: "Last-Modified") {
            UserDefaults.standard.set(lm, forKey: lastModifiedKey)
        }
        return true
    }
}
