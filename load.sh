#!/bin/bash
# usage: load.sh <name> <binary> <port> <path> <run>
# Starts the server, warms up 10 s, then load-tests 20 s with 64 connections.
# Writes results/<name>_<route>_run<run>.json: throughput per 0.5 s, latency percentiles,
# memory/CPU samples every 0.25 s, and results/<name>_<route>_mem_run<run>.json (used by run_all.sh).
set -euo pipefail
name=$1; bin=$2; port=$3; path=$4; run=$5
route=$(echo "$path" | tr -d '/')
duration=20
: "${DATABASE_URL:?DATABASE_URL must be set}"
"$bin" & pid=$!
work=$(mktemp -d)
trap 'kill $pid 2>/dev/null; rm -rf "$work"' EXIT
sleep 1
url="http://127.0.0.1:$port$path"
oha -z 10s -c 64 --no-tui --output-format quiet "$url" >/dev/null

# perl starts ~10x faster than python, keeping the sampler's own CPU cost negligible.
start=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
( while kill -0 $pid 2>/dev/null; do
    now=$(perl -MTime::HiRes=time -e "printf '%.2f', time - $start")
    read -r pg bg < <(ps -axo %cpu=,comm= | awk '
      /postgres/ { pg += $1; next }
      /server|oha|awk|ps$|perl/ { next }
      { bg += $1 } END { printf "%.0f %.0f\n", pg, bg }')
    echo "$now $(ps -o rss=,%cpu= -p $pid) $pg $bg"; sleep 0.25
  done ) > "$work/samples.txt" &
sampler=$!
oha -z ${duration}s -c 64 --no-tui --output-format csv "$url" > "$work/requests.csv"
kill $sampler 2>/dev/null || true
wait $sampler 2>/dev/null || true

out="results/${name}_${route}_run${run}.json"
python3 summarize_run.py "$work/requests.csv" "$work/samples.txt" "$duration" "$out"
python3 -c "
import json; d = json.load(open('$out'))
json.dump({k: round(d[k]) for k in ('peak_kb', 'avg_cpu_pct', 'pg_cpu_pct', 'bg_cpu_pct')}, open('results/${name}_${route}_mem_run${run}.json', 'w'))"
