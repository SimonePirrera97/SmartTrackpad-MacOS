# Smart Trackpad board firmware

A dedicated Smart Trackpad on the Waveshare **ESP32-S3-Touch-LCD-7B**: the same
trackpad surface and app control strip as the iPad app, talking to the same Mac
companion.

**Status, 2026-10-12.** Confirmed by the user on the board: screen, touch, pointer,
scroll, pinch, drag, app buttons, the session over USB, Wi-Fi and Bluetooth with the
route picked by hand, the startup search reaching Wi-Fi, USB at startup, the top bar, a
second finger joining a hold-drag, and the screen going dark when the Mac's lid closes
("perfect"). Flashed but not yet reported on: Quit App, the power button, the brightness
row, Bluetooth fallback at startup, returning to USB by hand, Bluetooth beyond 30 s,
battery level with a real cell. The user is trying the board on USB for some days.

**Update, 2026-10-13:** power-button screen-off and touch wake confirmed after a
backlight-control repair. Idle wake and Mac sleep/lid wake still need regression checks.

**Candidate update, 2026-10-15:** true deep sleep, double-tap slide dragging and the
VS Code Save/Delete row are implemented; build/flash evidence is recorded in
`docs/developer-notes.md`. Sleep current, overnight endurance and physical wake/drag
acceptance remain pending.

## What exists

| Part | File |
|---|---|
| Gesture engine (C port of `packages/GestureCore`), checked against the shared golden traces | `components/trackpad_core/gesture.c` |
| Compact input encoding, command validity | `components/trackpad_core/protocol.c` |
| Session: handshake, heartbeat, app context, timeouts, key hand-over | `components/trackpad_core/session.c` |
| Display, IO extension chip, GT911 multi-touch, backlight, battery voltage | `main/board.c` |
| Touch task: interrupt-driven reading, routing (pad → engine, bar and strip → LVGL), dimming | `main/touch.c` |
| Screen: top bar, pad, app strip, Settings, Wireless page | `main/ui.c` |
| USB CDC session link, joining and leaving the bus | `main/usb_link.c` |
| TLS-PSK session shared by both radios | `main/secure_link.c` |
| Wi-Fi: saved networks, scan, join, socket | `main/wifi_link.c` |
| Bluetooth LE central | `main/ble_link.c` |
| Settings in flash, startup route, offline and sleep, battery percentage | `main/main.c` |

## Intended behaviour

This is the specification the firmware is tested against. Where the board does something
else, that is a bug, not a variant.

### Screen

- **Top bar, full width:** connection button, route button, Settings, battery cell,
  power button. Everything below it on the right is app-specific only.
- **Connection button:** green "Connected", amber "Connecting", grey "Disconnected".
  A tap goes offline (ends the session, radios off, the board leaves the USB bus) or back
  online. Offline is not saved: the board always starts online.
- **Route button:** shows the one route in use: USB, Wi-Fi or Bluetooth. A tap opens a
  menu under the button with the three routes, the current one highlighted. Choosing one
  ends a session on any other route. A touch anywhere else closes the menu. The choice
  is not saved.
- **Power button:** the square in the top right corner. A tap ends the session, switches
  the backlight off, both radios off and takes the board off the USB bus. The next touch
  anywhere restarts the board after deep sleep and does nothing else: it reaches
  neither the pad nor a button. The chosen route and prior offline state are restored.
