#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/hobbs-flight-debug.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

swiftc -swift-version 6 -O \
    "$repo_dir/Hobbs Time Extractor/GarminExtractor.swift" \
    "$repo_dir/Hobbs Time Extractor/FlightTrack.swift" \
    "$repo_dir/tools/debug-flight.swift" \
    -o "$build_dir/debug-flight"
"$build_dir/debug-flight" --output-dir "$repo_dir/debug/flights" "$@"
