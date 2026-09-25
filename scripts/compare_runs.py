#!/usr/bin/env python3
"""Compare stream-spike runs: timing and cost stats from a runner's stdout
(.out) file, plus item-box match quality against a baseline run, from the
raw events (.jsonl or .jsonl.gz) files.

Usage:

  python3 scripts/compare_runs.py \\
      --baseline LABEL OUT EVENTS \\
      --run LABEL OUT EVENTS [--run LABEL OUT EVENTS ...]

OUT is a stream-spike runner's stdout, saved to a file (the text
`summaryLines` prints; see docs/stream-spike/box-second-1.out for the
shape). EVENTS is the matching *.events.jsonl(.gz) file the runner writes,
one JSON object per line: {"ms": ..., "event": ..., "data": ...}, where
"data" is the raw Claude stream event, still encoded as a JSON string.

For each run, this script rebuilds the final assistant text by
concatenating every text_delta in file order (the same text
StreamSpike.res decodes as JSON), parses it as {"items": [...]}, and reads
each item's "box": [x1, y1, x2, y2]. It then matches the run's boxes to
the baseline's boxes one to one, greedy by IoU (intersection over union)
descending, and reports how many pairs cleared IoU 0.5 and the median IoU
of those pairs. A run whose final text does not parse gets "n/a" in both
IoU columns; its OUT-derived columns still print.

Prints one markdown table row per run, baseline first.
"""

import argparse
import gzip
import json
import re
import statistics
import sys

TOOL_LINE_RE = re.compile(
    r"^tool code_execution: start=(?:(?P<start>\d+)ms|-) done=(?P<done>\d+)ms status=(?P<status>\S+)$"
)
FIRST_ITEM_RE = re.compile(r"^first item: (?:(\d+)ms|-)$")
DONE_RE = re.compile(r"^done: (?:(\d+)ms|-)$")
ITEMS_RE = re.compile(r"^items: (\d+)$")
USAGE_WEB_SEARCH_RE = re.compile(r"^usage: .*webSearch=(\d+)$")
USD_RE = re.compile(r"^usd: \$([0-9.]+)$")
OUTCOME_RE = re.compile(r"^outcome: (\S+)$")

IOU_MATCH_THRESHOLD = 0.5


