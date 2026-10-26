#!/usr/bin/env python3
"""Offline JSONL timing analysis and a deliberately small personal click baseline.

No third-party dependencies, network calls, raw text output, or automated actions.
Input events must be chronological within an uninterrupted session; metadata
receipt times may interleave newer than queued input occurrence times.
Files are read in argument order (directory files
by their first event's wall time). Do not combine logs from different people.
"""

import argparse
from collections import Counter, defaultdict
import json
import math
import os
from pathlib import Path
import sys


INPUT_KINDS = frozenset(("key_down", "key_up", "flags_changed", "mouse_down",
                         "mouse_up", "mouse_move", "mouse_drag", "scroll"))


class Moments:
    def __init__(self):
        self.count = 0
        self.mean = self.m2 = 0.0
        self.minimum = self.maximum = None

    def add(self, value):
        self.count += 1
        delta = value - self.mean
        self.mean += delta / self.count
        self.m2 += delta * (value - self.mean)
        self.minimum = value if self.minimum is None else min(self.minimum, value)
        self.maximum = value if self.maximum is None else max(self.maximum, value)

    def export(self):
        return {"count": self.count, "mean_ms": self.mean if self.count else None,
                "stddev_ms": math.sqrt(max(0.0, self.m2 / self.count)) if self.count else None,
                "min_ms": self.minimum, "max_ms": self.maximum}


def cell_for(event, cell_size):
    x, y = event.get("x"), event.get("y")
    if not all(isinstance(v, (int, float)) and not isinstance(v, bool)
               and math.isfinite(v) for v in (x, y)):
        return None
    return f"{math.floor(x / cell_size)},{math.floor(y / cell_size)}"


def analyze(events, cell_size=100):
    """Stream input; memory scales with key codes, heatmap cells, and click count."""
    if cell_size <= 0:
        raise ValueError("cell_size must be positive")
    counts, quality = Counter(), Counter()
    dwell, dd, ud, mouse_hold = Moments(), Moments(), Moments(), Moments()
    by_key, heatmap = defaultdict(Moments), Counter()
    held, mouse_held, last_down, previous_click = {}, {}, None, None
    clicks = []
    session, last_timestamp, current_app = None, None, None

    def reset():
        nonlocal last_down, previous_click, current_app, last_timestamp
        quality["unclosed_key_presses"] += len(held)
        quality["unclosed_mouse_presses"] += len(mouse_held)
        held.clear()
        mouse_held.clear()
        last_down = previous_click = None
        current_app = None
        last_timestamp = None

    for event in events:
        if not isinstance(event, dict):
            quality["invalid_events"] += 1
            reset()
            continue
        timestamp = event.get("timestamp_ns")
        kind = event.get("kind")
        if (event.get("schema_version") != 1 or not isinstance(kind, str) or not kind
                or not isinstance(timestamp, int)
                or isinstance(timestamp, bool) or timestamp < 0):
            quality["invalid_events"] += 1
            reset()
            continue
        if not isinstance(event.get("session_id"), str) or not event["session_id"]:
            quality["invalid_events"] += 1
            reset()
            continue
        if event["session_id"] != session:
            reset()
            session, last_timestamp = event["session_id"], None
            quality["session_segments"] += 1
        counts[kind] += 1
        if kind in ("boundary", "data_loss"):
            if kind == "data_loss":
                dropped = event.get("dropped_record_count", 0)
                if isinstance(dropped, int) and not isinstance(dropped, bool) and dropped > 0:
                    quality["writer_dropped_records"] += dropped
            reset()
            continue
        if kind in INPUT_KINDS:
            if last_timestamp is not None and timestamp < last_timestamp:
                raise ValueError("Input events are out of chronological order within a session segment")
            last_timestamp = timestamp
        app = event.get("app_bundle_id")
        if isinstance(app, str) and app:
            if app != current_app:
                previous_click = None
            current_app = app
        elif kind == "context":
            # A context refresh without an app means the foreground app is unknown.
            current_app = previous_click = None
        if kind in ("key_down", "key_up"):
            key = event.get("key_code")
            if not isinstance(key, int) or isinstance(key, bool) or not 0 <= key <= 65535:
                quality["missing_key_code"] += 1
                reset()
                continue
            if kind == "key_down":
                if event.get("is_repeat"):
                    quality["repeated_key_downs"] += 1
                    continue
                if key in held:
                    quality["duplicate_key_downs"] += 1
                    continue
                press = {"timestamp": timestamp, "release": None, "next": None}
                if last_down is not None:
                    dd.add((timestamp - last_down["timestamp"]) / 1e6)
                    if last_down["release"] is None:
                        last_down["next"] = timestamp
                    else:
                        ud.add((timestamp - last_down["release"]) / 1e6)
                held[key] = last_down = press
            else:
                press = held.pop(key, None)
                if press is None:
                    quality["unmatched_key_ups"] += 1
                    continue
                duration = (timestamp - press["timestamp"]) / 1e6
                dwell.add(duration)
                by_key[str(key)].add(duration)
                press["release"] = timestamp
                if press["next"] is not None:
                    ud.add((press["next"] - timestamp) / 1e6)
        elif kind in ("mouse_down", "mouse_up"):
            button = event.get("button")
            if not isinstance(button, int) or isinstance(button, bool) or button < 0:
                quality["missing_mouse_button"] += 1
                reset()
                continue
            if kind == "mouse_up":
                start = mouse_held.pop(button, None)
                if start is None:
                    quality["unmatched_mouse_ups"] += 1
                else:
                    mouse_hold.add((timestamp - start) / 1e6)
                continue
            if button in mouse_held:
                quality["duplicate_mouse_downs"] += 1
                continue
            mouse_held[button] = timestamp
            cell = cell_for(event, cell_size)
            if cell is None:
                quality["clicks_missing_position"] += 1
                previous_click = None
                continue
            heatmap[cell] += 1
            if not isinstance(app, str) or not app:
                quality["clicks_missing_app_context"] += 1
                previous_click = None
                continue
            previous_cell = previous_click[1] if previous_click and previous_click[0] == app else None
            clicks.append({"app": app, "cell": cell, "previous_cell": previous_cell})
            previous_click = (app, cell)
    reset()
    return {"schema_version": 1, "event_counts": dict(counts), "quality": dict(quality),
            "timing": {"key_hold": dwell.export(), "press_to_press": dd.export(),
                       "release_to_next_press_signed": ud.export(), "mouse_hold": mouse_hold.export()},
            "key_hold_by_code": {k: v.export() for k, v in sorted(by_key.items())},
            "click_heatmap": {"cell_size_points": cell_size, "counts": dict(sorted(heatmap.items()))},
            "notes": ["Timing uses uptime nanoseconds; display precision is not hardware accuracy.",
                      "Input timestamps are event occurrence times; metadata timestamps are receipt times and do not advance input chronology.",
                      "Negative release-to-next-press intervals mean overlapping keys.",
                      "Boundaries, invalid events, and session changes discard incomplete holds and reset sequences.",
                      "Observed app changes reset previous-click context, including changes on non-click events.",
                      "Text, window titles, and app names are never copied into this summary."]}, clicks


