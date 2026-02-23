#!/usr/bin/env bash
# Audit update_all.sh runs on remote hosts. Run this locally (e.g. from the asyla repo).
# Fetches the latest run summary from each host via SSH and reports pass/fail.
#
# Usage: audit_update_all.sh [host...]
#   Default hosts: d01 d02 d03 ns01 ns02
#   Or set HOSTS in the environment.
# Exit: 0 if every host has a run with failed=0; 1 otherwise.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$#" -gt 0 ]; then
  HOSTS=("$@")
else
  HOSTS=(d01 d02 d03 ns01 ns02)
fi

all_ok=0
for host in "${HOSTS[@]}"; do
  out=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" \
    'cd ~/logs/update_all && [ -L latest ] && cd "$(readlink latest)" && cat summary.txt 2>/dev/null' 2>/dev/null) || true
  if [ -z "$out" ]; then
    echo -e "${YELLOW}$host${NC}: no latest run or summary"
    all_ok=1
    continue
  fi
  host_from_file=$(echo "$out" | sed -n 's/^host=//p')
  run_id=$(echo "$out" | sed -n 's/^run_id=//p')
  total=$(echo "$out" | sed -n 's/^total=\([0-9]*\) failed=.*/\1/p')
  failed=$(echo "$out" | sed -n 's/^total=.* failed=\([0-9]*\)$/\1/p')
  if [ "$failed" = "0" ] && [ -n "$total" ]; then
    echo -e "${GREEN}$host${NC}: run_id=$run_id total=$total failed=0"
  else
    echo -e "${RED}$host${NC}: run_id=$run_id total=${total:-?} failed=${failed:-?}"
    echo "$out" | sed 's/^/  /'
    all_ok=1
  fi
done

exit "$all_ok"
