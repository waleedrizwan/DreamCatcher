# Bedside recorder (Raspberry Pi) + morning report (Mac)

The Pi only records. Everything else happens on the Mac.

```
Pi (dreamcatcher.local)                     Mac
record.sh  ── 02:00–09:00, 10-min WAVs ──►  pull.sh     rsync ~/nights → ~/DreamCatcher/nights
           (cron every 5 min + @reboot)     analyze.py  YAMNet (iOS Core ML bundle) → shared detector → report
```

## Every morning

```sh
pi/morning.sh            # pull, analyze the latest night, open the report
pi/morning.sh 2026-10-05 # a specific night
```

Output lands in `~/DreamCatcher/reports/<night>/`: `report.html`, `summary.json`,
`frames.csv` (every 500 ms: levels plus scores for snoring, speech, gasp, snort,
cough, breathing, throat clearing, chewing, biting), and `clips/`.

## How the analysis matches the iPhone app

- Same model file: `ios/Packages/SnoreAudio/Sources/SnoreAudio/Resources/YAMNet.mlmodelc`, CPU-only.
- Same framing as `YAMNetClassifier.swift`: a frame every 500 ms, levels over the raw
  trailing 1 s, YAMNet over the trailing 0.975 s peak-normalized to 0.5 (≤ +30 dB).
- Counting: by default the AI decides (`detect_bouts` in `analyze.py`): frames with a
  snoring score at or above the shared threshold, speech filtered out, merged into bouts
  with the shared 30 s gap, and a bout needs at least two snores. The phone app's
  detector (`spec/reference/detector.py`) also requires each snore to be 12 dB above the
  room, which this USB mic's electrical hum makes impossible; run `--strict` to use it
  anyway. Its result is always recorded in `summary.json` as `strictDetector`.
- Timestamps come from sample counts anchored at each capture start; a gap between
  files (recorder restarted) flushes the detector and re-anchors (spec §0.2).

Deliberate differences from the phone:

- **Hum removal** (`denoise.remove_hum`, on by default, `--keep-hum` to skip) runs
  before levels, YAMNet and clips. A bedroom has several hums at once (60 Hz mains,
  a fan or motor, the USB chip's own lines at multiples of 62.5 Hz, small whines), so
  `find_tones` finds every line that holds its pitch for a whole file (machines do,
  snoring never does), pools the ones that recur across the night, and notches them.
  It took YAMNet from 200 to 446 recognised snore frames on night 1, with no false
  snoring on awake daytime audio.
- **Report**: a line graph of snores per minute with each bout shaded; click anywhere
  to hear that moment. Each bout gets one clip covering the whole bout (hiss and hum
  removed, turned up; `_original.wav` alongside), about 80 MB a night.
- Gasp candidates are listed for listening, not counted.

## The Pi

- Recorder: `~/dreamcatcher/record.sh` (copy of `record.sh`), log `~/dreamcatcher/record.log`.
- Schedule: `crontab -l` on the Pi. Window and timezone are set at the top of `record.sh`
  (`DC_START`, `DC_END`, `DC_TZ`); the Pi's own system timezone does not matter.
- Off switch: unplug the mic. The recorder retries every 30 s and resumes when it is back.
- About 800 MB per 7-hour night; the 32 GB card holds about 30 nights.
- Update the recorder: `scp pi/record.sh dreamcatcher:dreamcatcher/record.sh`.
