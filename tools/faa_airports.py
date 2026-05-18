#!/usr/bin/env -S uv run --script
# /// script
# dependencies = [
#   "requests",
#   "beautifulsoup4",
# ]
# ///

from __future__ import annotations

import argparse
import csv
import io
import math
import struct
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import TextIO
from urllib.parse import urljoin

import requests
from bs4 import BeautifulSoup

BASE_URL = (
    "https://www.faa.gov/air_traffic/flight_info/aeronav/aero_data/NASR_Subscription/"
)
DEFAULT_BINARY_FILE = Path(__file__).parent / "output" / "faa_airports.bin"

BINARY_MAGIC = b"FAAPT001"
BINARY_HEADER_STRUCT = struct.Struct("<8sI")
BINARY_RECORD_STRUCT = struct.Struct("<8s7d")

REQUIRED_COLUMNS = [
    "ARPT_ID",
    "ICAO_ID",
    "LAT_DECIMAL",
    "LONG_DECIMAL",
    "SITE_TYPE_CODE",
]

MAX_REASONABLE_AIRPORTS = 100_000
UNIT_VECTOR_TOLERANCE = 1.0e-12
EARTH_RADIUS_NM = 3440.065
VERBOSE = False


def log(message: str = "") -> None:
    if VERBOSE:
        print(message, file=sys.stderr)


@dataclass(frozen=True, slots=True)
class AirportRecord:
    identifier: str
    latitude_degrees: float
    longitude_degrees: float
    latitude_radians: float
    longitude_radians: float
    unit_x: float
    unit_y: float
    unit_z: float

    @classmethod
    def from_lat_lon(
        cls, identifier: str, latitude_degrees: float, longitude_degrees: float
    ) -> AirportRecord:
        latitude_radians = math.radians(latitude_degrees)
        longitude_radians = math.radians(longitude_degrees)
        cos_latitude = math.cos(latitude_radians)

        airport = cls(
            identifier=identifier,
            latitude_degrees=latitude_degrees,
            longitude_degrees=longitude_degrees,
            latitude_radians=latitude_radians,
            longitude_radians=longitude_radians,
            unit_x=cos_latitude * math.cos(longitude_radians),
            unit_y=cos_latitude * math.sin(longitude_radians),
            unit_z=math.sin(latitude_radians),
        )

        airport.validate()
        return airport

    def distance_nm_to(
        self, latitude_degrees: float, longitude_degrees: float
    ) -> float:
        latitude_radians = math.radians(latitude_degrees)
        longitude_radians = math.radians(longitude_degrees)

        delta_latitude = latitude_radians - self.latitude_radians
        delta_longitude = longitude_radians - self.longitude_radians

        a = (
            math.sin(delta_latitude / 2.0) ** 2
            + math.cos(self.latitude_radians)
            * math.cos(latitude_radians)
            * math.sin(delta_longitude / 2.0) ** 2
        )

        c = 2.0 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))
        return EARTH_RADIUS_NM * c

    def to_text_line(self) -> str:
        return (
            f"{self.identifier} "
            f"{self.latitude_degrees:.10f} "
            f"{self.longitude_degrees:.10f} "
            f"{self.latitude_radians:.17g} "
            f"{self.longitude_radians:.17g} "
            f"{self.unit_x:.17g} "
            f"{self.unit_y:.17g} "
            f"{self.unit_z:.17g}"
        )

    def validate(self, index: int | None = None) -> None:
        prefix = "Airport record" if index is None else f"Airport record {index}"

        if not self.identifier:
            raise RuntimeError(f"{prefix}: empty identifier")

        if len(self.identifier.encode("ascii", errors="ignore")) != len(
            self.identifier
        ):
            raise RuntimeError(
                f"{prefix}: identifier is not ASCII: {self.identifier!r}"
            )

        if len(self.identifier.encode("ascii")) > 8:
            raise RuntimeError(f"{prefix}: identifier too long: {self.identifier!r}")

        if not -90.0 <= self.latitude_degrees <= 90.0:
            raise RuntimeError(
                f"{prefix}: latitude out of range: {self.latitude_degrees}"
            )

        if not -180.0 <= self.longitude_degrees <= 180.0:
            raise RuntimeError(
                f"{prefix}: longitude out of range: {self.longitude_degrees}"
            )

        for name, value in [
            ("latitude_degrees", self.latitude_degrees),
            ("longitude_degrees", self.longitude_degrees),
            ("latitude_radians", self.latitude_radians),
            ("longitude_radians", self.longitude_radians),
            ("unit_x", self.unit_x),
            ("unit_y", self.unit_y),
            ("unit_z", self.unit_z),
        ]:
            if not math.isfinite(value):
                raise RuntimeError(f"{prefix}: {name} is not finite: {value}")

        vector_length_squared = (
            self.unit_x * self.unit_x
            + self.unit_y * self.unit_y
            + self.unit_z * self.unit_z
        )

        if abs(vector_length_squared - 1.0) > UNIT_VECTOR_TOLERANCE:
            raise RuntimeError(
                f"{prefix}: unit vector length mismatch: {vector_length_squared}"
            )


