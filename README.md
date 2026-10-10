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

VS Code Compile sends the build-task shortcut; it requires a configured task or prompts you to select one. Finder deletion moves selected items to Trash. App controls target the active app and reject stale requests after app switches.

## Build and run

The included Xcode project targets iPadOS 17+ and macOS 14+. Development and build checks used Xcode 27.0. Run on a physical iPad and Mac to test touch and input behavior.

1. Open `SmartTrackpad.xcodeproj` in Xcode.
2. Choose your development team under Signing & Capabilities for both targets. Update bundle identifiers if required by your account.
3. Run the **MacTrackpadCompanion** scheme on **My Mac**. Open its mouse icon in the menu bar and grant Accessibility access through macOS settings when needed for input control.
4. Run **iPadTrackpad** on your iPad. Allow local-network access; camera access is only needed for QR pairing.
5. Start pairing in the Mac companion. Select the Mac under Nearby Macs on the iPad, enter the copied pairing key, compare the six-digit codes and approve on the Mac. Manual address/key and QR entry are also available.

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

## Next steps

The functional iPad phase is complete. Next priorities:

- [ ] **Connection robustness:** test home, public/guest and institutional Wi-Fi with client isolation, blocked Bonjour/multicast, firewalls, captive portals and VPNs. Test manual pairing separately from discovery; measure latency, loss, disconnect recovery and held-input cleanup. Document networks that prevent direct peer connections rather than promising universal support.
- [ ] **Bluetooth:** prototype a paired Bluetooth transport and compare latency, reliability, throughput and battery use with Wi-Fi. Choose the transport from measurements; retain approval, authorization and safe disconnect behavior.
- [ ] **Fast wired connection:** evaluate a supported iPad–Mac cable path and an STM–Mac USB path separately. Measure latency and jitter, assess charging/data behavior, and document hardware/platform constraints before choosing an implementation.
- [ ] **STM client:** confirm the exact STM MCU/board, touchscreen/contact count, radio, USB capability, battery and display hardware. Reuse the Mac companion and portable gesture/protocol behavior; do not assume the earlier ESP32-S3 candidate applies to STM.
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
