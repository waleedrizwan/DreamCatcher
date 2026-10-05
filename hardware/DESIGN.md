> **Superseded (2026-10-04).** The ESP32 build was dropped as over-engineered and never ordered. The bedside device is now the user's Raspberry Pi 3 recording audio only, with analysis on the Mac: see [`pi/README.md`](../pi/README.md). The model and data plan in this document still apply.

# Dream Catcher — Bedside Device Design Document

Status: **design, nothing built.** Parts specified and verified 2026-09-19; order not yet placed.
Companion documents: [`parts-list.md`](parts-list.md) (BOM, wiring, gotchas), [`../spec/SHARED_BEHAVIOR_SPEC.md`](../spec/SHARED_BEHAVIOR_SPEC.md) (normative detection behavior), [`../docs/design-ios.md`](../docs/design-ios.md) (the phone app this syncs to).

---

## 0. Why this exists

The phone app works, but it inherits a problem the phone will not let us solve.

**The technical trigger.** Spike 0 on a physical iPhone 17 / iOS 26.6 (2026-09-19, 71 minutes locked) confirmed the failure predicted in [`../docs/design-feasibility.md`](../docs/design-feasibility.md) §B1: Apple's built-in `SoundAnalysis` classifier produced 7 results over ~4 seconds, then returned `com.apple.SoundAnalysis` code 2 and nothing further, while mic RMS kept updating for the full hour. iOS forbids background GPU work. The workaround is a CPU-only Core ML model, which is implemented but costs battery and still leaves the app subject to OS-level termination. Android is worse: users of Sleep as Android report 35–50% of nights failing because the OS kills the app mid-night.

A device whose only job is listening has no OS to fight.

**The personal trigger.** The author has sleep apnea and grinds their teeth. The purpose of this project is measurement of the author's own nights; anything else is downstream of that.

**The market trigger.** A 10-agent scan of ~100 products (2026-09-19) found nothing matching the target combination. Closest:

| Product | Price | Has | Missing |
|---|---|---|---|
| Sleepal AI Lamp | $399 | Bedside, plugged in, own mic, snore clips on device, privacy button, iOS+Android | Cloud account required, snore detection behind $5.99/mo after 6 free months, no gasp/grinding |
| Google Nest Hub 2 | $99 | On-device snore and cough detection, mic-off switch | No audio clips at all, Google account required |
| Withings Sleep | $200 | Under-mattress, snore detection, no subscription | Stores no audio, cloud-synced |
| Motion Pillow / Nitetronic | $360–700 | Bedside mic unit, snore playback | Sold as an airbag pillow system; the tracking is incidental |

The graveyard matters more than the competition: Hello Sense, Amazon Halo Rise, Sleep Number BreatheIQ and Fitbit's snore detection were all shut down, and Sleep Number's users lost their stored recordings. Every one of them was cloud-dependent. A device that works with no account and no server cannot be switched off by its vendor.

**Objective, in one sentence:** a plugged-in bedside device that classifies snoring, choking and teeth grinding on-device, stores events and clips locally, and hands them to the phone over BLE in the morning — with no account, no subscription, and no network.

---

## 1. Scope

### In scope (v1)
- Continuous overnight audio classification on the device, during configured sleep hours.
- Three detected classes plus background: **snoring**, **choking** (gasp/apnea-termination sounds), **teeth grinding**.
- Short audio clips for the loudest episode of each class, stored on microSD.
- Three-position hardware switch: OFF / AUTO / ON.
- Status LED reflecting real device state.
- BLE sync to the existing iOS app; Android at M7 alongside the existing port.
- Clock and schedule pushed from the phone.

### Out of scope (v1)
- Wi-Fi, cloud, accounts, OTA updates. The radio exists on the chip and stays unused.
- Continuous full-night audio recording. Events and clips only.
- Any intervention (no pillow, no vibration, no sound).
- Vitals. HealthKit remains the phone app's business (see [`../docs/design-scope.md`](../docs/design-scope.md)).
- Battery operation. It is a nightstand appliance; it lives on a wall charger.

### Explicit non-goals
- **Not a medical device.** It is a personal sound log. Labels are plain: "Choking", "Teeth grinding".
- Not a general-purpose sleep tracker. No stages, no heart rate, no radar.

---

## 2. Hardware