@dataclass(frozen=True, slots=True)
class AirportDatabase:
    airports: tuple[AirportRecord, ...]

    @classmethod
    def from_download(cls) -> AirportDatabase:
        subscription_url = get_current_subscription_url()
        log(f"Subscription URL: {subscription_url}")

        apt_csv_url = get_apt_csv_url(subscription_url)
        log(f"APT CSV URL: {apt_csv_url}")

        airports = download_airports(apt_csv_url)
        database = cls(tuple(airports))
        database.verify()
        return database

    @classmethod
    def from_binary_file(cls, path: Path) -> AirportDatabase:
        return cls.from_binary_bytes(path.read_bytes())

    @classmethod
    def from_binary_bytes(cls, data: bytes, validate: bool = True) -> AirportDatabase:
        if len(data) < BINARY_HEADER_STRUCT.size:
            raise RuntimeError(f"Binary data too small: {len(data)} bytes")

        magic, count = BINARY_HEADER_STRUCT.unpack_from(data, 0)

        if magic != BINARY_MAGIC:
            raise RuntimeError(
                f"Bad binary magic: expected {BINARY_MAGIC!r}, got {magic!r}"
            )

        expected_size = BINARY_HEADER_STRUCT.size + count * BINARY_RECORD_STRUCT.size

        if len(data) != expected_size:
            raise RuntimeError(
                f"Binary size mismatch: expected {expected_size}, got {len(data)}"
            )

        airports: list[AirportRecord] = []
        offset = BINARY_HEADER_STRUCT.size

        for index in range(count):
            (
                identifier_bytes,
                lat_deg,
                lon_deg,
                lat_rad,
                lon_rad,
                unit_x,
                unit_y,
                unit_z,
            ) = BINARY_RECORD_STRUCT.unpack_from(data, offset)

            airport = AirportRecord(
                identifier=decode_identifier(identifier_bytes),
                latitude_degrees=lat_deg,
                longitude_degrees=lon_deg,
                latitude_radians=lat_rad,
                longitude_radians=lon_rad,
                unit_x=unit_x,
                unit_y=unit_y,
                unit_z=unit_z,
            )

            if validate:
                airport.validate(index)

            airports.append(airport)
            offset += BINARY_RECORD_STRUCT.size

        database = cls(tuple(airports))

        if validate:
            database.verify()

        return database

    def to_binary_bytes(self) -> bytes:
        self.verify()

        output = io.BytesIO()
        output.write(BINARY_HEADER_STRUCT.pack(BINARY_MAGIC, len(self.airports)))

        for airport in self.airports:
            output.write(
                BINARY_RECORD_STRUCT.pack(
                    encode_identifier(airport.identifier),
                    airport.latitude_degrees,
                    airport.longitude_degrees,
                    airport.latitude_radians,
                    airport.longitude_radians,
                    airport.unit_x,
                    airport.unit_y,
                    airport.unit_z,
                )
            )

        return output.getvalue()

    def write_binary_file(self, path: Path) -> None:
        path.write_bytes(self.to_binary_bytes())

    def write_text(self, file: TextIO) -> None:
        file.write("IDENT LAT_DEG LON_DEG LAT_RAD LON_RAD UNIT_X UNIT_Y UNIT_Z\n")

        for airport in self.airports:
            file.write(airport.to_text_line())
            file.write("\n")

    def nearest_airport(
        self, latitude_degrees: float, longitude_degrees: float
    ) -> tuple[AirportRecord, float]:
        best_airport: AirportRecord | None = None
        best_distance = math.inf

        for airport in self.airports:
            distance = airport.distance_nm_to(latitude_degrees, longitude_degrees)

            if distance < best_distance:
                best_airport = airport
                best_distance = distance

        if best_airport is None:
            raise RuntimeError("Airport database is empty")

        return best_airport, best_distance

    def verify(self) -> None:
        if not self.airports:
            raise RuntimeError("Airport database is empty")

        if len(self.airports) > MAX_REASONABLE_AIRPORTS:
            raise RuntimeError(
                f"Airport database is suspiciously large: {len(self.airports)}"
            )

        seen: set[str] = set()

        for index, airport in enumerate(self.airports):
            airport.validate(index)

            if airport.identifier in seen:
                raise RuntimeError(
                    f"Duplicate airport identifier: {airport.identifier}"
                )

            seen.add(airport.identifier)

    def verify_binary_round_trip(self) -> None:
        parsed = AirportDatabase.from_binary_bytes(self.to_binary_bytes())

        if parsed != self:
            raise RuntimeError("Binary round-trip verification failed")


