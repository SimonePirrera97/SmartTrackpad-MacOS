# Smart Trackpad

Use an iPad as a wireless trackpad and app control panel for a Mac. The project contains a native iPad app, a macOS menu-bar companion, and shared Swift protocol and gesture modules.

The functional iPad phase passed the joint physical checklist on 2026-10-10, including the final Spotify/Finder controls and layout adjustments. Pinch now correctly zooms the Overleaf PDF preview in the latest physical test; the reason for the change is unknown. These results establish practical operation on the tested devices, not complete equivalence to Apple's built-in trackpad.

## Features

- Pointer movement, tap/double/triple click, two-finger right-click, hold-to-drag and optional three-finger drag.
- Two-axis scrolling, natural scrolling, adjustable speed and momentum, and pinch to zoom.
- Three-finger page navigation and interactive Mission Control opening, closing and reversal. Navigation and three-finger drag are mutually exclusive.
- A one-finger scrolling control panel that follows the active Mac app, with the app title pinned at the top and Show Desktop last.
- Copy/Cut/Paste/Undo/Redo; VS Code Save/Compile/Delete; Safari Save/New Tab/Close Tab. Safari's tab buttons sit together above Undo/Redo.
- Terminal replaces Undo/Redo with Delete Word and Enter. Finder replaces them with New Folder and Move to Trash. Spotify replaces editing controls with Play/Pause, Previous/Next and Volume Down/Up.
- Saved settings, input pause, automatic release on disconnect/background/sleep, and connection diagnostics.
- TLS-PSK pairing, nearby Mac discovery, optional QR/manual pairing and explicit Mac approval.
- Wired, Wi-Fi and Bluetooth LE connection choices. Wi-Fi/BLE have user-reported functional acceptance. The key-free wired revision failed the latest physical test; its USB discovery repair awaits retesting.
- Mac USB serial adapter for future dedicated-board firmware; the firmware is not implemented yet.

VS Code Compile sends the build-task shortcut; it requires a configured task or prompts you to select one. Finder deletion moves selected items to Trash. App controls target the active app and reject stale requests after app switches.

## Build and run

The included Xcode project targets iPadOS 17+ and macOS 14+. Development and build checks used Xcode 27.0. Run on a physical iPad and Mac to test touch and input behavior.

1. Open `SmartTrackpad.xcodeproj` in Xcode.
2. Choose your development team under Signing & Capabilities for both targets. Update bundle identifiers if required by your account.
3. Run the **MacTrackpadCompanion** scheme on **My Mac**. Open its mouse icon in the menu bar and grant Accessibility access through macOS settings when needed for input control.
4. Run **iPadTrackpad** on your iPad. Allow local-network access; camera access is only needed for QR pairing.
5. Choose **Wi-Fi** on the iPad. Start pairing in the Mac companion. Select the Mac under Nearby Macs on the iPad, enter the copied pairing key, compare the six-digit codes and approve on the Mac. Manual address/key and QR entry are also available.

Adjust pointer speed and gestures in the iPad settings. Scroll the right panel with one finger to reach app controls; use the main trackpad region for Mac input.

