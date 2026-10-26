#!/usr/bin/env bash
# Samples the fdev server of instance $1 with ticklens for $3 seconds (default 30) and writes
# the JSON report to $2. Start it in the background, then advance the server with run_ticks at
# game speed 1 for longer than the duration (ticklens loads factorio.pdb before it samples).
# ticklens is read-only toward the game (docs/benchmarks.md, Method).
set -euo pipefail
instance="$1"
out="$2"
duration="${3:-30}"
ticklens="${TICKLENS:-E:/factorio-dev/ticklens-target/release/ticklens.exe}"
pid=$(powershell.exe -NoProfile -Command \
  "(Get-CimInstance Win32_Process -Filter \"Name='factorio.exe'\" | Where-Object { \$_.CommandLine -like '*\\instances\\${instance}\\config*' }).ProcessId" | tr -d '\r')
if [ -z "$pid" ]; then
  echo "no factorio.exe for instance ${instance}" >&2
  exit 1
fi
"$ticklens" report --pid "$pid" --duration "$duration" --json --out "$out"
echo "pid ${pid} -> ${out}"