def fit(clicks, cell_size=100, min_support=5):
    transitions, popularity = {}, {}
    for click in clicks:
        app, previous, target = click["app"], click["previous_cell"], click["cell"]
        # JSON null is reserved as the start/changed-app context.
        context = json.dumps([app, previous], separators=(",", ":"))
        transitions.setdefault(context, Counter())[target] += 1
        popularity.setdefault(app, Counter())[target] += 1
    return {"schema_version": 1, "model_type": "personal_app_previous_cell_counts",
            "cell_size_points": cell_size, "min_support": min_support,
            "training_clicks": len(clicks),
            "transitions": {k: dict(v) for k, v in transitions.items()},
            "app_popularity": {k: dict(v) for k, v in popularity.items()},
            "limitations": ["Predicts coarse absolute screen cells, not semantic controls or text.",
                            "Assumes unchanged display layout; do not mix changed resolutions/layouts.",
                            "Counts are empirical frequencies, not calibrated confidence.",
                            "No live cursor forecast and no autonomous clicking."]}


def predict(model, app, previous_cell=None, top_k=3, baseline=False):
    if top_k < 1:
        raise ValueError("top_k must be positive")
    if baseline:
        counts = model["app_popularity"].get(app, {})
    else:
        context = json.dumps([app, previous_cell], separators=(",", ":"))
        counts = model["transitions"].get(context, {})
    support = sum(counts.values())
    if support < model["min_support"]:
        return {"abstained": True, "support": support, "candidates": []}
    ranked = sorted(counts, key=lambda cell: (-counts[cell], cell))[:top_k]
    return {"abstained": False, "support": support,
            "candidates": [{"cell": cell, "frequency": counts[cell] / support} for cell in ranked]}


