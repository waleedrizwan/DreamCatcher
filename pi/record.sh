#!/usr/bin/env bash
# Dream Catcher bedside recorder (Raspberry Pi).
#
# Records the USB mic to WAV during the sleep window, in 10-minute files.
# Cron runs it every 5 minutes and on boot; outside the window it exits
# silently, so a power blip or a missed start costs at most 5 minutes. Unplugging the mic is the
# off switch: arecord fails, we retry every 30 s until the mic comes back
# or the window ends.
#
# Processing happens on the Mac; this script only records.
set -u

# Window times and file names are in this zone regardless of the Pi's system
# timezone (changing that needs sudo; this does not).
export TZ="${DC_TZ:-America/Toronto}"

START="${DC_START:-02:00}"          # local time, HH:MM
END="${DC_END:-09:00}"              # local time, HH:MM (must be after START, same day)
DEVICE="${DC_DEVICE:-plughw:CARD=Device,DEV=0}"
CHUNK_SECS="${DC_CHUNK_SECS:-600}"
ROOT="${DC_ROOT:-$HOME/nights}"
LOG="${DC_LOG:-$HOME/dreamcatcher/record.log}"

mkdir -p "$(dirname "$LOG")" "$ROOT"
log() { echo "$(date '+%F %T %Z') $*" >> "$LOG"; }

# One recorder at a time (cron at 02:00 and @reboot can overlap).
exec 9>"$HOME/dreamcatcher/record.lock"
flock -n 9 || exit 0

# No RTC on a Pi 3: after a power cut the clock is wrong until network time
# syncs. Never decide "are we in the window" or name files on a wrong clock.
for _ in $(seq 1 60); do
  [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ] && break
  sleep 15
done
if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]; then
  log "clock never synced after 15 min; not recording (wrong timestamps are worse than no night)"
  exit 1
fi

to_secs() { date -d "$1" +%s; }
in_window() {
  local now; now=$(date +%s)
  [ "$now" -ge "$(to_secs "today $START")" ] && [ "$now" -lt "$(to_secs "today $END")" ]
}

in_window || exit 0   # the common case: cron tick outside sleep hours, stay quiet
log "started (window $START-$END $TZ, device $DEVICE)"
while :; do
  now=$(date +%s)
  start=$(to_secs "today $START")
  end=$(to_secs "today $END")
  if [ "$now" -lt "$start" ] || [ "$now" -ge "$end" ]; then
    log "outside window; exiting"
    exit 0
  fi

  remaining=$(( end - now ))
  night_dir="$ROOT/$(date +%F)"
  mkdir -p "$night_dir"
  log "recording ${remaining}s into $night_dir"
  arecord -q -D "$DEVICE" -f S16_LE -c 1 -r 16000 \
    -d "$remaining" --max-file-time "$CHUNK_SECS" --use-strftime \
    "$night_dir/%Y-%m-%d_%H-%M-%S.wav" 2>> "$LOG"
  rc=$?

  [ "$(date +%s)" -ge "$end" ] && { log "window ended"; exit 0; }
  log "arecord exited early (rc=$rc), mic unplugged? retrying in 30s"
  sleep 30
done