- **Settings:** one page, two columns, no scrolling. Holds the gesture switches, the two
  speeds, brightness and the button to the Wireless page. Brightness is the row
  "Brightness" under a heading that says which level it is ("SCREEN, ON A COMPUTER'S USB
  PORT" or "SCREEN, ON BATTERY"); label, slider and value must not overlap. Changes are
  written to flash when the page closes, and only if something changed.
- **Wireless page:** state of USB, Wi-Fi and Bluetooth, the remembered Mac with Forget
  Mac, the network list (a tick marks a remembered network; tapping it joins without a
  password), Scan, and the password keyboard.
- **Battery cell:** percentage and icon, with a USB mark while a computer is on the USB port.
- **Pad:** hints in the middle. The status line under them is shown only while there is
  no session ("Waiting for the Mac", why a route was lost); while connected it is empty.
- **App strip:** title of the Mac's front app and its buttons, in the iPad's order (VS Code: Copy/Cut, Paste, Save/Delete, Undo/Redo; no Compile); Show
  Desktop and Quit App (Cmd+Q to the front app, board only) side by side last. Buttons are disabled while there is no session.
- Opening Settings, the Wireless page or the route menu releases everything held on the
  Mac, and every touch then belongs to the screen, none to the pad.

### Routes

- **One route at a time, and the board never changes it by itself after startup.** USB:
  both radios off. Wi-Fi or Bluetooth: the other radio off, and the board leaves the USB
  bus. Plugging or unplugging the cable changes nothing; a route that drops is retried,
  not replaced.
- **At startup only**, in this order: USB if a computer drives the USB port within 4 s of
  power-on; otherwise Wi-Fi for 25 s; otherwise Bluetooth for 40 s; if neither produced a
  session, back to USB. The first session ends the search, and so does picking a route,
  Disconnect or the power button. An unpaired board stays on USB. During the search the
  board stays on the USB bus: a computer that appears on the port before a radio has a
  session, or within half a second of it, gets USB and ends the search.
- Wi-Fi and Bluetooth work only after the Mac has remembered the board over the cable.
  Until then the radios stay off and the pad says so when one of them is picked.
- The Wireless page keeps Wi-Fi on while it is open, whatever the route, so networks can
  be listed and joined.

### Power and screen

- Two brightness levels are kept: on a computer's USB port (default 100 %) and otherwise
  (default 10 %). The slider changes the one in effect and its heading says which.
- **Follows the Mac (2026-10-15 update).** When the Mac sleeps or its lid is
  closed with no external display, the companion sends `disconnect` with
  `"sleeping": true`. The board now enters the same offline/deep-sleep path as
  Power, on every route, after fingers lift and two seconds of settling. Touch
  is required to wake it; reopening the Mac alone cannot wake a deeply sleeping
  board. Closing the lid while using an external display changes nothing.
  This replaces the earlier screen-only/automatic-reconnect behavior. USB lid
  close, remaining asleep after reopening, then touch wake/reconnect passed the
  joint test on 2026-10-15. Wireless regressions remain pending.
- Dim to 15 % after 30 s without a touch, backlight off after 5 min. The touch that
  wakes the screen from this is handled normally (unlike the wake from the power button).
- A finger whose reports stop for 250 ms without a lift counts as lifted.

### Gestures

Same engine and defaults as the iPad, with one deliberate difference: three-finger drag
is on, Mission Control uses four fingers, and page swipes (three fingers, exclusive with
three-finger drag) start off.

Second difference (updated 2026-10-15): **tap, then slide on the second touch to drag.**
The second touch must start within 350 ms and 30 gesture units of the first tap;
movement past the tap tolerance presses the mouse button before sending motion.
Stationary double/triple taps keep their click counts. Hold-to-drag is replaced on
the board; its saved switch now controls Double-tap drag. The iPad gesture is unchanged.
**A second finger can join an active drag.** Once the button is pressed, a second finger landing on the pad does
not end the drag. Each finger moves the pointer by its own travel, so one can hold still
while the other slides, lifts, lands again and slides further. Either finger may lift;
the button is released when both have lifted, or when a third finger lands. Two fingers
during such a drag never scroll or pinch.

## Open problems

- **USB cable (resolved 2026-10-12).** `bus: host seen 0` from power-on with the Mac
  listing no device was the cable on the USB port: after the user swapped it with the
  UART cable the board settles on USB 1.7 s after power-on. Returning to USB by hand
  after a radio route has not been retried with the good cable.
- **Battery reading without a battery** shows 93–100 %; see below.
- **Wi-Fi range.** The board has been seen at −78 to −93 dBm with session timeouts on the Mac.
- **Touch interrupt line** is unverified: read the "reports / interrupts" log line.

The Mac needs no board-specific setup: the companion looks for a serial port named
`/dev/cu.usbmodemSmartTrackpad*` once a second and opens it, exactly as it opens a
cabled iPad. That name comes from the USB serial-number string in `usb_link.c`; on the
test Mac the port appears as `/dev/cu.usbmodemSmartTrackpad1`.

## Wireless pairing

No pairing key is ever typed on the board. While it is on the trusted cable, the Mac's
**Remember this board** sends an `enroll` message with a fresh 32-byte key, the Mac's
`.local` host name and its display name; the board stores them in flash and answers
`enrolled`; the Mac stores the key in its keychain. Wirelessly the board then:

1. resolves the stored host name and connects to port 47821;
2. runs TLS 1.2 `TLS_PSK_WITH_AES_128_GCM_SHA256` with identity `smart-trackpad-board`
   and its key (the Mac's listener holds this key beside the iPad's session key);
3. sends `pairRequest` with `boardProof` = HMAC-SHA256(key, "smart-trackpad-board-proof-v1:" + session UUID), hex.
   The Mac accepts it at once, without the approval step an iPad needs.

The route is `g_route` in `main/main.c`: `pick_startup_route` sets it once after
power-on, `app_set_route` (the top bar's menu) afterwards. It is not stored in flash.
While the route is a radio, or the board is disconnected or asleep, it leaves the USB bus
(`tud_disconnect` in `usb_link_poll`), so the port vanishes on the Mac and the companion
does not open it. The Mac has no route logic of its own: it opens the board's serial
port whenever it appears and no session is running, and accepts the remembered board on
Wi-Fi or Bluetooth.

Over Bluetooth the Mac is the GATT peripheral (service `ADCA1000-…`). The board writes
TLS bytes to `ADCA1001` with response, one write at a time, and receives them as
notifications on `ADCA1002`. The fast unacknowledged channel (`1003`/`1004`) is not
used. Because that carries far fewer packets than a finger produces, `app_send` sums
consecutive pointer moves and scroll steps while the route is busy.

## Power and radio policy

- **Radios.** `power_task` in `main/main.c` keeps the Wi-Fi radio on only while Wi-Fi is
  the route, the board is paired and online; the Bluetooth task scans and connects only
  while Bluetooth is the route. The Wireless page forces Wi-Fi on while it is open, so
  networks can be listed. "Off" for Bluetooth means no scanning and no connection; the
  controller stays initialised.
- **Sleep (2026-10-15 candidate).** Power first ends the session and goes offline.
  After all fingers lift and a two-second settling interval, the touch task arms
  RTC EXT1 on GT911 INT (GPIO4), disables backlight and LCD power (EXIO6), then enters
  ESP32 deep sleep. CPU, RGB refresh and radio execution stop. The GT911, expander,
  regulators and other board circuitry still consume power; endurance is unmeasured.
  A touch restarts the firmware and restores the chosen route and previous offline
  state from RTC memory. Its first contact is swallowed. No timer wake is scheduled.
  LCD shutdown is followed by draining zero-contact reports and waiting for quiet
  INT before arming a floating RTC input. Active IRQ or I2C failures defer entry.
  An initial version woke immediately in the lid test; the repaired USB lid
  test now passes, staying asleep until touch. Battery endurance is unmeasured.
  Five idle minutes also triggers this on wireless routes or without a computer on
  USB. Normal USB stays online until a Mac sleep notification or Power press.
  Deep sleep requires touch to wake; it cannot receive a Mac wake message.
- **Backlight.** `brightness` applies on a computer's USB port, `brightness_battery`
  (default 10 %) otherwise; the slider edits whichever is in effect. Dim to 15 % after
  30 s idle, backlight off after 5 min, restored by any touch.
- **Battery.** The expander's ADC (register 0x06, 10-bit, 3.3 V reference, 3:1 divider)
  is read at startup, then once a minute, and mapped through a rough lithium curve. **With no battery fitted
  it reads about 4.1–4.3 V, so the screen shows 93–100 %**: a missing cell cannot be told
  from a full one yet. Calibrate against a real cell and a multimeter.
  Failed ADC reads leave the last estimate unchanged; before any valid reading the
  display says "Battery unknown" (or "Battery ?" with a USB mark if a host is present).
  Readings above 4.35 V show 100% by user preference (including USB-only use);
  readings below 2.5 V show unknown. Neither identifies whether a battery is fitted.
  Charging is handled by the board's CS8501, independently of firmware. Waveshare
  specifies 580 mA with the stock R45. Its CHRG/STDBY signals drive LEDs, not ESP32
  inputs, so USB presence and voltage alone cannot establish charging/full status.
  See the [vendor documentation](https://www.waveshare.com/wiki/ESP32-S3-Touch-LCD-7B)
  and [schematic](https://files.waveshare.com/wiki/ESP32-S3-Touch-LCD-7B/ESP32-S3-Touch-LCD-7B-Schematic.pdf).
- **Touch.** The GT911's INT line (GPIO 4, either edge) wakes the touch task; timeouts of
  5 ms with a finger down and 40 ms idle are the fallback. The task logs report and
  interrupt counts every 2000 reports: if interrupts stay at 0 the line is not working
  and the board is silently polling. A finger whose reports stop for 250 ms without a
  lift frame is treated as lifted (logged as a warning), which is what stops a stuck drag.
- **What is not event-driven and cannot be:** the RGB panel has no memory of its own, so
  the chip streams the whole frame to it continuously whether or not anything changed.
  LVGL already redraws only the regions that change.

## Build and flash

```sh
. ~/esp/esp-idf/export.sh            # ESP-IDF v5.5.5
cd firmware/waveshare-esp32s3-7inch
idf.py build
idf.py -p /dev/cu.<port> flash monitor   # port marked "USB TO UART"
```

The two USB-C ports have different jobs. **USB TO UART** is for flashing and logs.
**USB** is the trackpad connection to the Mac; nothing but session bytes may appear on it.

`bash scripts/check.sh` at the repository root runs the desktop checks of the portable core.

## Lessons from the first bring-up

- **Internal RAM.** With the display, Wi-Fi and Bluetooth together the 512 KB of internal
  RAM runs out: the Bluetooth controller failed with "Malloc failed" and the board
  boot-looped. What fixed it: Wi-Fi/lwIP and mbedTLS allocations in PSRAM, link task
  stacks in PSRAM, Wi-Fi IRAM optimisations off, one Bluetooth connection, bounce buffer
  10 lines instead of 20, Bluetooth started before Wi-Fi. About 120 KB is free before
  Wi-Fi starts now. Check that figure in the log before adding anything memory-hungry.

- **UART switch.** The slide switch next to the BOOT button (printed `UART2 UART1`) must be
  on **UART1**, or the USB TO UART port is silent and flashing fails with "No serial data
  received". With it on UART1, automatic reset works and the buttons are not needed.
- **Cable.** A charge-only USB-C cable on the USB port lights the board but never enumerates.
- **macOS accessory prompt.** The first time, macOS holds the port back until "Allow accessory
  to connect" is approved.
- **Fonts.** The built-in Montserrat fonts have no middle dot or ellipsis; use ASCII in labels.
- While nothing is connected the strip buttons are disabled, so they show no press feedback.

## First power-on checklist

Each step isolates one untested layer; stop at the first failure and read the log.

1. Flash through USB TO UART. The log should show no I2C or GT911 errors.
2. The screen lights up with the top bar (Connecting, USB, Settings, battery, power), "Connect to your Mac" on the left and a dimmed button column on the right. Wrong colors, tearing or a blank screen point at `board.c` timings or the backlight/power expander pins.
3. Scroll the button column with one finger: it should move. That proves GT911 reading and the strip routing.
4. Plug the **USB** port into the Mac with the companion running. The Mac's cable status should read "Smart Trackpad board on USB · connecting", then the board's top bar shows "Connected" and "USB".
5. Pointer, tap, two-finger scroll, hold-drag, pinch, three-finger gestures, strip buttons following the front app.
6. Unplug: the Mac releases input; replug reconnects by itself.

## Design notes

- `trackpad_core` has no ESP-IDF or display dependency and must stay that way; it is the
  part checked against the iPad's behavior. When `packages/GestureCore` changes, change
  `gesture.c` in the same commit and keep the fixtures passing on both.
- Units: the engine works in 1000 units per shortest pad dimension as tuned on the iPad.
  `touch.c` uses 1.1 units per pixel so travel and tap/hold tolerances match per millimetre.
- Input is sent as it is sampled, with no client-side queue. Over Bluetooth `app_send`
  merges consecutive pointer moves and scroll steps while a write is outstanding.
- `drag_second_finger` is an engine option that is off by default, so the C engine still
  matches `packages/GestureCore` and the golden traces; only `app_apply_capabilities`
  switches it on. `packages/GestureCore` has no such option yet.
- **Deliberate difference from the iPad (user request, 2026-10-11):** on the board
  Mission Control uses **four** fingers (`mission_fingers = 4`), so it can stay on beside
  three-finger drag, which is on by default. Page swipes still use three fingers and are
  exclusive with three-finger drag, so they start off. With `mission_fingers = 3` the C
  engine behaves exactly like `packages/GestureCore`; the golden traces run in that mode.
- The settings screen fits on one page in two columns on purpose: scrolling a full-screen
  panel redraws all 1024x600 pixels per frame and was visibly jerky.
- Going offline, sleeping, or picking a radio makes the board leave the USB bus
  (`tud_disconnect`), so its serial port vanishes on the Mac and the companion stays free
  for an iPad. Going online on the USB route rejoins.
- The firmware requires `input.binary.v1` and never requests `input.ack.v1`.
- Three locks would be easy to deadlock: the rule is LVGL lock first, core lock second,
  and the touch/USB tasks only ever take the core lock (`main/app.h`).
- Pins, RGB timings and the IO extension register protocol come from the vendor's
  Apache-2.0 examples at github.com/waveshareteam/ESP32-S3-Touch-LCD-7B.

## Confirmed board — 2026-10-11

User confirmed the model: **ESP32-S3-Touch-LCD-7B** (ESP32-S3-WROOM-1-N16R8, 16 MB flash, 8 MB octal PSRAM). Toolchain: ESP-IDF v5.5.5 in `~/esp/esp-idf`. From the [Waveshare wiki](https://www.waveshare.com/wiki/ESP32-S3-Touch-LCD-7B), not yet verified on the hardware:

- Display: 1024×600 IPS, 16-bit RGB (ST7262). R3–R7 = GPIO 1, 2, 42, 41, 40; G2–G7 = 39, 0, 45, 48, 47, 21; B3–B7 = 14, 38, 18, 17, 10; HSYNC 46, VSYNC 3, DE 5, PCLK 7. Timings come from the vendor demo/schematic.
- Touch: GT911, five points, I2C SDA 8 / SCL 9, address 0x5D, INT GPIO 4, reset on expander EXIO1.
- IO extension chip at I2C 0x24 (same bus): EXIO1 touch reset, EXIO2 backlight enable, EXIO4 SD CS, EXIO5 USB/CAN select (low = USB), EXIO6 LCD VDD enable. Also brightness and battery voltage; register protocol comes from the vendor demo.
- Native USB on GPIO 19/20 (shared with CAN, so EXIO5 must be low); second USB-C is a CH343 USB-to-UART bridge for flashing and logs.
- Battery: single 3.7 V cell on PH2.0, CS8501 charger.