def clean_cell(value: str | None) -> str:
    return "" if value is None else value.strip()


def normalize_header(value: str) -> str:
    return clean_cell(value).replace("\ufeff", "")


def encode_identifier(identifier: str) -> bytes:
    encoded = identifier.encode("ascii")

    if len(encoded) > 8:
        raise ValueError(
            f"Airport identifier too long for binary format: {identifier!r}"
        )

    return encoded.ljust(8, b"\0")


def decode_identifier(identifier_bytes: bytes) -> str:
    identifier = identifier_bytes.split(b"\0", 1)[0].decode("ascii")

    if not identifier:
        raise RuntimeError("Empty identifier in binary airport record")

    return identifier


def get_current_subscription_url() -> str:
    response = requests.get(BASE_URL, timeout=30)
    response.raise_for_status()

    soup = BeautifulSoup(response.text, "html.parser")
    current = soup.find(string=lambda text: text is not None and "Current" in text)

    if current is None:
        raise RuntimeError("Could not find Current section")

    link = current.find_next("a")

    if link is None:
        raise RuntimeError("Could not find subscription link after Current section")

    href = link.get("href")

    if not href:
        raise RuntimeError("Current subscription link has no href")

    return urljoin(BASE_URL, href)


def get_apt_csv_url(subscription_url: str) -> str:
    response = requests.get(subscription_url, timeout=30)
    response.raise_for_status()

    soup = BeautifulSoup(response.text, "html.parser")

    for link in soup.find_all("a", href=True):
        if "Airports and Other Landing Facilities" in link.get_text(strip=True):
            return urljoin(subscription_url, link["href"])

    raise RuntimeError(
        "Could not find Airports and Other Landing Facilities CSV ZIP URL"
    )


def find_apt_base_csv_name(zip_file: zipfile.ZipFile) -> str:
    for name in zip_file.namelist():
        if name.upper().endswith("APT_BASE.CSV"):
            return name

    raise RuntimeError(f"APT_BASE.csv not found. ZIP contains: {zip_file.namelist()}")


