#!/usr/bin/env python3
"""Summarize a Mailficient RSS/PSS profile and conservatively detect a plateau."""

import argparse
import csv
import json
import statistics
from pathlib import Path


def linear_slope(points):
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    x_mean = statistics.fmean(xs)
    y_mean = statistics.fmean(ys)
    denominator = sum((value - x_mean) ** 2 for value in xs)
    if denominator == 0:
        return 0.0
    return sum((x - x_mean) * (y - y_mean) for x, y in points) / denominator


parser = argparse.ArgumentParser()
parser.add_argument("profile", type=Path)
parser.add_argument("--minimum-seconds", type=float, default=1200)
parser.add_argument("--maximum-slope-kib-minute", type=float, default=1024)
parser.add_argument("--maximum-range-kib", type=float, default=262144)
parser.add_argument("--json", action="store_true")
args = parser.parse_args()

with args.profile.open(newline="", encoding="utf-8") as stream:
    rows = list(csv.DictReader(stream))

samples = []
for row in rows:
    try:
        samples.append((float(row["elapsed_s"]), int(row["rss_kib"]), int(row["pss_kib"])))
    except (KeyError, TypeError, ValueError):
        continue

if len(samples) < 4:
    raise SystemExit("A profile needs at least four valid samples")

duration = samples[-1][0] - samples[0][0]
tail = samples[len(samples) // 2 :]
rss_points = [(elapsed, rss) for elapsed, rss, _ in tail]
rss_values = [rss for _, rss in rss_points]
pss_values = [pss for _, _, pss in samples if pss > 0]
slope_per_minute = linear_slope(rss_points) * 60
tail_range = max(rss_values) - min(rss_values)
long_enough = duration >= args.minimum_seconds
slope_ok = slope_per_minute <= args.maximum_slope_kib_minute
range_ok = tail_range <= args.maximum_range_kib
plateau = long_enough and slope_ok and range_ok

result = {
    "samples": len(samples),
    "duration_seconds": round(duration, 1),
    "rss_start_kib": samples[0][1],
    "rss_end_kib": samples[-1][1],
    "rss_peak_kib": max(sample[1] for sample in samples),
    "pss_peak_kib": max(pss_values) if pss_values else None,
    "final_half_rss_slope_kib_minute": round(slope_per_minute, 1),
    "final_half_rss_range_kib": tail_range,
    "minimum_duration_met": long_enough,
    "slope_within_limit": slope_ok,
    "range_within_limit": range_ok,
    "plateau_candidate": plateau,
}

if args.json:
    print(json.dumps(result, indent=2))
else:
    print(f"Samples: {result['samples']} over {result['duration_seconds']} seconds")
    print(
        "RSS: start {rss_start_kib} KiB, end {rss_end_kib} KiB, peak {rss_peak_kib} KiB".format(
            **result
        )
    )
    if result["pss_peak_kib"] is not None:
        print(f"PSS peak: {result['pss_peak_kib']} KiB")
    print(
        "Final-half RSS: slope {final_half_rss_slope_kib_minute} KiB/min, range "
        "{final_half_rss_range_kib} KiB".format(**result)
    )
    print("Plateau candidate: " + ("yes" if plateau else "no"))
    if not long_enough:
        print(f"Reason: duration is below the required {args.minimum_seconds:g} seconds")
    if not slope_ok:
        print("Reason: final-half RSS is still growing faster than the configured limit")
    if not range_ok:
        print("Reason: final-half RSS variation exceeds the configured limit")

raise SystemExit(0 if plateau else 1)
