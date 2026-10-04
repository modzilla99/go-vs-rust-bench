#!/bin/bash
# Full suite: 5 alternating runs of every configuration. Needs Postgres with the bench DB (see README).
# On a shared laptop, each run waits for a quiet machine and is redone if background CPU was too high.
set -euo pipefail
export DATABASE_URL="${DATABASE_URL:-postgres://$USER@localhost:5432/bench}"
QUIET_PCT=230     # max background CPU (sum of %, idle baseline here is ~200) before a run starts
DISTURBED_PCT=280 # a run averaging more background CPU than this is discarded and redone
ATTEMPTS=4

(cd go-server && go build -o server .)
(cd rust-server && cargo build --release -q)
mkdir -p results && rm -f results/*.json
GO=go-server/server
RUST=rust-server/target/release/rust-server

background_cpu() {
  ps -axo %cpu=,comm= | awk '/postgres|server|oha|awk|ps$|perl|python3/ { next } { s += $1 } END { printf "%.0f", s }'
}

wait_quiet() {
  local calm=0
  while [ "$calm" -lt 5 ]; do
    if [ "$(background_cpu)" -le "$QUIET_PCT" ]; then calm=$((calm + 1)); else calm=0; fi
    sleep 1
  done
}

measure() { # name binary port path run
  local route; route=$(echo "$3$4" | sed 's#.*/##')
  for attempt in $(seq 1 $ATTEMPTS); do
    wait_quiet
    ./load.sh "$1" "$2" "$3" "$4" "$5"
    local bg; bg=$(python3 -c "import json;print(json.load(open('results/$1_${4#/}_mem_run$5.json'))['bg_cpu_pct'])")
    if [ "$bg" -le "$DISTURBED_PCT" ]; then return 0; fi
    echo "  $1 $4 run $5 disturbed (background ${bg}%), retry $attempt" >&2
  done
  echo "  $1 $4 run $5 kept despite background load" >&2
}

for run in 1 2 3 4 5; do
  measure go   "$GO"   8081 /users      "$run"
  measure rust "$RUST" 8082 /users      "$run"
  measure go   "$GO"   8081 /users-db   "$run"
  measure rust "$RUST" 8082 /users-db   "$run"
  measure go   "$GO"   8081 /users-scan "$run"
  measure rust "$RUST" 8082 /users-pg   "$run"
  echo "run $run done"
done
