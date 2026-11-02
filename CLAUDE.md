# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Hobbs Time Extractor is a SwiftUI app (iOS 18+, macOS 15+) that parses Garmin G1000 and GDU 465/G3X avionics CSV logs and displays flight time events. It has no external dependencies — only Apple frameworks.

## Building and Running

Open `Hobbs Time Extractor.xcodeproj` in Xcode and use the standard build/run workflow (`Cmd+B` / `Cmd+R`). The project targets both iOS and macOS (universal app).

Run `./tests/run.sh` on a Mac with Swift installed for parser and flight-track regression tests. It compiles the production parser, flight analyzer, and synthetic fixtures into a temporary standalone executable without Xcode project changes or external dependencies.

## Architecture

Main source files in `Hobbs Time Extractor/`:

- **GarminExtractor.swift** — CSV parsing, duty/engine detection, and result assembly. Contains:
  - `GarminRow`: timestamp, optional coordinates, TAS/IAS/groundspeed, GPS/pressure/indicated altitude, recorded AGL, vertical speed, fuel flow, and RPM.
  - `GarminTimeReader`: streaming iterator with 4 KB reads. Discovers compact or descriptive headers, maps timestamp/GPS/telemetry columns independently, skips invalid timestamps, and yields one `GarminRow` per valid sample.
  - `GarminTimestampParser`: validates named local date, local time, and UTC-offset fields and converts them to UTC epoch seconds with Gregorian integer arithmetic.
  - `EngineSignal`: selects RPM when a recognized RPM column exists, otherwise fuel flow. The source stays fixed for the file; a missing RPM sample does not fall back to fuel flow.
  - `FlightTime`: result for one file. Holds six named event times (On/Off Duty, Time Out/In, Time Off/On) as both epoch seconds and formatted `"HH:mm"` UTC strings, plus a `"H.h"` Hobbs duration, first/last GPS coordinates, engine diagnostics, and a flight-detection note.
  - `GarminExtractor`: static entry point. `extract(from:)` streams duty/engine detection while collecting rows, then calls `FlightTrackAnalyzer.analyze(_:)` for flight boundaries.

- **FlightTrack.swift** — Foundation-only, offline flight analysis using timestamp, altitude, and motion; engine fields never influence its calculations. `FlightTrackAnalysis` exposes smoothed points, source/quality notes, all detected flight intervals, and the first interval's takeoff/final interval's landing. Missing boundaries are `0`.

- **AirportBinaryReader.swift** — loads `faa_airports.bin` from the app bundle and exposes `nearestAirport(latitudeDegrees:longitudeDegrees:airports:)` using unit-vector dot-product search. `AirportRecord` stores pre-computed unit vector components for O(n) nearest-neighbor lookup.

- **ContentView.swift** — SwiftUI view. `FlightRecord` wraps `FlightTime` with nearest departure/arrival `AirportRecord` and distances in km. The list shows all six event times, a route label (`KEYE 0.5km → KGYY 0.7km`), and Hobbs duration. When engine or flight events aren't detected, an orange debug row shows diagnostic values.

- **Hobbs_Time_ExtractorApp.swift** — `@main` entry, single `WindowGroup`.

## Garmin CSV Format

Headers are detected by column names rather than fixed line numbers or byte positions. The original G1000 layout remains supported:
```
#airframe_info,...
#yyy-mm-dd, hh:mm:ss,   hh:mm,...
  Lcl Date, Lcl Time, UTCOfst,...
2025-03-17, 09:59:11,  -05:00,...
```

GDU 465/G3X logs may have a descriptive header followed by a compact header, with an extra `UTC Time` column before `UTCOfst`. Either header works; the last recognized header before the first data sample is used. Required fields are local date, local time, and UTC offset, recognized as `Lcl Date` / `Date (yyyy-mm-dd)`, `Lcl Time` / `Time (hh:mm:ss)`, and `UTCOfst` / `UTC Offset (hh:mm)`. `UTC Time` is not the offset. Column matching ignores case and whitespace, and accepts reordered columns.

GPS and telemetry are optional and independent. Recognized fields include `Latitude` / `Latitude (deg)`, `Longitude` / `Longitude (deg)`, `GPSfix` / `GPS Fix Status`, `TAS` / `True Airspeed (kt)`, `E1 FFlow` (and other engine numbers) / `Fuel Flow (gal/hour)`, and `E1 RPM` (and other engine numbers) / `RPM`. Descriptive aliases include units; supported compact Garmin headers use knots for TAS and gallons/hour for FFlow. Other unit systems are not supported.

