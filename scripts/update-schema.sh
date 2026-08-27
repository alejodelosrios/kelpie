#!/usr/bin/env bash
set -euo pipefail

if [ "${HERDR_ENV:-}" != "1" ]; then
    echo "error: HERDR_ENV=1 not set — must run inside a herdr session" >&2
    exit 1
fi

if ! command -v herdr &>/dev/null; then
    echo "error: herdr binary not found in PATH" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$REPO_ROOT/src/herdr/testdata/herdr-api.schema.json"

mkdir -p "$(dirname "$OUT")"
herdr api schema --json > "$OUT"
echo "wrote $(wc -c < "$OUT") bytes to $OUT"