def read_out(path):
    """Parse a runner .out file into a plain stats dict. Every field is
    None (or 0 for counters) when its line is missing, so a partial or
    unusual OUT file still yields a row instead of a crash."""
    stats = {
        "code_steps": 0,
        "detection_timeouts": 0,
        "longest_step_ms": None,
        "web_searches": None,
        "first_item_ms": None,
        "done_ms": None,
        "items": None,
        "usd": None,
        "outcome": None,
    }

    with open(path, "r", encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")

            m = TOOL_LINE_RE.match(line)
            if m:
                stats["code_steps"] += 1
                if m.group("status") == "detection_timeout":
                    stats["detection_timeouts"] += 1
                if m.group("start") is not None:
                    step_ms = int(m.group("done")) - int(m.group("start"))
                    if stats["longest_step_ms"] is None or step_ms > stats["longest_step_ms"]:
                        stats["longest_step_ms"] = step_ms
                continue

            m = FIRST_ITEM_RE.match(line)
            if m:
                stats["first_item_ms"] = int(m.group(1)) if m.group(1) else None
                continue

            m = DONE_RE.match(line)
            if m:
                stats["done_ms"] = int(m.group(1)) if m.group(1) else None
                continue

            m = ITEMS_RE.match(line)
            if m:
                stats["items"] = int(m.group(1))
                continue

            m = USAGE_WEB_SEARCH_RE.match(line)
            if m:
                stats["web_searches"] = int(m.group(1))
                continue

            m = USD_RE.match(line)
            if m:
                stats["usd"] = float(m.group(1))
                continue

            m = OUTCOME_RE.match(line)
            if m:
                stats["outcome"] = m.group(1)
                continue

    return stats


def open_events(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8")
    return open(path, "r", encoding="utf-8")


def final_text_from_events(path):
    """Concatenate every text_delta in file order. The runner's onRaw
    writes one {"ms", "event", "data"} line per raw SSE event, in arrival
    order, with "data" holding the Claude event as a JSON string."""
    parts = []
    with open_events(path) as f:
        for raw_line in f:
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            try:
                outer = json.loads(raw_line)
            except json.JSONDecodeError:
                continue
            data = outer.get("data")
            if not isinstance(data, str):
                continue
            try:
                inner = json.loads(data)
            except json.JSONDecodeError:
                continue
            if inner.get("type") != "content_block_delta":
                continue
            delta = inner.get("delta")
            if isinstance(delta, dict) and delta.get("type") == "text_delta":
                parts.append(delta.get("text", ""))
    return "".join(parts)


def boxes_from_events(path):
    """Rebuild the final text and read each item's box. Returns None (not
    an empty list) when the text does not parse as {"items": [...]}, so
    callers can tell "no boxes" apart from "unparseable"."""
    text = final_text_from_events(path)
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return None
    if not isinstance(parsed, dict):
        return None
    items = parsed.get("items")
    if not isinstance(items, list):
        return None
    boxes = []
    for item in items:
        box = item.get("box") if isinstance(item, dict) else None
        if isinstance(box, list) and len(box) == 4:
            try:
                boxes.append(tuple(float(v) for v in box))
            except (TypeError, ValueError):
                continue
    return boxes


def iou(box_a, box_b):
    ax1, ay1, ax2, ay2 = box_a
    bx1, by1, bx2, by2 = box_b
    ix1, iy1 = max(ax1, bx1), max(ay1, by1)
    ix2, iy2 = min(ax2, bx2), min(ay2, by2)
    inter = max(0.0, ix2 - ix1) * max(0.0, iy2 - iy1)
    area_a = max(0.0, ax2 - ax1) * max(0.0, ay2 - ay1)
    area_b = max(0.0, bx2 - bx1) * max(0.0, by2 - by1)
    union = area_a + area_b - inter
    return inter / union if union > 0 else 0.0


def greedy_match_ious(run_boxes, baseline_boxes):
    """One-to-one match, greedy by IoU descending. Returns the IoU of
    each matched pair (unmatched boxes on either side are simply left
    out, same as the spot-pass join in docs/stream-spike.md)."""
    candidates = []
    for i, rb in enumerate(run_boxes):
        for j, bb in enumerate(baseline_boxes):
            candidates.append((iou(rb, bb), i, j))
    candidates.sort(key=lambda c: c[0], reverse=True)

    used_run, used_baseline = set(), set()
    matched = []
    for iou_val, i, j in candidates:
        if i in used_run or j in used_baseline:
            continue
        used_run.add(i)
        used_baseline.add(j)
        matched.append(iou_val)
    return matched


def match_columns(run_boxes, baseline_boxes):
    """Returns (count, median) strings for the two IoU columns, or
    ("n/a", "n/a") when either side's text did not parse."""
    if run_boxes is None or baseline_boxes is None:
        return "n/a", "n/a"
    matched = greedy_match_ious(run_boxes, baseline_boxes)
    good = [v for v in matched if v >= IOU_MATCH_THRESHOLD]
    if not good:
        return "0", "n/a"
    return str(len(good)), f"{statistics.median(good):.2f}"


def fmt_int(v, suffix=""):
    return "-" if v is None else f"{v}{suffix}"


def fmt_usd(v):
    return "-" if v is None else f"${v:.4f}"


def build_row(label, stats, match_count, median_iou):
    cells = [
        label,
        str(stats["code_steps"]),
        str(stats["detection_timeouts"]),
        fmt_int(stats["longest_step_ms"], "ms"),
        fmt_int(stats["web_searches"]),
        fmt_int(stats["first_item_ms"], "ms"),
        fmt_int(stats["done_ms"], "ms"),
        fmt_int(stats["items"]),
        fmt_usd(stats["usd"]),
        stats["outcome"] or "-",
        match_count,
        median_iou,
    ]
    return "| " + " | ".join(cells) + " |"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--baseline", nargs=3, metavar=("LABEL", "OUT", "EVENTS"), required=True, help="the run every other run is matched against"
    )
    parser.add_argument(
        "--run", nargs=3, metavar=("LABEL", "OUT", "EVENTS"), action="append", default=[], help="a run to compare; repeatable"
    )
    args = parser.parse_args()

    baseline_label, baseline_out, baseline_events = args.baseline
    baseline_stats = read_out(baseline_out)
    baseline_boxes = boxes_from_events(baseline_events)

    header = (
        "| label | code steps | detection_timeout | longest step | web searches "
        "| first item | done | items | usd | outcome | IoU>=0.5 | median IoU |"
    )
    divider = "|---|---|---|---|---|---|---|---|---|---|---|---|"
    print(header)
    print(divider)

    baseline_match_count, baseline_median_iou = match_columns(baseline_boxes, baseline_boxes)
    print(build_row(baseline_label, baseline_stats, baseline_match_count, baseline_median_iou))

    for label, out_path, events_path in args.run:
        stats = read_out(out_path)
        run_boxes = boxes_from_events(events_path)
        match_count, median_iou = match_columns(run_boxes, baseline_boxes)
        print(build_row(label, stats, match_count, median_iou))


if __name__ == "__main__":
    sys.exit(main())
