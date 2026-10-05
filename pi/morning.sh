#!/usr/bin/env bash
# One command after you wake up: pull last night from the Pi, analyze it, open the report.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ ! -x "$HERE/.venv/bin/python" ]; then
  echo "Setting up the analysis environment (one time)…"
  uv venv --python 3.11 "$HERE/.venv" -q
  uv pip install --python "$HERE/.venv/bin/python" -q -r "$HERE/requirements.txt"
fi

"$HERE/pull.sh"
"$HERE/.venv/bin/python" "$HERE/analyze.py" "$@"
