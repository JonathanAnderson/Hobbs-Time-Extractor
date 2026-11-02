#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["matplotlib>=3.9,<4"]
# ///
"""Render flight-motion diagnostics exported by debug-flight.sh; no engine data used."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import textwrap

import matplotlib

matplotlib.use("Agg")
import matplotlib.dates as mdates
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D


UTC = timezone.utc


def utc(epoch: int) -> datetime:
    return datetime.fromtimestamp(epoch, UTC)


def line_segments(records: list[dict], field: str, *, use_segment_ids: bool = False):
    """Break at missing values, clock resets, or recording gaps; never join gaps."""
    xs, ys = [], []
    previous = None
    for record in records:
        epoch = record["epochSec"]
        value = record.get(field)
        discontinuity = previous is not None and (
            epoch <= previous["epochSec"]
            or epoch - previous["epochSec"] > 15
            or (use_segment_ids and record["segmentID"] != previous["segmentID"])
        )
        if value is None or discontinuity:
            if xs:
                yield xs, ys
            xs, ys = [], []
        if value is not None:
            xs.append(utc(epoch))
            ys.append(value)
        previous = record
    if xs:
        yield xs, ys


def series(ax, records, field, label, color, *, smooth=False, alpha=1.0):
    labelled = False
    for xs, ys in line_segments(records, field, use_segment_ids=smooth):
        ax.plot(
            xs, ys, color=color, linewidth=1.6 if smooth else 0.8,
            alpha=alpha, label=label if not labelled else None,
            marker="." if len(xs) == 1 else None, markersize=3,
        )
        labelled = True


def render(source: Path, destination: Path) -> Path:
    document = json.loads(source.read_text())
    if document.get("schemaVersion") != 1:
        raise ValueError(f"{source}: unsupported diagnostic schema")
    samples = document["samples"]
    points = document["points"]
    if not samples:
        raise ValueError(f"{source}: no timestamped samples")
    plt.rcParams.update({"font.size": 10, "font.family": "DejaVu Sans"})
    fig, axes = plt.subplots(3, 1, figsize=(15, 10), sharex=True)
    fig.patch.set_facecolor("#f5f7fa")
    for ax in axes:
        ax.set_facecolor("#ffffff")
        ax.grid(color="#e4e9ef", linewidth=0.7)
        ax.spines[["top", "right"]].set_visible(False)
        ax.spines[["left", "bottom"]].set_color("#bac5d0")
        ax.tick_params(colors="#334155")
        ax.margins(x=0.01)

    series(axes[0], samples, "gpsAltitudeFeet", "GPS altitude", "#8ba6c5", alpha=0.6)
    series(axes[0], samples, "pressureAltitudeFeet", "Pressure altitude", "#a99ac6", alpha=0.5)
    series(axes[0], samples, "indicatedAltitudeFeet", "Indicated altitude", "#9da8af", alpha=0.5)
    series(axes[0], points, "smoothedAltitudeFeet", "Smoothed altitude", "#2456a6", smooth=True)
    axes[0].set_ylabel("Altitude (ft)")

    series(axes[1], samples, "recordedAGLFeet", "Raw recorded AGL", "#84a9a2", alpha=0.55)
    series(axes[1], points, "recordedAGLFeet", "Smoothed recorded AGL", "#3a788e", smooth=True)
    series(axes[1], points, "estimatedAGLFeet", "Height above taxi elevations", "#007e77", smooth=True)
    axes[1].axhline(0, color="#8796a5", linewidth=0.7)
    axes[1].set_ylabel("Height / recorded AGL (ft)")

    series(axes[2], samples, "groundSpeedKnots", "Groundspeed", "#9b9cc4", alpha=0.6)
    series(axes[2], samples, "indicatedAirspeedKnots", "Indicated airspeed", "#dab991", alpha=0.55)
    series(axes[2], samples, "trueAirspeedKnots", "True airspeed", "#b6a5c1", alpha=0.5)
    series(axes[2], points, "speedKnots", "Detection speed", "#6942a1", smooth=True)
    axes[2].set_ylabel("Speed (kt)")
    axes[2].set_xlabel("Time (UTC)")

    first = document.get("firstTakeoffEpoch", 0)
    last = document.get("lastLandingEpoch", 0)
    for flight in document.get("flights", []):
        for key, color, emphasized in (
            ("takeoffEpoch", "#19804a", first),
            ("landingEpoch", "#bd3f43", last),
        ):
            event = flight.get(key, 0)
            if not event:
                continue
            for ax in axes:
                ax.axvline(
                    utc(event), color=color,
                    linewidth=1.6 if event == emphasized else 0.8,
                    linestyle="-" if event == emphasized else ":",
                    alpha=0.9 if event == emphasized else 0.55,
                )
    # Also show summary events if a future analyzer omits incomplete flight episodes.
    for event, color in ((first, "#19804a"), (last, "#bd3f43")):
        if event:
            for ax in axes:
                ax.axvline(utc(event), color=color, linewidth=1.3, alpha=0.8)

    for ax in axes:
        handles, labels = ax.get_legend_handles_labels()
        if handles:
            ax.legend(handles, labels, loc="upper left", ncol=4, fontsize=8, framealpha=0.94)
        else:
            ax.text(0.5, 0.5, "No data for this panel", transform=ax.transAxes,
                    ha="center", color="#687789")

    locator = mdates.AutoDateLocator(minticks=6, maxticks=12, tz=UTC)
    axes[2].xaxis.set_major_locator(locator)
    axes[2].xaxis.set_major_formatter(mdates.DateFormatter("%H:%M", tz=UTC))
    start, end = min(r["epochSec"] for r in samples), max(r["epochSec"] for r in samples)
    if start == end:
        axes[2].set_xlim(utc(start - 30), utc(end + 30))

    first_text = utc(first).strftime("%Y-%m-%d %H:%M:%S UTC") if first else "not detected"
    last_text = utc(last).strftime("%Y-%m-%d %H:%M:%S UTC") if last else "not detected"
    title = document.get("fileName", source.stem)
    fig.suptitle(title, x=0.08, y=0.976, ha="left", color="#14283f", fontsize=15, fontweight="bold")
    fig.text(0.08, 0.943, f"First takeoff: {first_text}   •   Final landing: {last_text}",
             color="#334155", fontsize=10)
    fig.legend(
        handles=[Line2D([], [], color="#19804a", label="First takeoff"),
                 Line2D([], [], color="#bd3f43", label="Final landing"),
                 Line2D([], [], color="#64748b", linestyle=":", label="Other flight boundaries")],
        loc="upper right", bbox_to_anchor=(0.94, 0.978), fontsize=8, ncol=3, frameon=False,
    )
    note = document.get("note", "")
    caption = "Motion and altitude only; engine readings are excluded. Estimated height relative to taxi elevations; terrain not modeled."
    if document.get("altitudeSource"):
        caption += f" Altitude source: {document['altitudeSource']}."
    if note:
        caption += " " + note
    fig.text(0.08, 0.028, "\n".join(textwrap.wrap(caption, width=155)),
             ha="left", va="bottom", fontsize=8, color="#526276")
    fig.subplots_adjust(left=0.08, right=0.96, top=0.91, bottom=0.12, hspace=0.16)
    destination.mkdir(parents=True, exist_ok=True)
    output = destination / f"{source.stem}.png"
    fig.savefig(output, dpi=170, facecolor=fig.get_facecolor())
    plt.close(fig)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("json_files", type=Path, nargs="+", help="JSON exported by debug-flight.sh")
    parser.add_argument("-o", "--output-dir", type=Path, default=None,
                        help="Output directory; defaults to each JSON file's directory")
    args = parser.parse_args()
    for source in args.json_files:
        try:
            output = render(source, args.output_dir or source.parent)
        except (OSError, ValueError, KeyError) as error:
            parser.exit(1, f"{error}\n")
        print(output)


if __name__ == "__main__":
    main()