For unsigned compilation checks:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project SmartTrackpad.xcodeproj -scheme iPadTrackpad -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project SmartTrackpad.xcodeproj -scheme MacTrackpadCompanion -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Target configuration is in `project.yml`. The generated project is included, so [XcodeGen](https://github.com/yonaskolb/XcodeGen) is needed only when regenerating it after configuration changes:

```sh
xcodegen generate
```


## Alternative connections

The iPad Air 4 (USB-C, iPadOS 26.6.2) supports the APIs used here. The user previously reported all three routes working, including a plain iPad–Mac USB-C cable. The subsequent key-free wired revision failed on 2026-10-11; the current USB discovery repair is hardware-pending. Only one input session is accepted at a time; changing routes requires disconnecting first. New behavior below still needs physical acceptance.

**Wired (first/default tab):** Connect the iPad directly to the Mac using USB-C, unlock both devices and click **Start connections** on the Mac. Select the Mac in the iPad Wired tab and tap Connect. No pairing key, QR, security code, approval or TLS encryption is used. A separate `_stpad-usb._tcp` service listens only on link-local addresses on interfaces whose Mac hardware ancestry identifies a physically attached Apple iPad/iPhone USB device; generic wired LAN and Wi-Fi interfaces are excluded from this key-free mode. Session IDs, sequence checks, capability negotiation, heartbeat timeout, input pause and disconnect cleanup remain. The user explicitly chose to trust the direct cable; ordinary shared Ethernet is not treated as a private cable. The previously implemented encrypted path worked over the user's direct USB cable, correcting the earlier documentation's unsupported-cable assumption. The app does not change network settings or install a driver.

The cable service name was also shortened to `_stpad-usb._tcp` to satisfy the [DNS service-name length limit](https://www.rfc-editor.org/rfc/rfc6335.html#section-5.1). The 2026-10-11 repair enumerates attached USB interface addresses independently of the Mac's default/internet route. USB NCM links can exist while a route monitor reports only Wi-Fi; requiring an Ethernet-classified route previously prevented cable discovery. The iPad now searches only the cable Bonjour service, excludes Wi-Fi/cellular/loopback results, and pins service resolution and connection to the discovered interface. Wired availability comes from discovering that cable service rather than an internet-route check. USB still uses IP/Bonjour internally; it does not search the shared Wi-Fi network or fall back to a wireless connection. No USB-to-Ethernet adapters are required for the tested plain USB-C setup.

**Cable retest:** Start connections on Mac, plug in the USB-C cable and unlock both devices. Mac should show **Direct USB cable ready**. In the iPad Wired tab, select the Mac under **Mac on USB cable** and connect without a key/code. Turn off Wi-Fi and Bluetooth and verify the session still works in Finder/Overleaf. Unplug during a drag: input must release, the Mac must disappear from cable discovery, and replug/reconnect must work. If no Mac appears, record the Mac cable status and the iPad USB-discovery status. This checklist has not yet passed for the repaired implementation.

**Wi-Fi:** Both devices join the same network. Start connections on Mac, select the Mac on iPad, paste its pairing key, connect and approve the matching six-digit code. QR/manual pairing remains available. Guest networks may block discovery or device-to-device traffic. Wi-Fi always retains TLS-PSK and explicit approval.

**Bluetooth LE:** Start connections on Mac and enable **Allow Bluetooth LE pairing**. Choose Bluetooth LE on iPad, allow Bluetooth access, select the Mac, paste its current pairing key, connect and approve the matching code. Wi-Fi is not needed. BLE retains TLS-PSK and approval. Actual sustained throughput, latency and battery savings remain unmeasured.

Wi-Fi shows local-route availability; Wired shows cable-service discovery availability; BLE shows radio/permission availability. These checks do not guarantee a Mac is reachable. Wi-Fi/BLE provide **Open Settings** buttons using Apple's public app-settings URL. The public link opens Smart Trackpad's Settings page, not the system Wi-Fi/Bluetooth switches; the app provides directions to Settings → Wi-Fi or Settings → Bluetooth. See [Apple's Settings URL documentation](https://developer.apple.com/documentation/uikit/uiapplication/opensettingsurlstring).

**USB on the dedicated board:** The Mac companion's Dedicated board USB section lists `/dev/cu.usbmodem*` and `/dev/cu.usbserial*` ports. Select the board and open its port after closing other serial tools. This direct byte stream uses 115200 baud (native CDC may ignore baud) and the key-free session handshake below, with no TLS/code approval. Firmware must emit no console/debug text on this channel. Unplug, port closure or timeout releases input; reopen the port for the next session. Firmware, physical CDC enumeration and unplug behavior remain pending.

### Dedicated-board transport contract

The intended board is Waveshare ESP32-S3-Touch-LCD-7, subject to confirmation of the physical SKU/revision and touch variant. It is an Espressif board, not STM32. Its [manufacturer documentation](https://docs.waveshare.com/ESP32-S3-Touch-LCD-7) lists BLE, Wi-Fi, native USB and five-point capacitive touch. The non-touch and 7B models are different candidates.

- Wi-Fi: implement the current versioned, newline-framed JSON messages over TLS 1.2 PSK (`TLS_PSK_WITH_AES_128_GCM_SHA256`, identity `smart-trackpad-v2`, 32-byte key).
- BLE: Mac is the GATT peripheral; iPad/board is the central. Service UUID `ADCA1000-7D6D-4D46-ACF4-13F29B8A67E1`; central-to-Mac write-with-response characteristic `ADCA1001-7D6D-4D46-ACF4-13F29B8A67E1`; Mac-to-central notify characteristic `ADCA1002-7D6D-4D46-ACF4-13F29B8A67E1`. Subscribe before starting TLS. Characteristic values are ordered opaque TLS fragments, with no extra headers or JSON at the GATT layer. Respect negotiated ATT limits, allow one acknowledged write in flight, and handle notification backpressure. Implement TLS with a custom embedded byte-stream adapter; BLE bonding is not a substitute for application authentication.
- USB: expose a CDC byte stream on the board’s native USB port. Send a protocol-v2 `sessionRequest` with session UUID, sequence, monotonic timestamp and capabilities; omit `code`. Mac replies with `sessionAccept`, negotiated capabilities and optional preferences/app context. Subsequent input/heartbeat framing is unchanged. No TLS or pairing is used. This uses a different low-level adapter from iPad Ethernet. Keep the USB-to-UART debug port separate when using native CDC. No board USB Ethernet support is assumed.

The Apple BLE adapter forwards ciphertext through loopback-only local byte relays so the existing Network.framework TLS implementation remains the endpoint. Firmware needs its own wireless TLS/GATT and direct CDC adapters and a port of gesture behavior; Swift source and Apple frameworks do not transfer unchanged. Native USB CDC and BLE are firmware capabilities to implement and test, not functionality supplied by the factory demo. All routes reuse the existing Mac gesture backend; no HID mouse or keyboard fallback is introduced.

### Physical acceptance checklist

For each available route, record the route shown in connection status and Mac diagnostics:

1. For Wi-Fi/BLE, pair with the correct key and verify approval gating, rejection and wrong-key refusal. For Wired, verify there are no key/code fields and connection succeeds without approval.
2. In Finder/Safari/Overleaf, test pointer, clicks, hold-drag/text selection, scroll/flick, PDF-only pinch, page navigation, interactive Mission Control and contextual buttons.
3. Disconnect during a drag; verify release and reconnect. Repeat with iPad backgrounding, Mac sleep and Bluetooth switched off or Ethernet unplugged, as applicable.
4. For BLE, temporarily turn Wi-Fi off using device settings and verify input plus app-context updates still work. For wired use, verify diagnostics report Direct USB cable and unplugging does not fall back to Wi-Fi.
5. Use sustained rapid pointer/scroll movement for several minutes and assess lag, queued motion and connection loss. Compare against Wi-Fi on the same apps. Measure latency/jitter and whole-device power before choosing a preferred mode.

The user reported the previous transports working, then reported the key-free Wired revision failing. The current cable-discovery repair and unplug/reconnect checks remain pending; Waveshare firmware is unimplemented. No hardware/native parity claim follows from compilation or local relay tests.

## Next steps

The functional iPad phase is complete. Next priorities:

- [ ] **Connection robustness:** test home, public/guest and institutional Wi-Fi with client isolation, blocked Bonjour/multicast, firewalls, captive portals and VPNs. Test manual pairing separately from discovery; measure latency, loss, disconnect recovery and held-input cleanup. Document networks that prevent direct peer connections rather than promising universal support.
- [ ] **Bluetooth:** measure the user-tested encrypted BLE transport and compare latency, reliability, throughput and battery use with Wi-Fi.
- [ ] **Fast wired connection:** retest the repaired direct USB discovery, key-free handshake, unplug/replug and radio-off operation first; validate the Mac board-serial adapter separately. Measure latency/jitter and charging/data behavior.
- [ ] **Dedicated client:** the user has again named the Waveshare ESP32-S3 7-inch board. Confirm its exact SKU/revision, touch IDs/rate, USB and battery behavior before firmware work. If a separate STM32 board is intended, confirm its exact model and radio/USB capabilities.
- [ ] **Battery-first firmware:** set a measurable power budget and runtime target. Implement bounded allocation, event-driven touch handling, adaptive display refresh/backlight, radio scheduling, idle/sleep states and safe wake/reconnect. Measure current and latency in active, idle and sleep modes before optimizing the highest-cost components.

Keep transport adapters separate from portable gesture and session logic. Validate security and hardware behavior for each new transport and board increment before marking it complete.

## Project layout

- `apps/iPadTrackpad`: iPad interface and Apple touch adapters.
- `apps/MacTrackpadCompanion`: Mac interface, active-app detection and input adapters.
- `apps/Shared`: Apple network and pairing adapters.
- `packages/TrackpadProtocol`: bounded, capability-negotiated messages and fixed app controls.
- `packages/GestureCore`: portable gesture and input-state logic.

Apple adapters remain separate from the portable modules for a future dedicated touch-display client. Board firmware, distribution and general configurable profiles are future work. Some gesture delivery uses undocumented macOS event formats and may require maintenance across OS versions. No driver or system extension is installed.

This repository intentionally contains only compilation inputs, required assets and this README. Local plans, research, test tooling, build products and personal Xcode state are ignored. The Lucide asset license is retained in `assets/lucide/LICENSE`.