def make_csv_reader(csv_bytes: bytes) -> csv.DictReader[str]:
    text_file = io.TextIOWrapper(
        io.BytesIO(csv_bytes), encoding="utf-8-sig", newline=""
    )

    reader = csv.DictReader(
        text_file,
        delimiter=",",
        quotechar='"',
        doublequote=True,
        skipinitialspace=False,
    )

    if reader.fieldnames is None:
        raise RuntimeError("APT_BASE.csv has no header row")

    reader.fieldnames = [normalize_header(fieldname) for fieldname in reader.fieldnames]

    return reader


def require_columns(fieldnames: list[str], required_columns: list[str]) -> None:
    missing = [column for column in required_columns if column not in fieldnames]

    if missing:
        raise RuntimeError(
            f"Missing required CSV columns: {missing}. Available columns: {fieldnames}"
        )


def parse_float_cell(row: dict[str, str], column_name: str, row_number: int) -> float:
    value = clean_cell(row.get(column_name))

    if not value:
        raise ValueError(f"Missing {column_name} on CSV row {row_number}")

    return float(value)


def get_airport_identifier(row: dict[str, str]) -> str:
    icao_id = clean_cell(row.get("ICAO_ID"))

    if icao_id:
        return icao_id

    return clean_cell(row.get("ARPT_ID"))


def parse_airport_row(row: dict[str, str], row_number: int) -> AirportRecord | None:
    site_type_code = clean_cell(row.get("SITE_TYPE_CODE")).upper()

    if site_type_code != "A":
        return None

    airport_id = get_airport_identifier(row)

    if not airport_id:
        return None

    latitude = parse_float_cell(row, "LAT_DECIMAL", row_number)
    longitude = parse_float_cell(row, "LONG_DECIMAL", row_number)

    return AirportRecord.from_lat_lon(
        identifier=airport_id,
        latitude_degrees=latitude,
        longitude_degrees=longitude,
    )


def parse_airports_from_csv_bytes(csv_bytes: bytes) -> list[AirportRecord]:
    reader = make_csv_reader(csv_bytes)

    if reader.fieldnames is None:
        raise RuntimeError("APT_BASE.csv has no header row")

    require_columns(reader.fieldnames, REQUIRED_COLUMNS)

    airports: list[AirportRecord] = []
    skipped_not_airport = 0
    skipped_missing = 0
    skipped_bad_number = 0
    skipped_malformed = 0
    used_icao_id = 0
    used_arpt_id = 0

    for row_number, row in enumerate(reader, start=2):
        if None in row:
            skipped_malformed += 1
            continue

        clean_row = {
            normalize_header(key): clean_cell(value)
            for key, value in row.items()
            if key is not None
        }

        try:
            airport = parse_airport_row(clean_row, row_number)

            if airport is None:
                if clean_cell(clean_row.get("SITE_TYPE_CODE")).upper() != "A":
                    skipped_not_airport += 1
                else:
                    skipped_missing += 1
                continue

            if clean_cell(clean_row.get("ICAO_ID")):
                used_icao_id += 1
            else:
                used_arpt_id += 1

            airports.append(airport)

        except ValueError:
            skipped_bad_number += 1
            continue

    log(f"Parsed airports: {len(airports)}")
    log(f"Used ICAO_ID: {used_icao_id}")
    log(f"Used ARPT_ID fallback: {used_arpt_id}")
    log(f"Skipped non-airport site types: {skipped_not_airport}")
    log(f"Skipped rows with missing airport id: {skipped_missing}")
    log(f"Skipped rows with bad numbers: {skipped_bad_number}")
    log(f"Skipped malformed CSV rows: {skipped_malformed}")

    return sorted(
        airports,
        key=lambda airport: (
            airport.latitude_degrees,
            airport.longitude_degrees,
            airport.identifier,
        ),
    )


def download_airports(csv_zip_url: str) -> list[AirportRecord]:
    response = requests.get(csv_zip_url, timeout=60)
    response.raise_for_status()

    zip_file = zipfile.ZipFile(io.BytesIO(response.content))
    apt_base_csv_name = find_apt_base_csv_name(zip_file)

    with zip_file.open(apt_base_csv_name) as file:
        csv_bytes = file.read()

    log(f"Reading: {apt_base_csv_name}")

    return parse_airports_from_csv_bytes(csv_bytes)


