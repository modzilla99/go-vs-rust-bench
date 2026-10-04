"""Builds summary.json and the video's chart data from results/*.json.

usage: export_charts.py <summary.json> <charts.json>
"""
import json
import statistics
import sys

RUNS = range(1, 6)
CONFIGS = {
    "go_json": ("go", "users", "Go · net/http + encoding/json"),
    "rust_json": ("rust", "users", "Rust · axum + serde"),
    "go_pgx": ("go", "users-db", "Go · pgx (CollectRows) + encoding/json"),
    "rust_sqlx": ("rust", "users-db", "Rust · sqlx"),
    "go_tuned": ("go", "users-scan", "Go · pgx (manual Scan) + go-json"),
    "rust_tokio_pg": ("rust", "users-pg", "Rust · tokio-postgres + deadpool"),
}
SETUP = {
    "machine": "MacBook Pro, M1 Pro (10-core), 16 GB, macOS",
    "versions": "Go 1.27.1 · Rust 1.97.1 · PostgreSQL 17.11 · oha 1.16",
    "load": "64 connections · 10 s warm-up · 20 s measured · 5 alternating runs, median",
    "db": "users table, 10,000 rows · random page of 50 by primary key · each route: 20-connection pool opened at startup",
    "caveat": "Load tool, server and Postgres share one laptop",
}


def load(lang: str, route: str, run: int) -> dict:
    with open(f"results/{lang}_{route}_run{run}.json") as f:
        return json.load(f)


def main() -> None:
    summary_path, charts_path = sys.argv[1], sys.argv[2]
    summary, charts = {}, {}
    for key, (lang, route, label) in CONFIGS.items():
        runs = [load(lang, route, r) for r in RUNS]
        rps = [r["summary"]["requestsPerSec"] for r in runs]
        median_rps = statistics.median(rps)
        median_run = min(runs, key=lambda r: abs(r["summary"]["requestsPerSec"] - median_rps))
        pct = {p: statistics.median(r["latencyPercentiles"][p] for r in runs) * 1000 for p in ("p50", "p90", "p99", "p99.9")}
        summary[key] = {
            "label": label,
            "rps": round(median_rps),
            "rps_min": round(min(rps)),
            "rps_max": round(max(rps)),
            "p50_ms": round(pct["p50"], 2),
            "p99_ms": round(pct["p99"], 2),
            "p99_9_ms": round(pct["p99.9"], 2),
            "success": min(r["summary"]["successRate"] for r in runs),
            "peak_mb": round(statistics.median(r["peak_kb"] for r in runs) / 1024, 1),
            "server_cpu_pct": round(statistics.median(r["avg_cpu_pct"] for r in runs)),
            "postgres_cpu_pct": round(statistics.median(r["pg_cpu_pct"] for r in runs)),
            "background_cpu_pct": round(statistics.median(r["bg_cpu_pct"] for r in runs)),
        }
        charts[key] = {
            "bucket_s": median_run["throughput_series"]["bucket_s"],
            "throughput_runs": [[round(v) for v in r["throughput_series"]["rps"]] for r in runs],
            "median_run": runs.index(median_run),
            "latency_ms": {p: round(v, 3) for p, v in pct.items()},
            "memory": [[s["t"], s["rss_mb"]] for s in median_run["memory_series"]],
        }
    summary["setup"] = SETUP
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    with open(charts_path, "w") as f:
        json.dump(charts, f)


if __name__ == "__main__":
    main()
