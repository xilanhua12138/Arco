#!/usr/bin/env python3
"""Measure system-wide jank while the installed Arco app is idle or listening."""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import plistlib
import statistics
import subprocess
import tempfile
import threading
import time
from datetime import datetime, timezone
from typing import Iterable


TARGET_NAMES = (
    "Arco",
    "Arco WebKit",
    "recorder",
    "transcriber",
    "WindowServer",
    "coreaudiod",
    "systemstatusd",
)


def percentile(values: Iterable[float], quantile: float) -> float | None:
    ordered = sorted(float(value) for value in values)
    if not ordered:
        return None
    if not 0 <= quantile <= 1:
        raise ValueError("quantile must be between zero and one")
    rank = max(1, math.ceil(quantile * len(ordered)))
    return ordered[rank - 1]


def summarize_intervals(
    values: Iterable[float],
    *,
    baseline_ms: float | None = None,
    missed_multiplier: float | None = 1.5,
    stall_threshold_ms: float = 16.7,
) -> dict[str, float | int | None]:
    samples = [max(0.0, float(value)) for value in values]
    if not samples:
        return {
            "sample_count": 0,
            "baseline_ms": baseline_ms,
            "p50_ms": None,
            "p95_ms": None,
            "p99_ms": None,
            "max_ms": None,
            "missed_refresh_count": 0,
            "missed_refresh_ratio": 0.0,
            "stall_count": 0,
            "stall_ratio": 0.0,
        }

    learned_baseline = statistics.median(samples) if baseline_ms is None else baseline_ms
    missed_threshold = (
        learned_baseline * missed_multiplier
        if missed_multiplier is not None and learned_baseline > 0
        else None
    )
    missed = (
        sum(value > missed_threshold for value in samples)
        if missed_threshold is not None
        else 0
    )
    stalls = sum(value > stall_threshold_ms for value in samples)
    return {
        "sample_count": len(samples),
        "baseline_ms": round(learned_baseline, 4),
        "p50_ms": round(percentile(samples, 0.50) or 0.0, 4),
        "p95_ms": round(percentile(samples, 0.95) or 0.0, 4),
        "p99_ms": round(percentile(samples, 0.99) or 0.0, 4),
        "max_ms": round(max(samples), 4),
        "missed_refresh_count": missed,
        "missed_refresh_ratio": round(missed / len(samples), 6),
        "stall_count": stalls,
        "stall_ratio": round(stalls / len(samples), 6),
    }


def summarize_process_samples(
    samples_by_name: dict[str, list[dict[str, float]]],
) -> dict[str, dict[str, float | int | None]]:
    result: dict[str, dict[str, float | int | None]] = {}
    for name, samples in samples_by_name.items():
        if not samples:
            result[name] = {
                "sample_count": 0,
                "cpu_mean": None,
                "cpu_p95": None,
                "cpu_max": None,
                "rss_mean_mb": None,
                "rss_peak_mb": None,
            }
            continue
        cpu = [sample["cpu"] for sample in samples]
        rss = [sample["rss_kb"] / 1024 for sample in samples]
        result[name] = {
            "sample_count": len(samples),
            "cpu_mean": round(statistics.fmean(cpu), 3),
            "cpu_p95": round(percentile(cpu, 0.95) or 0.0, 3),
            "cpu_max": round(max(cpu), 3),
            "rss_mean_mb": round(statistics.fmean(rss), 3),
            "rss_peak_mb": round(max(rss), 3),
        }
    return result


def summarize_gpu_samples(
    samples: Iterable[dict[str, float]],
) -> dict[str, float | int | None]:
    collected = list(samples)
    if not collected:
        return {
            "sample_count": 0,
            "device_mean": None,
            "device_p95": None,
            "device_max": None,
            "device_above_80_ratio": 0.0,
            "renderer_p95": None,
            "tiler_p95": None,
        }

    device = [sample["device"] for sample in collected]
    renderer = [sample["renderer"] for sample in collected]
    tiler = [sample["tiler"] for sample in collected]
    saturated = sum(value >= 80.0 for value in device)
    return {
        "sample_count": len(collected),
        "device_mean": round(statistics.fmean(device), 3),
        "device_p95": round(percentile(device, 0.95) or 0.0, 3),
        "device_max": round(max(device), 3),
        "device_above_80_ratio": round(saturated / len(collected), 6),
        "renderer_p95": round(percentile(renderer, 0.95) or 0.0, 3),
        "tiler_p95": round(percentile(tiler, 0.95) or 0.0, 3),
    }


def sample_gpu() -> dict[str, float] | None:
    output = subprocess.run(
        ["ioreg", "-a", "-r", "-c", "AGXAccelerator"],
        check=True,
        capture_output=True,
    ).stdout
    entries = plistlib.loads(output)
    for entry in entries:
        statistics_entry = entry.get("PerformanceStatistics", {})
        if "Device Utilization %" not in statistics_entry:
            continue
        return {
            "device": float(statistics_entry["Device Utilization %"]),
            "renderer": float(statistics_entry.get("Renderer Utilization %", 0.0)),
            "tiler": float(statistics_entry.get("Tiler Utilization %", 0.0)),
        }
    return None


