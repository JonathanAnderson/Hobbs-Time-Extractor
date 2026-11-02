# tools/

Developer tools for app bundle assets and flight-log diagnostics.

## Flight-motion diagnostics

Generate diagnostic files outside the app to inspect the flight detector. The exporter
runs the same Swift parser and flight analysis as the app; charts contain no engine
readings and are not part of the app UI.

From the repository root, export one or more logs:

```sh
tools/debug-flight.sh /path/to/log.csv /path/to/another-log.csv
```

This requires the macOS Swift command-line tools. It writes one `.flight.json` file
per log to `debug/flights/`, which Git ignores. Use `-o /path/to/output` to choose a
different directory. The JSON contains raw timestamped airspeed, groundspeed,
altitude, recorded AGL, and vertical-speed readings; smoothed altitude and estimated
AGL; recording segment identifiers; and detected flight boundaries. Missing values
remain absent rather than being replaced with zero. No raw logs are copied.

Render shareable PNG charts with [uv](https://github.com/astral-sh/uv):

```sh
uv run tools/plot-flight.py debug/flights/*.flight.json
```

Matplotlib is declared in the script and installed automatically by `uv`. Each PNG
is saved beside its input JSON, or in a directory supplied with `-o`. The three
panels show altitude, recorded versus estimated AGL, and speed in UTC. Green and red
lines mark the first takeoff and final landing; dotted lines show other detected
flight boundaries. Lines break at missing measurements and recording gaps.

Estimated height is relative to taxi elevations; terrain is not modeled. It is kept
separate from recorded AGL and is not a terrain-clearance measurement.
The chart includes the analyzer's notes so uncertain detections remain visible.

## faa_airports.py

Downloads the current FAA NASR airport dataset directly from faa.gov, parses it, and writes `faa_airports.bin`. No local data file needed.

Requires [uv](https://github.com/astral-sh/uv). Dependencies (`requests`, `beautifulsoup4`) are declared inline and installed automatically.

**To regenerate `faa_airports.bin`:**

```sh
cd tools
uv run faa_airports.py -v -o faa_airports.bin
cp faa_airports.bin ../Hobbs\ Time\ Extractor/faa_airports.bin
```

Then rebuild the app in Xcode.

**Other commands:**

```sh
uv run faa_airports.py verify faa_airports.bin   # validate an existing binary
uv run faa_airports.py dump   faa_airports.bin   # print all records as text
```

## Binary format (`FAAPT001`)

| Offset | Size | Field |
|--------|------|-------|
| 0 | 8 | ASCII magic: `FAAPT001` |
| 8 | 4 | Record count (uint32 LE) |
| 12 | 64×N | Records |

Each 64-byte record:

| Offset | Size | Field |
|--------|------|-------|
| 0 | 8 | ICAO identifier (ASCII, null-padded) |
| 8 | 8 | Latitude (degrees, float64 LE) |
| 16 | 8 | Longitude (degrees, float64 LE) |
| 24 | 8 | Latitude (radians, float64 LE) |
| 32 | 8 | Longitude (radians, float64 LE) |
| 40 | 8 | Unit vector X (float64 LE) |
| 48 | 8 | Unit vector Y (float64 LE) |
| 56 | 8 | Unit vector Z (float64 LE) |
