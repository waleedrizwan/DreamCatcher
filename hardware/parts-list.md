> **Superseded (2026-10-04).** The ESP32 build was dropped as over-engineered and never ordered. The bedside device is now the user's Raspberry Pi 3 recording audio only, with analysis on the Mac: see [`pi/README.md`](../pi/README.md). The model and data plan in this document still apply.

# Bedside snore recorder prototype: parts and wiring

Researched 2026-09-19. Prices in CAD unless marked. Pin facts were checked against the Seeed wiki and schematic.

## Required parts

| Part | Exact product | Qty | Price | Where |
|---|---|---|---|---|
| Main board | [Seeed Studio XIAO ESP32S3 Sense, SKU 113991115 (DigiKey 1597-113991115-ND). Antenna included. Headers NOT soldered.](https://www.digikey.ca/en/products/detail/seeed-technology-co-ltd/113991115/18724504) | 1 | CAD $21.72 (4,709 in stock) | DigiKey.ca |
| microSD card | [TEAMGROUP 32GB microSDHC UHS-I U1 with SD adapter (TUSDH32GCL10U03)](https://www.canadacomputers.com/en/microsd-cards/249848/teamgroup-32gb-microsdhc-uhs-i-u1-tusdh32gcl10u03.html) | 1 | CAD $16.99 (10+ online, in stores) | Canada Computers (store pickup avoids shipping). Any name-brand 32GB card you already own also works. |
| 3-position switch (OFF/AUTO/ON) | [Same Sky SLW-178562-3A-S-D, SP3T slide, through-hole, pins at 0 / 2.5 / 5 / 10 mm](https://www.digikey.ca/en/products/detail/same-sky-formerly-cui-devices/SLW-178562-3A-S-D/24399212) | 2 | CAD $0.78 each (2,246 in stock) | DigiKey.ca (same order as board) |
| Status LED | [Kingbright WP710A10ID, 3 mm red diffused, Vf 2 V](https://www.digikey.ca/en/products/detail/kingbright/WP710A10ID/2769809) | 2 | CAD $0.37 each (169,898 in stock) | DigiKey.ca |
| LED resistor | [Stackpole CF14JT10K0, 10 kOhm 1/4 W through-hole](https://www.digikey.ca/en/products/detail/stackpole-electronics-inc/CF14JT10K0/1741265) | 10 | CAD $0.042 each at qty 10 ($0.42 total); $0.16 for one | DigiKey.ca |
| Breadboard | [DFRobot FIT0096, 400 tie points, half size](https://www.digikey.ca/en/products/detail/dfrobot/FIT0096/7597069) | 1 | CAD $4.53 (9,642 in stock) | DigiKey.ca |
| Jumper wires | [SparkFun PRT-12795, 20 male-to-male wires, 6 inch](https://www.digikey.ca/en/products/detail/sparkfun-electronics/PRT-12795/5993860) | 1 | CAD $4.32 (2,298 in stock) | DigiKey.ca |

**Total:** About CAD $50.28 in parts (DigiKey $33.29 + microSD $16.99) + $15 DigiKey shipping (orders under $100) = about CAD $65 before tax. Assumes you already own a USB-C charger and a data-capable USB-C cable. Shipping source: https://www.digikey.ca/en/help-support/delivery-information/delivery-time-and-cost

## Optional parts

| Part | Exact product | Price | When to buy |
|---|---|---|---|
| No-solder board (buy INSTEAD of the DigiKey board) | [Seeed XIAO ESP32-S3 Sense (Pre-Soldered), SKU 102010635](https://www.seeedstudio.com/Seeed-Studio-XIAO-ESP32S3-Sense-Pre-Soldered-p-6335.html) | US$14.90, in stock at Seeed. Shipping/duty to Canada unverified. DigiKey.ca: 0 stock until Nov 2026 (per research). | If you have no soldering iron and no makerspace/library iron. Slower, ships from overseas. |
| Fallback switches | [E-Switch EG1218 SPDT slide switch x2 (DigiKey EG1903-ND, same part as SparkFun COM-00102)](https://www.digikey.ca/en/products/detail/e-switch/EG1218/101726) | CAD $1.06 each (19,725 in stock, checked 2026-09-19) | Add to the first DigiKey order. If the SP3T sits loose, use two of these (master OFF/ON + AUTO/FORCE). Replaces Adafruit 805, which DigiKey does not stock (2,849 was its minimum order quantity, not stock). |
| Spare header strip | [Sullins PRPC040SAAN-RC, 40-pin 2.54 mm breakaway header](https://www.digikey.ca/en/products/detail/sullins-connector-solutions/PRPC040SAAN-RC/2775214) | CAD $1.80 | Add to the first order as insurance. Headers are reported to be in the box, but I could not confirm it on Seeed's page. |
| USB data cable | [Adafruit 4474 USB-A to USB-C cable, ~1 m, data + charge](https://www.digikey.ca/en/products/detail/adafruit-industries-llc/4474/11587355) | CAD $7.73 (1,741 in stock) | Only if you have no known data cable. An Apple USB-C charge cable already carries USB 2 data (https://www.apple.com/ca/shop/product/myqt3am/a/240w-usb-c-charge-cable-2m). Any 5 V phone charger you own powers the board. |
| High-endurance microSD | [SanDisk 32GB High Endurance microSDHC (SDSQQNR-032G-GN6IA)](https://www.amazon.ca/SanDisk-Endurance-microSDHC-Adapter-Monitoring/dp/B07P14QHB7) | CAD $37.00 per research; Amazon blocked my re-check | Only if the cheap card corrupts or you switch to all-night continuous recording. |
| Better antenna | [Seeed 2.4GHz Rod Antenna for XIAO (2.81 dBi, U.FL)](https://www.seeedstudio.com/2-4GHz-2-81dBi-Antenna-for-XIAO-ESP32C3-p-5475.html) | US$2.20 | Only if morning BLE sync is flaky with the included antenna. |
| Case | [Free 3D-print STL: XIAO ESP32S3 Sense housing (Printables)](https://www.printables.com/model/998372-seed-studio-xiao-esp32s3-sense-housing) | Free (filament only). Link from research; site blocked my re-check. | After the breadboard version works. Print at the library. Use plastic, never metal (blocks BLE). |

## Wiring

- Verified free header pins with the Sense board on: D0-D7 = GPIO1,2,3,4,5,6,43,44. Taken: D8/D9/D10 = SD SCK/MISO/MOSI (GPIO7/8/9), GPIO21 = SD CS + onboard LED, GPIO41/42 = mic. Sources: https://wiki.seeedstudio.com/xiao_esp32s3_pin_multiplexing/ and Seeed schematic.
- Use only D0 (GPIO1), D1 (GPIO2), D3 (GPIO4). Leave D2 (GPIO3) empty: strapping pin and also routed to the Sense connector. Leave D6 (GPIO43) empty: prints boot log. Keep D4/D5 free for I2C later.
- Switch SLW-178562-3A-S-D: 4 pins in a line. Name them P1 P2 P3 (close together) and P4 (alone after the gap). Put them in 4 separate breadboard rows: n, n+1, n+2, n+4. Bend up or snip the 2 frame tabs first.
- P3 = common (per datasheet schematic) -> XIAO GND. P1 -> D0 (GPIO1). P4 -> D1 (GPIO2). P2 -> nothing.
- Firmware: pinMode(INPUT_PULLUP) on D0 and D1. D0 LOW = slider at P1 end = OFF. Both HIGH = middle = AUTO. D1 LOW = slider at P4 end = ON. Debounce ~50 ms. A broken wire reads as AUTO.
- Test once with Serial.print. If the middle and one end read the same, the GND wire is on the wrong pin; move it to the pin next to the gap.
- LED: D3 (GPIO4) -> 10k resistor -> LED long leg. LED short leg -> XIAO GND. About 0.13 mA. Dim more with PWM (ledcAttach / ledcWrite) or blink briefly.
- Power comes from USB-C only. Nothing connects to the 5V or 3V3 pins.
- Fallback with two EG1218 switches: each middle pin -> GND. Switch A end pin -> D0 (LOW = OFF). Switch B end pin -> D1 (LOW = force ON). Both HIGH = AUTO. Other end pins unused.

## Gotchas

- Soldering: the in-stock DigiKey board needs 14 header pins soldered. Solder before clipping the Sense board on. True no-solder = pre-soldered SKU 102010635 from Seeed.
- Antenna is mandatory. The board has only a U.FL connector, no onboard antenna (schematic). Seeed: without it 'you may not be able to use the Bluetooth feature'. Press one edge in first; never pull it straight off. https://wiki.seeedstudio.com/xiao_esp32s3_bluetooth/
- Onboard yellow LED shares GPIO21 with SD chip-select and is active-low, so expect it to flicker on SD writes. Cover it with tape. The red charge LED turns off 30 s after plug-in when no battery is attached.
- microSD: 32GB max, FAT32. If it fails to mount, do a full (not quick) format with SD Card Formatter. https://wiki.seeedstudio.com/xiao_esp32s3_sense_filesystem/
- Before it goes in the bedroom: unplug the camera and flash your own firmware. Factory firmware runs a webcam and a Wi-Fi AP (SSID XIAO_ESP32S3_Sense, password seeedstudio). Slide the Sense board off sideways; never pry it up. Test mic + SD with the camera unplugged on day one (expected to work from the schematic, not stated by Seeed).
- Firmware traps: mic is stable only at 16 kHz/16-bit mono; Arduino core 3.x uses ESP_I2S.h with setPinsPdmRx(42, 41); enable OPI PSRAM. Do not fit the heat sink on a breadboard: it sits under the board and stops it seating. https://wiki.seeedstudio.com/xiao_esp32s3_sense_mic/

## Free software

- Arduino IDE 2 + Espressif esp32 board package 3.x. Board: XIAO_ESP32S3, PSRAM: OPI PSRAM. https://www.arduino.cc/en/software and https://wiki.seeedstudio.com/xiao_esp32s3_getting_started/
- Optional instead of Arduino: PlatformIO in VS Code, or ESP-IDF. https://platformio.org
- Edge Impulse (free tier) to train the snore model. Seeed tutorial for this board; keep EON Compiler off. https://wiki.seeedstudio.com/xiao_esp32s3_keyword_spotting/
- Kaggle snoring dataset (500 snore / 500 non-snore 1 s clips). https://www.kaggle.com/datasets/tareqkhanemu/snoring
- NimBLE-Arduino library for BLE on the ESP32-S3. https://github.com/h2zero/NimBLE-Arduino
- nRF Connect for Mobile or LightBlue (iOS/Android) to test BLE before writing the app.
- SD Card Formatter. https://www.sdcard.org/downloads/formatter/
- Xcode + CoreBluetooth for the iPhone app (already have).

## Corrections made during fact-check

- Switch wiring was under-specified. Datasheet schematic shows the common is the 3rd pin (at 5.0 mm, next to the gap), not an end pin. Throws are pins 1, 2, 4. GND on an end pin makes two positions read the same. Fixed in wiring.
- Claim 'both inputs can read low mid-slide' is wrong: the unused middle throw sits between the two wired throws. Debounce anyway.
- Switch fit caveat added: pitch matches a breadboard (0/2.5/5/10 mm, verified on the drawing) but pins are only ~3 mm long and 0.5 x 0.4 mm flat, and the 2 frame tabs do not line up. Added Adafruit 805 x2 as same-order fallback.
- Dropped E-Switch EG2301 (researcher 3's pick): pin pitch could not be verified by anyone.
- SD pin map in researcher 2 was wrong. Correct per Seeed wiki: GPIO7 = SCK, GPIO8 = MISO, GPIO9 = MOSI, GPIO21 = CS.
- Charge LED was marked unverified/may blink. Seeed wiki for the S3: with no battery the red light comes on at plug-in and goes off after 30 seconds.
- USB-C CC resistors were marked unverified by researcher 3. I read Seeed's schematic: R1 and R2 are 5.1K on CC1/CC2, so USB-C to USB-C chargers will power it.
- Advice to stick on the heat sink is wrong for a breadboard. It mounts on the underside and the stock headers are too short to seat with it (Seeed forum). Skip it; no camera means little heat. https://forum.seeedstudio.com/t/extended-height-breadboard-headers-for-seeed-studio-xiao-esp32s3-with-xiao-heatsink-installed/283867
- New finding: D2 (GPIO3) is also routed to the Sense board connector as an alternate SD CS (R11 unpopulated). Second reason to leave D2 unused. Schematic + https://forum.seeedstudio.com/t/xiao-esp32s3-sense-spi-sd-card-pin-schematic-error/284934
- D6/D7 are not needed for the serial console. The XIAO S3 uses native USB (no USB-UART chip on the schematic). They are free; only D6 (GPIO43) prints ROM boot text.
- Headers in the box: researchers disagreed and Seeed's product page did not show a part list to me. A forum user mentions kit-provided headers. Treated as likely; added a $1.80 header strip as insurance.
- Bad or stale links replaced: Canada Computers iCAN charger URL returns 404; iCAN USB-C cable is sold out online; Adafruit 758 jumpers are out of stock at DigiKey.ca. Charger and cable moved to optional (use what you own).
- Consolidated small parts onto one DigiKey.ca order. Splitting across Canada Robotix / BC Robotics / PiShop adds a second shipping charge for about $10 of parts.
- Dropped for a first prototype: DS3231 RTC, external I2S mic, RGB LED, resistor kit, card reader, project box, full-size breadboard.

## DigiKey.ca cart (verified 2026-09-19, subtotal CAD $37.21)

Paste into the cart's **Bulk Add** box (format: quantity, DigiKey part number). Manufacturer part numbers fail for some lines, so use these:

```
1, 1597-113991115-ND
2, 2223-SLW-178562-3A-S-D-ND
2, 754-1606-ND
10, CF14JT10K0CT-ND
1, 1738-1326-ND
1, 1568-12795-ND
2, EG1903-ND
1, S1011EC-40-ND
```

Guest checkout is available. Shipping is $15 on orders under $100.