Additional flight fields are `GndSpd` / `GPS Ground Speed (kt)`, `IAS` / `Indicated Airspeed (kt)`, `AltMSL` (preferred) or `AltGPS` / `GPS Altitude (ft)`, `AltP` / `Pressure Altitude (ft)`, `AltInd` / `Baro Altitude (ft)`, `AGL` / `Height Above Ground (ft)`, and `VSpd` / `Vertical Speed (ft/min)`. Altitudes are feet, speeds are knots, and vertical speed is signed feet/minute.

Coordinates must be finite and in range. When present, `GPSfix` must be `3D` or `3DDiff`, and each `HPLwas` / `VPLwas` value must be in `[0, 100)`. Missing GPS-quality columns are allowed. GPS altitude and groundspeed require a valid fix, but do not use the stricter HPL/VPL limits applied to route coordinates; a protection-level change must not erase otherwise usable flight motion. Invalid GPS does not suppress timestamps or unrelated telemetry. The reader accepts metadata comments, blank lines, UTF-8 BOM, CRLF, single-line quoted CSV fields, and a final line without a newline. Invalid UTF-8 bytes are replaced so corruption in an unrelated field does not discard a valid timestamp.

## Detection Logic

- **Engine On** (`Time Out`): first row where the maximum recognized RPM exceeds 300; if no RPM column exists, the maximum recognized fuel flow must exceed 5 gph
- **Engine Off** (`Time In`): last valid sample at or below the selected engine threshold after engine-on (existing last-low-sample behavior)
- **Takeoff** (`Time Off`): departure of the first detected flight interval, using sustained altitude/motion evidence and refining the event against ground elevation and smoothed vertical rate
- **Landing** (`Time On`): arrival of the final detected flight interval, using sustained near-ground/slow-motion evidence; low airspeed aloft alone cannot count as a landing
- **On/Off Duty**: first and last row with a valid epoch (> 365 days since Unix epoch)
- **Hobbs**: `(offDuty − onDuty) / 3600`, rounded to one decimal hour; this remains the recording span, not an accumulated engine-running duration

Engine detection retains its end-of-file fallback when a start has no observed stop. Flight detection never fabricates a takeoff at the start of a log or a landing at EOF: a log starting airborne has no first takeoff, and an unfinished final flight has no final landing even if an earlier flight landed.

Flight analysis skips duplicate/backward timestamps and splits at timestamp gaps over 15 seconds. In altitude mode, recovery after more than 15 seconds with neither the selected absolute-altitude source nor recorded AGL also starts a new segment. A touchdown hidden in a sensor outage remains unobserved instead of using taxi recovery as the landing time. A centered five-second median followed by a centered five-second mean smooths altitude, AGL, and motion; windows use elapsed seconds and never cross segments. A single absolute-altitude source is chosen for the file, preferring sufficiently populated GPS, then pressure, then indicated altitude.

Sustained slow motion with stable altitude establishes taxi-elevation references. Interpolating these references accommodates different departure and arrival elevations. `estimatedAGLFeet` is height relative to those references, not modeled terrain clearance; recorded AGL stays separate. At least eight seconds of raw absolute-altitude or recorded-AGL availability enables altitude-based detection. Airborne evidence requires eight seconds of motion plus recorded AGL or estimated relative height; ground evidence requires a 12-second dwell. AGL-only logs can establish ground without absolute altitude. If sustained altitude data is unavailable, an explicitly noted fallback uses smoothed speed above 60 kt for takeoff and below 40 kt for landing with the same dwell requirements; an isolated altitude sample does not disable it.

## Flight Diagnostics

Diagnostic charts remain outside the app. [tools/debug-flight.sh](tools/debug-flight.sh) exports the production analyzer's JSON, and [tools/plot-flight.py](tools/plot-flight.py) renders altitude/height/speed PNG charts with first takeoff and final landing markers. These tools exclude engine readings. See [tools/README.md](tools/README.md) for commands and output details; generated diagnostics default to the Git-ignored `debug/flights/` directory.

## Airport Database

`faa_airports.bin` (inside `Hobbs Time Extractor/`) is a compact binary built from FAA data. Format: 8-byte ASCII magic `FAAPT001`, 4-byte little-endian record count, then 64-byte records (8-byte null-padded ICAO identifier + 7 IEEE 754 doubles: lat°, lon°, lat rad, lon rad, unit x/y/z). The `tools/` directory contains `faa_airports.py`, which downloads directly from the FAA NASR subscription and writes the binary — no local source file required.

## Sandbox Entitlements

The app is sandboxed with read-only access to user-selected files (`com.apple.security.files.user-selected.read-only`). `GarminTimeReader` calls `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` around all file I/O — any new file reading code must do the same. `AirportBinaryReader` reads from the app bundle (no security scope needed).
