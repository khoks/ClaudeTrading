#!/usr/bin/env bash
# dashboard/scripts/open.sh
#
# Opens the dashboard HTML in the operator's default browser.
# The HTML itself does all the work — fetches live data from Alpaca,
# reads local files via File System Access API, renders the page.
# Re-running just re-opens. Refreshing the browser tab re-fetches.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HTML="$SCRIPT_DIR/../dashboard.html"

if [ ! -f "$HTML" ]; then
  echo "ERROR: $HTML not found." >&2
  exit 1
fi

# Cross-platform "open" (mirrors CLAUDE.md helpful one-liners).
case "$(uname -s 2>/dev/null || echo unknown)" in
  Darwin) open "$HTML" ;;
  Linux)  xdg-open "$HTML" >/dev/null 2>&1 & ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT*) start "" "$HTML" ;;
  *)
    echo "Don't know how to open files on this OS." >&2
    echo "Manually open: $HTML" >&2
    exit 1
    ;;
esac

echo "$HTML"
