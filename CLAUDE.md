# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Hobbs Time Extractor is a SwiftUI app (iOS 18+, macOS 15+) that parses Garmin G1000 avionics CSV export files to calculate and display flight durations. It has no external dependencies — only Apple frameworks.

## Building and Running

Open `Hobbs Time Extractor.xcodeproj` in Xcode. There are no command-line build scripts; use Xcode's standard build/run workflow (`Cmd+B` / `Cmd+R`). The project targets both iOS and macOS (universal app).

There are no automated tests.

## Architecture

Three source files in `Hobbs Time Extractor/`:

- **GarminExtractor.swift** — all parsing logic. Contains:
  - `GarminTimeReader`: streaming file reader implementing `Sequence`/`IteratorProtocol`. Reads in 4 KB chunks, validates three magic-header lines, and yields Unix epoch integers per data row.
  - `FlightTime`: immutable result struct (`fileName`, `start`, `end`, `dt`).
  - `GarminExtractor`: static entry point — `extract(from:)` drives the reader, finds first/last valid epoch, and returns a `FlightTime`.

- **ContentView.swift** — SwiftUI view. Uses `fileImporter` to pick multiple CSVs, calls `GarminExtractor.extract` on each, and displays results in a `List`.

- **Hobbs_Time_ExtractorApp.swift** — `@main` entry, single `WindowGroup`.

## Garmin CSV Format

Expected file structure (first three lines are magic headers validated byte-for-byte):
```
#airframe_info,...
#yyy-mm-dd, hh:mm:ss,   hh:mm,...
  Lcl Date, Lcl Time, UTCOfst,...
2025-03-17, 09:59:11,  -05:00,...
```

The parser reads columns 0–2 (local date, local time, UTC offset) from each data row, converts to UTC epoch seconds, and ignores rows with epochs under 365 days (invalid/zero entries).

## Sandbox Entitlements

The app is sandboxed with read-only access to user-selected files (`com.apple.security.files.user-selected.read-only`) and the Downloads folder. `GarminTimeReader` calls `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` around all file I/O — any new file reading code must do the same.
