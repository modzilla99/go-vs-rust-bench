# Go vs Rust: same web API, with and without Postgres

Code and per-run results behind the "How much faster is Rust than Go?" Short.

## What is tested
One tiny API in both languages: `GET /users` returns a JSON list of 50 users.

| Route | Go | Rust |
|---|---|---|
| `/users`, in memory | `net/http` + `encoding/json` | `axum` + `serde` |
| `/users-db`, the go-to DB library | `pgx` (`CollectRows`) + `encoding/json` | `sqlx` |
| `/users-scan` and `/users-pg`, tuned | `pgx` with hand-written `Scan` + `goccy/go-json` | `tokio-postgres` + `deadpool` |

Database: PostgreSQL 17, a `users` table with 10,000 rows. Each request reads a random page of 50 rows by primary key:
`SELECT id, name, email, active, tags FROM users WHERE id > $1 ORDER BY id LIMIT 50`.
Each database route uses its own 20-connection pool, opened at startup. Every driver sends exactly one query per request, which we verified with `pg_stat_statements`.

## Setup
- **Machine:** MacBook Pro, M1 Pro (10-core), 16 GB, macOS.
- **Versions:** Go 1.27.1 · Rust 1.97.1 · PostgreSQL 17.11 · oha 1.16.
- **Builds:** default release builds (`cargo build --release`, `go build`), with default GOMAXPROCS and tokio worker counts (10 each).
- **Load:** 64 connections · 10 s warm-up · 20 s measured · 5 alternating runs, median.
- **Quiet machine:** before each run, the script waits until background CPU drops to idle. Any run where background CPU stayed high is discarded and redone. Background CPU for every run is saved in `results/*_run*.json`.

## Results (median of 5)
| Config | req/s (min–max) | p50 | p99 | Peak RAM |
|---|---|---|---|---|
| Go · net/http + encoding/json | 77,325 (77,180–77,769) | 0.55 ms | 3.68 ms | 37.8 MiB |
| Rust · axum + serde | 128,563 (128,249–129,099) | 0.47 ms | 1.15 ms | 13.1 MiB |
| Go · pgx (CollectRows) + encoding/json | 31,802 (31,686–31,876) | 1.91 ms | 3.91 ms | 41.1 MiB |
| Rust · sqlx | 31,238 (31,164–31,611) | 2.0 ms | 2.87 ms | 13.1 MiB |
| Go · pgx (manual Scan) + go-json | 37,099 (36,273–37,226) | 1.61 ms | 3.59 ms | 41.2 MiB |
| Rust · tokio-postgres + deadpool | 49,019 (46,611–49,186) | 1.24 ms | 2.43 ms | 13.4 MiB |

## Reproduce
```bash
export LC_ALL=en_US.UTF-8
createdb bench && psql bench -f schema.sql
./run_all.sh      # about 35 minutes; writes results/ (per-run throughput every 0.5 s, latency percentiles, memory/CPU every 0.25 s)
python3 export_charts.py summary.json charts.json
```

## Caveats
- The load tool, the server and Postgres share one laptop's CPU. A client that uses less CPU leaves more for Postgres, so expect smaller gaps with Postgres on its own server.
- Go's `encoding/json` uses reflection. The tuned Go route uses `goccy/go-json`.
- On the Rust side, the tuned route swaps both the driver and the pool (`sqlx` to `tokio-postgres` + `deadpool`). Go's `pgx` is already a low-level driver, so its tuning is hand-written scanning plus a faster JSON encoder.
- Go's memory is measured at its default garbage-collector settings (GOGC=100).
- All three drivers use cached prepared statements: pgx and sqlx by default, tokio-postgres via `prepare_cached`.
- Memory figures are resident set size (RSS), in MiB.
- Not tried: Go GC tuning (GOGC / GOMEMLIMIT), Go's experimental encoding/json/v2, Rust LTO / codegen-units=1, or a different Rust allocator (e.g. mimalloc). Each could move the numbers.
- sqlx makes Postgres work harder per request (about 226% Postgres CPU vs ~158% for pgx at similar throughput). On a shared machine that CPU is taken from the benchmark itself.
