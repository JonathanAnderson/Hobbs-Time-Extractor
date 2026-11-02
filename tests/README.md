# Parser regression tests

Run `./tests/run.sh` from a Mac with Swift installed. The script compiles the production parser, flight analyzer, and a standalone test executable in a temporary directory; Xcode project changes and third-party dependencies are not needed.

The fixtures are synthetic. They cover the original G1000 format, GDU 465/G3X dual and verbose headers, named/reordered timestamps, RPM at low fuel flow, independent optional telemetry, quoted CSV fields, streaming boundaries, UTF-8 BOM, CRLF, final lines without a newline, UTC date boundaries, and invalid data.

Flight-track cases use timed ground/climb/cruise/descent trajectories to check smoothing, multiple flights, slow flight at altitude, different arrival elevations, missing or sparse altitude sources, engine independence, recording gaps, duplicate timestamps, and flights with an unobserved takeoff or landing. Flight-boundary assertions use physical transition windows instead of exact implementation thresholds.