def parse_lat_lon(value: str) -> tuple[float, float]:
    try:
        lat_text, lon_text = value.split(",", 1)
        return float(lat_text), float(lon_text)
    except ValueError as error:
        raise argparse.ArgumentTypeError(
            f"Expected lat,lon but got {value!r}"
        ) from error


def print_summary(database: AirportDatabase, path: Path | None = None) -> None:
    if path is not None:
        log(f"Binary airport file: {path}")
        log(f"Binary size: {path.stat().st_size:,} bytes")

    log(f"Airports: {len(database.airports)}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download FAA AIRPORT-only data and query nearest airports."
    )

    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Print progress to stderr."
    )

    subparsers = parser.add_subparsers(dest="command")

    download_parser = subparsers.add_parser(
        "download", help="Download current FAA AIRPORT-only data."
    )
    download_parser.add_argument(
        "-o", "--output", type=Path, default=DEFAULT_BINARY_FILE
    )

    dump_parser = subparsers.add_parser(
        "dump", help="Dump binary airport file to stdout."
    )
    dump_parser.add_argument("input", nargs="?", type=Path, default=DEFAULT_BINARY_FILE)

    verify_parser = subparsers.add_parser("verify", help="Verify binary airport file.")
    verify_parser.add_argument(
        "input", nargs="?", type=Path, default=DEFAULT_BINARY_FILE
    )

    nearest_parser = subparsers.add_parser(
        "nearest", help="Find nearest AIRPORT for lat,lon pair(s)."
    )
    nearest_parser.add_argument("-d", "--db", type=Path, default=DEFAULT_BINARY_FILE)
    nearest_parser.add_argument("pairs", nargs="+", type=parse_lat_lon)

    args = parser.parse_args()

    if args.command is None:
        args.command = "download"
        args.output = DEFAULT_BINARY_FILE

    return args


def run_download(output_path: Path) -> None:
    log("Finding current NASR subscription...")
    log("Finding APT CSV ZIP...")
    log("Downloading and parsing AIRPORT-only rows...")

    database = AirportDatabase.from_download()
    database.verify_binary_round_trip()

    log(f"Writing {output_path}...")
    database.write_binary_file(output_path)

    import hashlib
    checksum = hashlib.sha256(output_path.read_bytes()).hexdigest()
    checksum_path = output_path.with_suffix(".sha256")
    checksum_path.write_text(checksum + "\n", encoding="utf-8")
    log(f"SHA-256: {checksum}")
    log(f"Checksum written to {checksum_path}")

    print_summary(database, output_path)


def run_dump(input_path: Path) -> None:
    database = AirportDatabase.from_binary_file(input_path)
    database.write_text(sys.stdout)


def run_verify(input_path: Path) -> None:
    database = AirportDatabase.from_binary_file(input_path)
    database.verify()
    database.verify_binary_round_trip()
    print_summary(database, input_path)


def run_nearest(db_path: Path, pairs: list[tuple[float, float]]) -> None:
    database = AirportDatabase.from_binary_file(db_path)

    for latitude, longitude in pairs:
        airport, distance_nm = database.nearest_airport(latitude, longitude)
        print(
            f"{latitude:.10f},{longitude:.10f} "
            f"{airport.identifier} "
            f"{distance_nm:.2f}nm "
            f"{airport.latitude_degrees:.10f},{airport.longitude_degrees:.10f}"
        )


def main() -> None:
    global VERBOSE

    args = parse_args()
    VERBOSE = args.verbose

    if args.command == "download":
        run_download(args.output)
    elif args.command == "dump":
        run_dump(args.input)
    elif args.command == "verify":
        run_verify(args.input)
    elif args.command == "nearest":
        run_nearest(args.db, args.pairs)
    else:
        raise RuntimeError(f"Unknown command: {args.command}")


if __name__ == "__main__":
    main()
