#!/usr/bin/env bash
# state_persistence/scripts/prune_5min.sh
#
# Removes 5-min snapshots older than the retention window (default 7 days).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

DAYS="${PRUNE_DAYS:-7}"
DIR="$REPO_ROOT/persistence/snapshots/5min"

# Compute cutoff in YYYY-MM-DD format. Anything older than cutoff goes.
cutoff=$(date -u -d "now - $DAYS days" +%Y-%m-%d)

removed=0
shopt -s nullglob
for f in "$DIR"/*.json; do
  base=$(basename "$f" .json)         # YYYY-MM-DDTHH-MM
  fdate="${base%%T*}"                  # YYYY-MM-DD
  if [[ "$fdate" < "$cutoff" ]]; then
    rm -f "$f"
    removed=$((removed + 1))
  fi
done

echo "pruned $removed 5-min snapshots older than $cutoff"
