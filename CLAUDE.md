# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Hobbs Time Extractor is a SwiftUI app (iOS 18+, macOS 15+) that parses Garmin G1000 avionics CSV export files and displays flight time events. It has no external dependencies — only Apple frameworks.

## Building and Running

Open `Hobbs Time Extractor.xcodeproj` in Xcode. There are no command-line build scripts; use Xcode's standard build/run workflow (`Cmd+B` / `Cmd+R`). The project targets both iOS and macOS (universal app).

There are no automated tests.

## Architecture

Four source files in `Hobbs Time Extractor/`:

- **GarminExtractor.swift** — all parsing and detection logic. Contains:
  - `GarminRow`: one parsed data row (`epochSec`, `latitude?`, `longitude?`, `tas?`, `maxFFlow?`).
  - `GarminTimeReader`: streaming iterator over a Garmin G1000 CSV. Reads in 4 KB chunks, validates three magic-header lines, discovers column indices dynamically, and yields one `GarminRow` per data row.
  - `GarminTimestampParser`: zero-allocation parser that converts columns 0–2 (local date, local time, UTC offset) to a UTC epoch second using integer arithmetic only.
  - `FlightTime`: immutable result for one file. Holds six named event times (On/Off Duty, Time Out/In, Time Off/On) as both epoch seconds and formatted `"HH:mm"` UTC strings, plus a `"H.h"` Hobbs duration and first/last GPS coordinates.
  - `GarminExtractor`: static entry point. `extract(from:)` drives the reader and runs three detectors in one pass: duty (first/last valid epoch), engine (FFlow > 5 gph threshold), and flight (TAS > 60 kt / < 40 kt hysteresis).

- **AirportBinaryReader.swift** — loads `faa_airports.bin` from the app bundle and exposes `nearestAirport(latitudeDegrees:longitudeDegrees:airports:)` using unit-vector dot-product search. `AirportRecord` stores pre-computed unit vector components for O(n) nearest-neighbor lookup.

- **ContentView.swift** — SwiftUI view. `FlightRecord` wraps `FlightTime` with nearest departure/arrival `AirportRecord` and distances in km. The list shows all six event times, a route label (`KEYE 0.5km → KGYY 0.7km`), and Hobbs duration. When engine or flight events aren't detected, an orange debug row shows diagnostic values.

- **Hobbs_Time_ExtractorApp.swift** — `@main` entry, single `WindowGroup`.

## Garmin CSV Format

Expected file structure (first three lines are magic headers validated byte-for-byte):
```
#airframe_info,...
#yyy-mm-dd, hh:mm:ss,   hh:mm,...
  Lcl Date, Lcl Time, UTCOfst,...
2025-03-17, 09:59:11,  -05:00,...
```

Column indices are discovered dynamically from the header row (line 3). Required: `Latitude`, `Longitude`, `GPSfix`, `HPLwas`, `VPLwas`. Optional: `TAS`, all `*FFlow*` columns. GPS fixes are filtered to `GPSfix == "3DDiff"` with `HPLwas < 100` and `VPLwas < 100`.

## Detection Logic

- **Engine On** (`Time Out`): first row where `max(all FFlow columns) > 5 gph`
- **Engine Off** (`Time In`): last row where `max(all FFlow columns) ≤ 5 gph` after engine-on
- **Takeoff** (`Time Off`): first row where `TAS > 60 kt`
- **Landing** (`Time On`): first row where `TAS < 40 kt` after takeoff
- **On/Off Duty**: first and last row with a valid epoch (> 365 days since Unix epoch)

## Airport Database

`faa_airports.bin` (inside `Hobbs Time Extractor/`) is a compact binary built from FAA data. Format: 8-byte ASCII magic `FAAPT001`, 4-byte little-endian record count, then 64-byte records (8-byte null-padded ICAO identifier + 7 IEEE 754 doubles: lat°, lon°, lat rad, lon rad, unit x/y/z). The `tools/` directory contains `faa_airports.py`, which downloads directly from the FAA NASR subscription and writes the binary — no local source file required.

## Sandbox Entitlements

The app is sandboxed with read-only access to user-selected files (`com.apple.security.files.user-selected.read-only`). `GarminTimeReader` calls `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` around all file I/O — any new file reading code must do the same. `AirportBinaryReader` reads from the app bundle (no security scope needed).