def _elapsed_seconds(value: str) -> int | None:
    try:
        day_part, clock = (value.split("-", 1) if "-" in value else ("0", value))
        fields = [int(field) for field in clock.split(":")]
        if len(fields) == 2:
            hours = 0
            minutes, seconds = fields
        elif len(fields) == 3:
            hours, minutes, seconds = fields
        else:
            return None
        return int(day_part) * 86_400 + hours * 3_600 + minutes * 60 + seconds
    except ValueError:
        return None


def _arco_webkit_pids() -> set[int]:
    output = subprocess.run(
        ["ps", "-axo", "pid=,etime=,command="],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    arco_elapsed: int | None = None
    webkit: list[tuple[int, int]] = []
    for line in output.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3:
            continue
        pid_text, elapsed_text, command = fields
        elapsed = _elapsed_seconds(elapsed_text)
        if elapsed is None:
            continue
        if command.startswith("/Applications/Arco.app/Contents/MacOS/Arco"):
            arco_elapsed = elapsed
        elif "/System/Library/Frameworks/WebKit.framework/" in command:
            webkit.append((int(pid_text), elapsed))
    if arco_elapsed is None:
        return set()
    return {
        pid
        for pid, elapsed in webkit
        if abs(elapsed - arco_elapsed) <= 15
    }


def _classify_process(pid: int, command: str, arco_webkit: set[int]) -> str | None:
    if command.startswith("/Applications/Arco.app/Contents/MacOS/Arco"):
        return "Arco"
    if pid in arco_webkit:
        return "Arco WebKit"
    if "/Applications/Arco.app/Contents/Resources/native/recorder" in command:
        return "recorder"
    if "/Applications/Arco.app/Contents/Resources/native/arco-" in command and "transcriber" in command:
        return "transcriber"
    if command.startswith("/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"):
        return "WindowServer"
    if command.startswith("/usr/sbin/coreaudiod"):
        return "coreaudiod"
    if command.startswith("/System/Library/PrivateFrameworks/SystemStatusServer.framework/Support/systemstatusd"):
        return "systemstatusd"
    return None


def sample_processes(arco_webkit: set[int]) -> dict[str, dict[str, float]]:
    output = subprocess.run(
        ["ps", "-axo", "pid=,%cpu=,rss=,command="],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    aggregate: dict[str, dict[str, float]] = {}
    for line in output.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) != 4:
            continue
        pid_text, cpu_text, rss_text, command = fields
        try:
            pid = int(pid_text)
            cpu = float(cpu_text)
            rss = float(rss_text)
        except ValueError:
            continue
        name = _classify_process(pid, command, arco_webkit)
        if name is None:
            continue
        current = aggregate.setdefault(name, {"cpu": 0.0, "rss_kb": 0.0})
        current["cpu"] += cpu
        current["rss_kb"] += rss
    return aggregate


class SchedulerJitterSampler:
    def __init__(self, duration: float, interval: float = 0.01) -> None:
        self.duration = duration
        self.interval = interval
        self.values: list[float] = []
        self.thread = threading.Thread(target=self._run, name="arco-perf-jitter")

    def start(self) -> None:
        self.thread.start()

    def join(self) -> None:
        self.thread.join()

    def _run(self) -> None:
        end = time.monotonic() + self.duration
        deadline = time.monotonic() + self.interval
        while deadline < end:
            time.sleep(max(0.0, deadline - time.monotonic()))
            now = time.monotonic()
            self.values.append(max(0.0, (now - deadline) * 1_000))
            deadline += self.interval
            if deadline < now - self.interval:
                deadline = now + self.interval


def _display_probe_binary(source: Path) -> Path:
    cache = Path(tempfile.gettempdir()) / "arco-display-link-probe"
    if cache.exists() and cache.stat().st_mtime >= source.stat().st_mtime:
        return cache
    subprocess.run(
        [
            "swiftc",
            str(source),
            "-o",
            str(cache),
            "-framework",
            "CoreVideo",
            "-framework",
            "Foundation",
        ],
        check=True,
    )
    return cache


def _verdicts(report: dict[str, object]) -> list[dict[str, str]]:
    issues: list[dict[str, str]] = []
    processes = report["processes"]
    system_status = processes["systemstatusd"]
    if (system_status["cpu_p95"] or 0) >= 25:
        issues.append({
            "severity": "critical",
            "metric": "systemstatusd.cpu_p95",
            "message": "systemstatusd consumed at least a quarter of one CPU core at p95",
        })
    display = report["display"]
    if display["missed_refresh_ratio"] > 0.01:
        issues.append({
            "severity": "warning",
            "metric": "display.missed_refresh_ratio",
            "message": "more than 1% of display callbacks missed the learned refresh interval",
        })
    scheduler = report["scheduler"]
    if scheduler["stall_count"] > 0:
        issues.append({
            "severity": "warning",
            "metric": "scheduler.stall_count",
            "message": "the 10 ms scheduler probe was delayed by more than 16.7 ms",
        })
    gpu = report["gpu"]
    if (gpu["device_p95"] or 0) >= 90:
        issues.append({
            "severity": "critical",
            "metric": "gpu.device_p95",
            "message": "GPU utilization reached at least 90% at p95",
        })
    if gpu["device_above_80_ratio"] > 0.10:
        issues.append({
            "severity": "warning",
            "metric": "gpu.device_above_80_ratio",
            "message": "GPU utilization stayed above 80% for more than 10% of samples",
        })
    return issues


def capture(phase: str, duration: float, sample_interval: float) -> dict[str, object]:
    source = Path(__file__).with_name("display_link_probe.swift")
    display_binary = _display_probe_binary(source)
    display_process = subprocess.Popen(
        [str(display_binary), str(duration)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    scheduler = SchedulerJitterSampler(duration)
    scheduler.start()
    webkit_pids = _arco_webkit_pids()
    process_samples: dict[str, list[dict[str, float]]] = {
        name: [] for name in TARGET_NAMES
    }
    load_averages: list[float] = []
    gpu_samples: list[dict[str, float]] = []
    deadline = time.monotonic() + duration
    while time.monotonic() < deadline:
        started = time.monotonic()
        current = sample_processes(webkit_pids)
        for name, sample in current.items():
            process_samples[name].append(sample)
        gpu = sample_gpu()
        if gpu is not None:
            gpu_samples.append(gpu)
        load_averages.append(os.getloadavg()[0])
        time.sleep(max(0.0, sample_interval - (time.monotonic() - started)))

    scheduler.join()
    stdout, stderr = display_process.communicate(timeout=max(5.0, duration + 2))
    if display_process.returncode != 0:
        raise RuntimeError(f"display probe failed: {stderr.strip()}")
    display_intervals = [
        float(line) for line in stdout.splitlines() if line.strip()
    ]
    report: dict[str, object] = {
        "schema_version": 2,
        "phase": phase,
        "captured_at": datetime.now(timezone.utc).astimezone().isoformat(),
        "duration_seconds": duration,
        "sample_interval_seconds": sample_interval,
        "cpu_percent_semantics": "100 percent equals one fully occupied CPU core on macOS ps",
        "processes": summarize_process_samples(process_samples),
        "display": summarize_intervals(display_intervals, stall_threshold_ms=16.7),
        "scheduler": summarize_intervals(
            scheduler.values,
            baseline_ms=0.0,
            missed_multiplier=None,
            stall_threshold_ms=16.7,
        ),
        "gpu": summarize_gpu_samples(gpu_samples),
        "system": {
            "load_average_1m_mean": round(statistics.fmean(load_averages), 3),
            "load_average_1m_max": round(max(load_averages), 3),
        },
    }
    report["verdicts"] = _verdicts(report)
    return report


def print_summary(report: dict[str, object], output: Path) -> None:
    display = report["display"]
    scheduler = report["scheduler"]
    print(f"Arco performance phase: {report['phase']}")
    print(f"Report: {output}")
    print(
        "Display: "
        f"baseline {display['baseline_ms']} ms, "
        f"p95 {display['p95_ms']} ms, p99 {display['p99_ms']} ms, "
        f"missed {display['missed_refresh_ratio'] * 100:.2f}%"
    )
    print(
        "Scheduler: "
        f"p95 {scheduler['p95_ms']} ms, p99 {scheduler['p99_ms']} ms, "
        f">16.7 ms stalls {scheduler['stall_count']}"
    )
    gpu = report["gpu"]
    print(
        "GPU: "
        f"mean {gpu['device_mean']}%, p95 {gpu['device_p95']}%, "
        f"max {gpu['device_max']}%, >=80% {gpu['device_above_80_ratio'] * 100:.2f}%"
    )
    for name, summary in report["processes"].items():
        if summary["sample_count"]:
            print(
                f"{name}: CPU mean {summary['cpu_mean']}%, "
                f"p95 {summary['cpu_p95']}%, max {summary['cpu_max']}%"
            )
    for verdict in report["verdicts"]:
        print(f"[{verdict['severity']}] {verdict['metric']}: {verdict['message']}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", required=True, choices=("idle", "listening", "stopped"))
    parser.add_argument("--duration", type=float, default=15.0)
    parser.add_argument("--sample-interval", type=float, default=0.5)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.duration <= 0 or args.sample_interval <= 0:
        parser.error("duration and sample interval must be positive")

    output = args.output
    if output is None:
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        output = Path("artifacts/perf") / f"{stamp}-{args.phase}.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    report = capture(args.phase, args.duration, args.sample_interval)
    output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print_summary(report, output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