def evaluate(clicks, cell_size=100, min_support=5, train_fraction=0.8):
    if not 0 < train_fraction < 1:
        raise ValueError("train_fraction must be between 0 and 1")
    split = int(len(clicks) * train_fraction)
    model = fit(clicks[:split], cell_size, min_support)
    results = {"method": "chronological_prefix_train_suffix_test_no_updates",
               "train_clicks": split, "test_clicks": len(clicks) - split,
               "train_fraction": train_fraction}
    for name, baseline in (("transition_model", False), ("app_popularity_baseline", True)):
        covered = top1 = top3 = 0
        for click in clicks[split:]:
            result = predict(model, click["app"], click["previous_cell"], baseline=baseline)
            candidates = [candidate["cell"] for candidate in result["candidates"]]
            covered += not result["abstained"]
            top1 += bool(candidates) and candidates[0] == click["cell"]
            top3 += click["cell"] in candidates
        n = len(clicks) - split
        results[name] = {"predicted": covered, "abstained": n - covered,
                         "coverage": covered / n if n else None,
                         "top1_accuracy_all_test": top1 / n if n else None,
                         "top3_accuracy_all_test": top3 / n if n else None,
                         "top1_accuracy_when_predicted": top1 / covered if covered else None,
                         "top3_accuracy_when_predicted": top3 / covered if covered else None}
    results["status"] = "exploratory_holdout" if split and len(clicks) > split else "insufficient_data"
    return results


def read_events(paths):
    for path in paths:
        with path.open(encoding="utf-8") as stream:
            for number, line in enumerate(stream, 1):
                if not line.strip():
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    raise ValueError(f"Invalid JSON at {path.name}:{number}") from None
                if not isinstance(event, dict):
                    raise ValueError(f"Expected object at {path.name}:{number}")
                yield event


def capture_file_order(path):
    """Writer UUID filenames do not establish launch order within a day."""
    first = next(read_events([path]), None)
    if first is None:
        return ("", 0, str(path))
    wall = first.get("wall_time")
    if not isinstance(wall, str) or not wall:
        raise ValueError("Directory ordering requires wall_time; supply explicit files in chronological order")
    timestamp = first.get("timestamp_ns")
    if not isinstance(timestamp, int) or isinstance(timestamp, bool):
        raise ValueError("Capture file is missing its initial timestamp")
    return (wall, timestamp, str(path))


def write_private_json(path, payload):
    # Refuse replacement to avoid accidentally destroying a capture or prior report.
    with open(path, "x", encoding="utf-8", opener=lambda p, f: os.open(p, f, 0o600)) as stream:
        json.dump(payload, stream, indent=2, allow_nan=False)
        stream.write("\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path, help="JSONL files or capture directories, in chronological order")
    parser.add_argument("--summary", required=True, type=Path, help="New private summary JSON path, outside the repo")
    parser.add_argument("--model", type=Path, help="Optional new private model JSON path; fit on all supplied clicks")
    parser.add_argument("--cell-size", type=int, default=100, help="Absolute screen point grid size (default 100)")
    parser.add_argument("--min-support", type=int, default=5, help="Minimum historical context examples before predicting")
    parser.add_argument("--train-fraction", type=float, default=0.8)
    args = parser.parse_args(argv)
    if args.cell_size <= 0 or args.min_support < 1 or not 0 < args.train_fraction < 1:
        parser.error("Require positive cell size/support and 0 < train fraction < 1")
    repo = Path(__file__).resolve().parents[1]
    outputs = [args.summary] + ([args.model] if args.model else [])
    for output in outputs:
        resolved = output.resolve()
        if resolved == repo or repo in resolved.parents:
            parser.error("Keep personal summaries/models outside this public repository")
        if output.exists():
            parser.error("Output already exists; choose a new output path")
    if len({path.resolve() for path in outputs}) != len(outputs):
        parser.error("Summary and model paths must differ")
    try:
        paths = []
        for path in args.inputs:
            paths.extend(sorted(path.rglob("*.jsonl"), key=capture_file_order) if path.is_dir() else [path])
        if not paths:
            parser.error("No JSONL input files found")
        if len({path.resolve() for path in paths}) != len(paths):
            parser.error("Duplicate input files would double count data")
        summary, clicks = analyze(read_events(paths), args.cell_size)
        summary["prediction_evaluation"] = evaluate(clicks, args.cell_size, args.min_support, args.train_fraction)
        write_private_json(args.summary, summary)
        if args.model:
            write_private_json(args.model, fit(clicks, args.cell_size, args.min_support))
    except (OSError, ValueError) as error:
        print(f"Analysis failed: {error}", file=sys.stderr)
        return 1
    print("Offline analysis saved. Keep summaries and models private alongside recordings.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
