#!/usr/bin/env bash
# Copy recorded nights from the bedside Pi to this Mac over the home network.
# Recordings land in $DC_DATA/nights (default ~/DreamCatcher), outside the repo:
# they are audio of you sleeping and never belong in git.
set -euo pipefail

DATA="${DC_DATA:-$HOME/DreamCatcher}"
HOST="${DC_HOST:-dreamcatcher}"
mkdir -p "$DATA/nights"

echo "Pulling nights from $HOST → $DATA/nights"
rsync -a --partial --progress "$HOST:nights/" "$DATA/nights/"
echo "Done. Nights on this Mac:"
ls -1 "$DATA/nights"
