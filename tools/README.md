# tools/

Python scripts for generating app bundle assets. Run offline; output is checked into the app target.

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