### 2.1 Bill of materials

Verified against DigiKey.ca 2026-09-19. Full detail, including alternates and stock counts, in [`parts-list.md`](parts-list.md).

| # | Part | DigiKey PN | Qty | Unit | Role |
|---|---|---|---|---|---|
| 1 | Seeed XIAO ESP32S3 Sense | 1597-113991115-ND | 1 | $21.72 | The entire computer: ESP32-S3 dual-core @240 MHz, 8 MB PSRAM, 8 MB flash, PDM mic, microSD slot, BLE 5.0, USB-C. **Ships with the U.FL rod antenna in the box** (DigiKey attribute: "U.FL Antenna(s) Included") — no separate antenna line item, and do not discard the bag |
| 2 | Same Sky SLW-178562-3A-S-D | 2223-SLW-178562-3A-S-D-ND | 2 | $0.78 | SP3T slide switch: OFF / AUTO / ON |
| 3 | Kingbright WP710A10GD | 754-1603-ND | 2 | $0.37 | Green 3 mm diffused LED, 568 nm, Vf 2.2 V — running indicator |
| 4 | Kingbright WP710A10ID | 754-1606-ND | 2 | $0.37 | Red 3 mm diffused LED — fault indicator |
| 5 | Stackpole CF14JT10K0 | CF14JT10K0CT-ND | 10 | $0.042 | 10 kΩ — LED series resistor, night-dim (~0.11 mA) |
| 6 | Stackpole CF14JT1K00 | CF14JT1K00CT-ND | 10 | $0.042 | 1 kΩ — brighter option (~1.1 mA) if 10 kΩ is invisible |
| 7 | DFRobot FIT0096 | 1738-1326-ND | 1 | $4.53 | 400-point breadboard; also jigs the header pins square for soldering |
| 8 | SparkFun PRT-12795 | 1568-12795-ND | 1 | $4.32 | 20× M/M jumper wires |
| 9 | E-Switch EG1218 | EG1903-ND | 2 | $1.06 | SPDT fallback pair if the SP3T sits loose on the breadboard |
| 10 | Sullins PRPC040SAAN-RC | S1011EC-40-ND | 1 | $1.80 | Spare 2.54 mm header strip |

**Subtotal $38.37**, plus ~$15 shipping (free over $100 CAD). Already owned: microSD ≤32 GB, USB-C data cable, USB charger, solder and iron.

### 2.2 Why this board

- **The mic, SD slot and BLE are already on it.** No I2S wiring, no SPI card module, no radio module. One part instead of four.
- **8 MB PSRAM** holds the audio ring buffer and model tensors that 512 KB of internal SRAM could not.
- **Pre-certified radio.** The ESP32-S3-WROOM-1 module inside carries FCC/ISED modular approval, which is the difference between a $2k and a $15k certification bill if this ever becomes a product (§9).
- **Camera is removable.** The Sense expansion ships with a camera (OV3660 on the current DigiKey revision; older stock is OV2640). It unplugs. A device with a camera does not belong in a bedroom.

**The antenna is not optional.** The board carries a U.FL connector and no PCB antenna; Seeed's own wiki says that without the supplied rod antenna "you may not be able to use the Bluetooth feature". It arrives in the box. Snap it on at H0 and leave it on. Verification at H0: advertise a BLE name and confirm a phone sees it from across the room, not just from 30 cm away.

### 2.3 Pin budget

