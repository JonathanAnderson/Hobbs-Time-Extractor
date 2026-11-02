#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/hobbs-parser-build.XXXXXX")
trap 'rm -rf "$test_build_dir"' EXIT HUP INT TERM

swiftc -swift-version 6 \
    "$repo_dir/Hobbs Time Extractor/GarminExtractor.swift" \
    "$repo_dir/Hobbs Time Extractor/FlightTrack.swift" \
    "$repo_dir/tests/GarminExtractorTests.swift" \
    "$repo_dir/tests/FlightTrackTests.swift" \
    -o "$test_build_dir/GarminExtractorTests"
"$test_build_dir/GarminExtractorTests"
