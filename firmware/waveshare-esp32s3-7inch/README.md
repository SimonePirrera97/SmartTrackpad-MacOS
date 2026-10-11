# Smart Trackpad board firmware

A dedicated Smart Trackpad on the Waveshare **ESP32-S3-Touch-LCD-7B**: the same
trackpad surface and app control strip as the iPad app, talking to the same Mac
companion. Status: **running on the board over USB.** On 2026-10-11 the user confirmed the screen, automatic connection, pointer, scroll, pinch and the app buttons (not every gesture was tried). The settings screen, Disconnect and the larger buttons were flashed afterwards and still need a look.

## What exists

| Part | File | State |
|---|---|---|
| Gesture engine (C port of `packages/GestureCore`) | `components/trackpad_core/gesture.c` | Matches the shared golden traces on the desktop |
| Compact input encoding, command validity | `components/trackpad_core/protocol.c` | Matches the golden frame |
| Session: handshake, heartbeat, app context, timeouts | `components/trackpad_core/session.c` | Interoperates with the real Mac `ConnectionModel` in `scripts/check-board-session.swift` |
| Display, IO extension chip, GT911 multi-touch | `main/board.c` | Working on the board |
| Touch routing (pad → engine, strip → LVGL) | `main/touch.c` | Working on the board |
| Screen: pad, status, app control strip | `main/ui.c` | Working on the board |
| USB CDC session link | `main/usb_link.c` | Working on the board |
| Settings screen (saved in flash), Disconnect/Connect | `main/ui.c`, `main/main.c` | Flashed, not yet tried by the user |
| Key hand-over by cable ("Remember this board") | `session.c`, `main/main.c` | Checked against the real Mac code on the desktop; not yet tried on the board |
| Wi-Fi: network setup screen, TLS-PSK session with the board key | `main/wifi_link.c`, `main/ui.c` | Boots with Wi-Fi up; joining a network and the TLS session are untested |
| Bluetooth LE | — | Not started |
| Power management (dimming, sleep), battery level | — | Not started |

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

Route priority is USB, then Wi-Fi. Plugging the cable in takes a Wi-Fi session over.

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
2. The screen lights up with "Connect to your Mac" on the left and a dimmed button column on the right. Wrong colors, tearing or a blank screen point at `board.c` timings or the backlight/power expander pins.
3. Scroll the button column with one finger: it should move. That proves GT911 reading and the strip routing.
4. Plug the **USB** port into the Mac with the companion running. The Mac's cable status should read "Smart Trackpad board on USB · connecting", then the board shows "Connected to Mac · USB".
5. Pointer, tap, two-finger scroll, hold-drag, pinch, three-finger gestures, strip buttons following the front app.
6. Unplug: the Mac releases input; replug reconnects by itself.

## Design notes

- `trackpad_core` has no ESP-IDF or display dependency and must stay that way; it is the
  part checked against the iPad's behavior. When `packages/GestureCore` changes, change
  `gesture.c` in the same commit and keep the fixtures passing on both.
- Units: the engine works in 1000 units per shortest pad dimension as tuned on the iPad.
  `touch.c` uses 1.1 units per pixel so travel and tap/hold tolerances match per millimetre.
- Input is sent as it is sampled, with no client-side queue. That is fine on USB; Wi-Fi
  and BLE will need the bounded, coalescing queue the iPad has (`InputQueue.swift`).
- **Deliberate difference from the iPad (user request, 2026-10-11):** on the board
  Mission Control uses **four** fingers (`mission_fingers = 4`), so it can stay on beside
  three-finger drag, which is on by default. Page swipes still use three fingers and are
  exclusive with three-finger drag, so they start off. With `mission_fingers = 3` the C
  engine behaves exactly like `packages/GestureCore`; the golden traces run in that mode.
- The settings screen fits on one page in two columns on purpose: scrolling a full-screen
  panel redraws all 1024x600 pixels per frame and was visibly jerky.
- Disconnect makes the board leave the USB bus (`tud_disconnect`), so its serial port
  vanishes on the Mac and the companion stays free for an iPad. Connect rejoins.
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