Verified against the [Seeed pin-multiplexing wiki](https://wiki.seeedstudio.com/xiao_esp32s3_pin_multiplexing/) and the board schematic.

| Pin | Use | Free? |
|---|---|---|
| GPIO41 / GPIO42 | PDM mic (data / clock) | Taken by Sense board |
| GPIO7 / 8 / 9 | microSD SCK / MISO / MOSI | Taken by Sense board |
| GPIO21 | microSD chip-select **and** onboard yellow LED | Taken — this is why the status LED is external |
| GPIO3 (D2) | Strapping pin; also routed to the Sense connector as alternate SD CS (R11 unpopulated) | Leave empty |
| GPIO43 (D6) | Prints ROM boot log at reset | Leave empty |
| **GPIO1 (D0)** | Switch throw A → OFF | **Used** |
| **GPIO2 (D1)** | Switch throw B → ON | **Used** |
| **GPIO4 (D3)** | Status LED anode | **Used** |
| GPIO5 / GPIO6 (D4/D5) | Reserved for I2C (a future RTC or sensor) | Free |

Three pins used, two reserved. Comfortable.

### 2.4 Switch and LED wiring

The SP3T has four pins in a row; pin 3 (next to the gap) is the common per the datasheet schematic, not an end pin — a detail that cost one fact-check round and would otherwise have made two positions read identically.

```
Switch P3 (common) ──── GND
Switch P1 ──────────── D0 (GPIO1), INPUT_PULLUP
Switch P4 ──────────── D1 (GPIO2), INPUT_PULLUP
Switch P2 ──────────── not connected

D3 (GPIO4) ── 10 kΩ ── LED anode; LED cathode ── GND
```

Decoded in firmware, with 50 ms debounce:

| D0 | D1 | Position | Behavior |
|---|---|---|---|
| LOW | HIGH | OFF | Mic never sampled. LED dark. |
| HIGH | HIGH | AUTO | Records only inside the configured sleep window. |
| HIGH | LOW | ON | Records now, regardless of schedule. |

A broken or unplugged wire reads HIGH/HIGH, i.e. AUTO. Failing into the normal mode is the right default for a device that is supposed to work unattended.

### 2.5 LED states

| State | Indication |
|---|---|
| OFF position | Dark |
| AUTO, outside sleep window | Green, brief blink every 4 s (armed) |
| Recording | Green, solid |
| Fault (SD missing/full, mic init failed) | Red, 1 Hz blink |
| Firmware fault at boot | Red, solid |

Green is perceptually brighter than red at equal current. Default to the 10 kΩ resistor, then dim further with PWM (`ledcWrite`) if it is still distracting in a dark room. The 1 kΩ parts exist for the opposite case.

### 2.6 Enclosure

3D printed at the library (PLA is fine; no camera means negligible heat). Requirements:
- Mic port directly over the PDM mic, unobstructed and ungasketed.
- Switch slot, LED window, USB-C cutout, microSD access without disassembly.
- Plastic only. A metal or metallized case would detune the antenna.
- Dark filament so the LED does not glow through the walls.
- Tape over the onboard yellow LED, which flickers on every SD write because it shares GPIO21 with chip-select.

Existing free STLs for the bare board ([marcin212's housing](https://www.printables.com/model/998372-seed-studio-xiao-esp32s3-sense-housing)) are a starting point but have no switch or LED cutouts. A custom case comes after the breadboard wiring is frozen.

---

## 3. Firmware architecture

Arduino core 3.x on ESP-IDF 5.x (PlatformIO). Three FreeRTOS tasks, with storage deliberately isolated from the real-time path.

```
Core 0 ── audio task (priority 10, hard real time)
          I2S PDM read, 16 kHz / 16-bit mono, 20 ms chunks
            │
            ├─► 60 s PCM ring buffer in PSRAM (1.9 MB)
            └─► framer: 0.975 s windows, 0.487 s hop
                  │
                  ▼
Core 1 ── inference task (priority 8)
          YAMNet embedding → classification head → per-window scores
            │
            └─► detector state machine (per class) ──► events, episodes
                  │
                  ▼  writeQueue (FreeRTOS queue, depth 32, non-blocking send)
                  │
Core 1 ── storage task (priority 3, best effort)
            ├─► append events.jsonl / episodes.jsonl
            ├─► clip extractor: copy peak range out of the ring ──► clips/*.wav
            └─► periodic state.bin flush
                  │
Main ──── control task (priority 5): switch polling, schedule, LED, BLE server
```

**Why storage is its own task.** A microSD write is not bounded. A card doing internal garbage collection or a block erase can stall a single write for well over 100 ms, and the audio path cannot tolerate that: at a 0.487 s hop, a 100 ms stall eats a fifth of the budget, and a bad 500 ms stall drops windows outright. The inference task therefore never touches the filesystem — it posts a descriptor to `writeQueue` and returns immediately. The storage task drains the queue at low priority and is allowed to fall behind; the ring buffer is the slack.

Queue-full policy: drop the *clip* (it is a convenience) and keep the *event* (it is the data). Increment a dropped-clip counter, surface it in the night's metadata, and never block the producer.

**Verification (H4).** Instrument the audio task with a deadline-miss counter: if the interval between consecutive window handoffs exceeds 1.5× the hop, increment and log. A full night must end with zero misses. Log the queue high-water mark alongside it — if it ever approaches 32, the queue is too shallow or the card is too slow.

### 3.1 Audio

16 kHz, 16-bit, mono. The PDM mic is documented as stable only at this rate, and it is the input rate YAMNet wants, so no resampling anywhere in the chain. `ESP_I2S.h` with `setPinsPdmRx(42, 41)`; OPI PSRAM enabled in the build config.

The 60 s ring buffer (not 30 s) is a deliberate correction of the bug found in the phone app's spec ([`design-feasibility.md`](../docs/design-feasibility.md) M1): an episode confirms only after a 30 s span, so the peak event that triggers a clip can already be at or past the edge of a 30 s ring. 1.9 MB of a spare 8 MB is a cheap fix.

### 3.2 Detection

The window/hop/episode constants are **not redefined here**. [`../spec/SHARED_BEHAVIOR_SPEC.md`](../spec/SHARED_BEHAVIOR_SPEC.md) is normative for snoring, and the device must reproduce the golden fixtures in [`../spec/fixtures/`](../spec/fixtures/) or it is wrong. This is the same rule the two phone platforms follow, and it is the only way the device's numbers and the phone's numbers can ever be compared.

Two deltas the spec does not yet cover, both requiring **schema v2**:

- **Choking is a point event, not a span.** The snore detector's 30 s minimum episode span discards it by construction. Gasps need their own track with their own state machine: single-window confidence above threshold, no span requirement, minimum 10 s refractory period between events.
- **Teeth grinding is a span, but a quiet one.** Likely needs a lower relative-threshold path than snoring, since grinding at 1 m is far closer to the noise floor than a snore is.

### 3.3 Storage layout (microSD, FAT32, ≤32 GB)

```
/nights/2026-09-20/
    session.json          session metadata, mirrors spec `session` columns
    events.jsonl          one line per closed event; append-only
    episodes.jsonl        written when an episode closes
    clips/
        1758345600000_snore.wav     16 kHz mono PCM, 12 s nominal
        1758349210000_choke.wav
    state.bin             heartbeat + last-durable-offset, for power-cut recovery
```

Append-only JSONL, not SQLite, on the device. The phone owns the database; the device owns a log. A power cut mid-write loses at most the final line, and the phone's importer treats a truncated last line as absent.

**Heartbeat lives in RAM, not on the card.** The phone app writes a heartbeat every 60 s because it is defending against iOS killing it. Copying that here would rewrite the same small file 1,440 times a night, ~500k times a year, on a consumer card with a cheap wear-levelling controller and a FAT directory entry that gets touched on every write. That is a self-inflicted card failure, and the failure mode is losing the nights already stored on it.

The device keeps the session heartbeat in RAM and flushes `state.bin` only when:
- the session opens or closes,
- an event or episode is written (the JSONL append is already touching the card, so the flush is nearly free),
- 15 minutes pass with no events (bounds recovery error on a quiet night to 15 minutes),
- the switch leaves the recording position.

This is roughly 20–60 writes a night instead of 1,440, and the recovery story is unchanged in every case that matters: a power cut with events in the night recovers to the last event, which is the only timestamp anyone cares about.

**Verification (H4).** Run an hour with the device recording, pull the card, and check `state.bin`'s modification time and the file's contents against the event log. If it was rewritten every minute, the RAM heartbeat is not working.

Retention: delete oldest night when free space drops under 10%, and never delete a night that has not been marked synced.

### 3.4 BLE protocol

The device is the peripheral; the phone is the central. One custom 128-bit service, four characteristics:

| Characteristic | Dir | Purpose |
|---|---|---|
| `time_sync` | write | Unix ms + IANA tz + UTC offset. Sets the clock. |
| `schedule` | write | Sleep window start/end (local minutes), enable flags per class |
| `night_index` | read/notify | List of nights on card: date, event counts, clip count, byte size, synced flag |
| `transfer` | read/notify | Chunked payload: requested night's JSONL, then clips |

Notes and constraints:
- **Throughput.** Request a 512-byte ATT MTU and 2M PHY. A 12 s clip at 16 kHz/16-bit is ~384 KB, so expect single-digit seconds per clip at realistic BLE rates. Compress with ADPCM (4:1, trivial on both ends) before optimizing anything else.
- **Order matters.** JSONL first, clips second, so a sync interrupted by the user walking away still delivers the night's numbers. Clips resume by offset.
- **iOS background reconnect.** CoreBluetooth state restoration lets the app reconnect to a known peripheral without being opened, but it is best-effort and Apple gives no timing guarantee. Design assumption: sync usually happens unattended in the morning; if it does not, opening the app forces it. Never require the phone to be present during the night.
- **No pairing secrets in v1.** The device advertises only while in range and transfers only to a central that has completed a first-run handshake; the threat model is a curious neighbour, not a targeted attacker. Encrypted pairing is a v2 item.

### 3.5 Schedule and clock

The ESP32's internal RTC drifts and does not survive a power cut. The device treats time as phone-supplied: it refuses to enter AUTO recording until it has received a `time_sync` since boot, and shows the armed blink meanwhile.

**Decision: v1 ships with no DS3231 real-time clock module, deliberately.** The reasoning is build complexity, not cost. A DS3231 adds an I2C module, a coin cell, four more wires on a first-ever breadboard, and a battery-backed clock that can itself be wrong in ways that are hard to debug. The pins are reserved for it (D4/D5, §2.3) and the module is ~$5, so this is reversible in an evening.

**What we accept:** a power blip at 2 a.m. ends the night. The device reboots, has no idea what time it is, declines to record, and waits. It will not guess, and it will never stamp events with a fabricated clock — wrong timestamps are worse than a missing night, because they silently corrupt the history the phone imports.

**Revisit if:** more than one night per month is lost this way, or the device ever leaves the author's nightstand for someone else's.

**Verification (H5).** Unplug the device mid-recording and plug it back in. It must come up in the armed state (green blink, not solid), write nothing to the card, and only begin recording after the phone pushes `time_sync`. Confirm the interrupted night is marked `recovered` with its end time taken from the last event, not from the reboot.

---

## 4. The model

This is the part that determines whether the device is interesting or just a microphone.

### 4.1 Approach

**YAMNet embeddings plus a trained classification head**, quantized to int8 and run on the ESP32-S3 via TFLite Micro or an Edge Impulse export. YAMNet's 1024-dimensional embedding layer is a general-purpose audio representation; the head is a small dense network over it, trained on the four classes that matter. This keeps the learned front-end (which we cannot improve with the data we have) and trains only the part that needs our labels.

The phone app already runs a YAMNet-family Core ML model CPU-only ([`design-ios.md`](../docs/design-ios.md), post-Spike-0 inversion). Sharing the front-end between phone and device means the thresholds in the shared spec keep meaning the same thing on both.

### 4.2 Classes and data

| Class | Source | Confidence |
|---|---|---|
| Snoring | YAMNet has an AudioSet `Snoring` class directly; ICSD (github QingyuLiu0521/ICSD) has strongly-labeled snoring; Kaggle's 500/500 snore set for quick iteration | High |
| Choking / gasp | PSG-Audio (Sci Data 2021, CC BY 4.0, ScienceDB doi 10.11922/sciencedb.00345): 212 patient nights, ambient mic ~1 m above the bed @48 kHz, specialist-scored apnea/hypopnea events in `.rml`. Audio at apnea-event *ends* is the gasp. YAMNet also has `Gasp` and `Snort`. | Medium |
| Teeth grinding | **No open overnight dataset exists.** AudioSet has no teeth-grinding class. This is the real gap. | Low |
| Background | Bedroom noise: fans, HVAC, CPAP, traffic, partner snoring, pets, speech | High |

**Grinding is the unsolved problem.** Options, in order of preference: mine PSG-Audio and ICSD for incidental grinding (unlabeled, would need manual listening); record and hand-label the author's own nights *as a test set only*; last resort, synthesize from close-mic grinding recordings with room impulse responses. A prior product, SOVN, abandoned a bedside grinding sensor because it only caught loud grinders and moved to an in-ear wearable — that is the strongest available evidence that this class may not be reachable from the nightstand at all. v1 ships with grinding behind a flag until held-out numbers justify it.

### 4.3 Training and evaluation

- **Augmentation is the whole game.** Room impulse responses at 0.5–2 m, bedroom noise at varied SNR, a second snorer in the bed, fan and CPAP loops, mic-response simulation for the specific PDM part. Without this, a model trained on clean clips will fall apart against an actual box on an actual nightstand.
- **Evaluate on held-out people, never held-out clips.** Random clip splits leak the speaker and inflate every number.
- **The author's own recorded nights are the test set, not the training set.** A model that works only for one person is a toy; the point is that this could be someone else's device too.
- Target metric: per-episode recall at a fixed false-positive rate per hour, reported separately for each class. Frame accuracy is meaningless when 95% of a night is background.

### 4.4 On-device budget

The ESP32-S3 at 240 MHz with vector instructions runs YAMNet-scale int8 inference in roughly 100–300 ms per window. At one window every 487 ms that is a duty cycle under 60% on one core, with the audio task on the other. This needs measuring on day one; if it does not fit, the fallback is a smaller embedding front-end (fewer mel bands, fewer layers) rather than a slower hop.

---

## 5. Privacy model

- **Nothing leaves the box** except over BLE to a phone that has been through first-run handshake. No Wi-Fi association, no IP stack in the firmware image.
- **The switch is a real off.** In the OFF position the I2S peripheral is de-initialized, not merely ignored. Not a circuit-level mic cut — that would require hardware the Sense board does not expose — but the firmware is the only thing that can read the mic and it is open for inspection.
- **The camera is physically removed** before the device is ever powered in a bedroom.
- **Factory firmware is erased first.** The board ships running a webcam demo with an open Wi-Fi AP (SSID `XIAO_ESP32S3_Sense`, password `seeedstudio`). This is the single most important setup step and it happens before the device enters the bedroom.
- Audio lives on a removable card the owner physically holds. Clips are never uploaded anywhere by any component of this system.

---

## 6. Build plan

| Stage | Goal | Done when |
|---|---|---|
| **H0** | Bring-up | Board flashes; own firmware replaces factory image; camera unplugged; antenna snapped on and BLE advertisement visible from across the room; mic and SD both work with camera absent |
| **H1** | Audio path | 60 s WAV recorded to SD from the PDM mic and audible on a Mac; RMS/noise floor sane at 1 m |
| **H2** | Controls | Switch decodes to three states, LED shows all five states, debounce verified |
| **H3** | Snoring on-device | YAMNet + head, int8, running in real time; reproduces the golden fixtures in `spec/fixtures/` |
| **H4** | Events and clips | events.jsonl, episodes.jsonl and clip WAVs written across a full night; zero audio deadline misses and queue high-water below 32; `state.bin` written tens of times, not 1,440; survives a power cut |
| **H5** | BLE | Time sync, schedule push, night index, chunked transfer; verified with nRF Connect before any app work; unplug/replug leaves the device armed and silent until `time_sync` |
| **H6** | iOS integration | Existing app imports a night from the device into the same schema the phone's own recordings use |
| **H7** | Choking | Point-event track, schema v2, evaluated on PSG-Audio held-out patients |
| **H8** | Enclosure | Custom STL with switch/LED/USB/SD cutouts, printed, device lives on the nightstand |
| **H9** | Grinding | Only if §4.2 produces defensible held-out numbers |

H0–H2 are an evening each. H3 is the project.

---

## 7. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **Grinding is not detectable from a nightstand** | High | Behind a flag; ship snoring + choking regardless. SOVN's retreat is prior evidence. |
| Model does not fit the ESP32-S3 in real time | Medium | Measure at H3 before building anything on top. Fallback: smaller front-end, not a slower hop. |
| PDM mic too noisy at 1–1.5 m | Medium | H1 measures it directly. Fallback: INMP441 I2S mic on the free pins, ~$5. |
| False positives from fans, CPAP, a partner snoring | Medium | Augmentation is designed around exactly these; per-class FP/hour is the headline metric. |
| BLE clip transfer too slow or flaky on iOS | Low | ADPCM first; JSONL-before-clips ordering means a failed transfer still delivers the numbers. |
| Big vendor closes the gap (Sleepal adds clips, Google adds playback) | Low for a personal build | The differentiator is no-account/no-subscription/local, which is structurally hard for them. |
| Power cut loses the clock and a night | Low | Accepted in v1 (§3.5); pins reserved, DS3231 is a one-evening fix. |
| SD write stall blocks the audio path | Medium | Storage is a separate low-priority task behind a queue (§3); deadline-miss counter is a gate at H4. |
| microSD worn out by heartbeat writes | Medium | Heartbeat held in RAM, flushed on events and every 15 min (§3.3). High-endurance card is the escalation. |

---

## 8. Open questions

1. Does the PDM mic plus SD card work with the camera module physically removed? Expected yes from the schematic; Seeed does not state it. **Answered at H0.**
2. What is the real inference latency per window on this silicon? **Answered at H3.**
3. Is there any usable source of labeled teeth-grinding audio? Unresolved; the deciding factor for H9.
4. Does CoreBluetooth state restoration reliably fire an unattended morning sync, or does the app need to be opened? **Answered at H5.**
5. Should the shared spec absorb the device as a third platform, or should the device get its own fixture set? Leaning toward the former, since divergence is exactly what `design-feasibility.md` §B2 warns about.

---

## 9. If this ever becomes a product

Not a v1 concern, but it shapes v1 decisions (notably the pre-certified module in §2.2).

- **Stage 1, 0–50 units.** Hand-assembled, 3D printed case, sold on Tindie or direct. Cost ~$30/unit. Validates demand before any tooling spend.
- **Stage 2, 50–500 units.** Custom PCB in KiCad around the ESP32-S3-WROOM-1 module; turnkey assembly at JLCPCB or PCBWay for a few hundred dollars per small batch.
- **Stage 3, 500+.** Injection molding ($3–5k tooling), contract manufacturer, real inventory and support.
- **Certification.** FCC (US) and ISED (Canada) are required for a finished consumer device. The pre-certified module avoids intentional-radiator testing; unintentional-emissions testing still runs ~$1.5–4k. CE is separate.
- **The cautionary tale.** Smart Nora sold 100k+ units and roughly $30M and still filed for bankruptcy in July 2025, on tariffs and funding. Hardware margins do not forgive logistics.

---

## Appendix A: verified facts and their sources

| Fact | Source |
|---|---|
| Free pins with the Sense board attached; SD pin map (GPIO7/8/9, CS 21) | [Seeed pin multiplexing wiki](https://wiki.seeedstudio.com/xiao_esp32s3_pin_multiplexing/) |
| Antenna is mandatory; board has U.FL only, no PCB antenna | [Seeed BLE wiki](https://wiki.seeedstudio.com/xiao_esp32s3_bluetooth/) + schematic |
| microSD limited to 32 GB, FAT32 | [Seeed filesystem wiki](https://wiki.seeedstudio.com/xiao_esp32s3_sense_filesystem/) |
| Mic stable at 16 kHz/16-bit; `setPinsPdmRx(42, 41)` | [Seeed mic wiki](https://wiki.seeedstudio.com/xiao_esp32s3_sense_mic/) |
| SP3T common is pin 3, not an end pin | [Same Sky SLW-178562 datasheet](https://www.sameskydevices.com/product/resource/slw-178562-3a-s-d.pdf) |
| Factory image runs a webcam and open AP | Seeed getting-started wiki |
| Spike 0 failure: SoundAnalysis code 2 after ~4 s locked | This repo, 2026-09-19 device run; [`../docs/design-feasibility.md`](../docs/design-feasibility.md) §B1 |
| PSG-Audio dataset, 212 nights, CC BY 4.0 | Sci Data 2021, ScienceDB doi 10.11922/sciencedb.00345 |
| Sleepal pricing and subscription gating | [SmartHomeScene review](https://smarthomescene.com/reviews/sleepal-ai-lamp-sleep-tracking-without-wearing-anything/), [Kickstarter FAQ](https://www.kickstarter.com/projects/sleepal/sleepal-ai-lamp-tracking-and-improving-sleep-naturally/faqs) |
| Smart Nora bankruptcy, July 2025 | [BetaKit](https://betakit.com/sleep-tech-startup-smart-nora-files-for-bankruptcy-after-tariffs-derail-product-launch-and-fundraising-attempts/) |
| Sleep as Android nightly failure reports | [Urbandroid forum](https://forum.urbandroid.org/t/it-stopped-recording-in-middle-of-night/10294) |
| SOVN abandoned bedside grinding detection | [getsovn.com](https://getsovn.com/loud-teeth-grinding-reduced-with-vibration/) |
