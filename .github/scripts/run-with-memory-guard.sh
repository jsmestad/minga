#!/usr/bin/env bash
# Runs a command while watching host memory, so memory exhaustion fails the step with a visible error instead of starving the hosted runner until GitHub reports "lost communication" with no step log.
#
# Usage: run-with-memory-guard.sh <command> [args...]
#
# Environment:
#   MEMORY_GUARD_MIN_AVAILABLE_MB  Kill the command when MemAvailable falls below this many MiB (default 768).
#   MEMORY_GUARD_INTERVAL_SECONDS  Sampling interval in seconds (default 1).
#   MEMORY_GUARD_MEMINFO           Path to the meminfo file (default /proc/meminfo); tests override it.
#
# On exit the script prints the lowest available RAM plus free swap it observed, so passing runs record their memory headroom.
set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <command> [args...]" >&2
  exit 64
fi

min_available_mb="${MEMORY_GUARD_MIN_AVAILABLE_MB:-768}"
interval="${MEMORY_GUARD_INTERVAL_SECONDS:-1}"
meminfo="${MEMORY_GUARD_MEMINFO:-/proc/meminfo}"

mem_field_mb() {
  awk -v field="$1:" '$1 == field { print int($2 / 1024); exit }' "$meminfo"
}

# Headroom counts free swap as well as available RAM: the job adds swap so a large analysis pages instead of starving the runner.
headroom_mb() {
  echo $(( $(mem_field_mb MemAvailable) + $(mem_field_mb SwapFree) ))
}

total_mb="$(( $(mem_field_mb MemTotal) + $(mem_field_mb SwapTotal) ))"
lowest_available_mb="$(headroom_mb)"

"$@" &
pid=$!

kill_command() {
  pkill -KILL -P "$pid" 2>/dev/null || true
  kill -KILL "$pid" 2>/dev/null || true
}

trap 'kill_command; exit 143' TERM INT

while kill -0 "$pid" 2>/dev/null; do
  available_mb="$(headroom_mb)"

  if [ "$available_mb" -lt "$lowest_available_mb" ]; then
    lowest_available_mb="$available_mb"
  fi

  if [ "$available_mb" -lt "$min_available_mb" ]; then
    echo "::error title=Memory guard::Available RAM plus free swap fell to ${available_mb} MiB of ${total_mb} MiB (limit ${min_available_mb} MiB) while running '$*'. Killing it before the runner is starved."
    echo "Largest processes by resident memory:"
    ps -eo pid,rss,vsz,etime,args --sort=-rss | head -n 10
    kill_command
    wait "$pid" 2>/dev/null
    exit 137
  fi

  sleep "$interval"
done

status=0
wait "$pid" || status=$?

echo "Memory guard: lowest available RAM plus free swap ${lowest_available_mb} MiB of ${total_mb} MiB while running '$*'."
exit "$status"
