# Smart Trackpad

Turn an iPad into a trackpad and app control panel for your Mac — over a USB-C cable, Wi-Fi or Bluetooth. A dedicated 7-inch touch-screen board can do the same job over USB.

It is two apps: **Smart Trackpad** on the iPad and **Smart Trackpad Companion**, a small menu-bar app on the Mac. Nothing is installed into macOS: no driver, no system extension.

## What you can do

| On the iPad | On the Mac |
|---|---|
| Slide one finger | Move the pointer |
| Tap · double tap · triple tap | Click · double click · triple click |
| Two-finger tap | Right-click |
| Hold one finger, then slide | Drag or select text |
| Two fingers | Scroll in any direction, with momentum |
| Pinch | Zoom |
| Three fingers left/right | Back / forward |
| Three fingers up/down | Mission Control, following your fingers |
| Three-finger drag *(optional, replaces the two gestures above)* | Drag |

A button panel on the right follows the app in front on your Mac:

- **Everywhere:** Copy, Cut, Paste, Undo, Redo, Show Desktop
- **VS Code:** Save, Compile, Delete
- **Safari:** Save, New Tab, Close Tab
- **Terminal:** Delete Word, Enter
- **Finder:** New Folder, Move to Trash
- **Spotify:** Play/Pause, Previous, Next, Volume

Scroll the panel with one finger if it does not fit.

## What you need

- An iPad with iPadOS 17 or later and a Mac with macOS 14 or later
- [Xcode](https://developer.apple.com/xcode/) and a free Apple ID, to install the apps yourself — they are not on the App Store

## Install

1. Open `SmartTrackpad.xcodeproj` in Xcode.
2. Select each of the two targets, open **Signing & Capabilities** and choose your team. If Xcode complains about the bundle identifier, change it to something unique.
3. Choose the **MacTrackpadCompanion** scheme, destination **My Mac**, and press Run. A mouse icon appears in the menu bar.
4. Click that icon. Under **Input permission**, open Accessibility settings and allow Smart Trackpad. Without this the Mac cannot be controlled.
5. Plug in the iPad, choose the **iPadTrackpad** scheme with your iPad as destination, and press Run. Allow local-network access when asked.

## Connect

Pick a tab at the top of the iPad app.

### Wired — simplest

1. Connect the iPad to the Mac with a USB-C cable and unlock both.
2. On the iPad, choose **Wired**.

That is all: the Mac connects by itself within a second or two. There is nothing to select and no key or code, because the cable itself is trusted. It works with Wi-Fi and Bluetooth switched off.

If you tap **Disconnect** on the iPad, tap **Connect** to go back in. If you end the session from the Mac, unplug and replug the cable.

### Wi-Fi

1. Put both devices on the same Wi-Fi network.
2. On the Mac, click **Start connections**, then **Copy pairing key**.
3. On the iPad, choose **Wi-Fi**, select your Mac, paste the key and tap **Connect**.
4. Check that the six-digit code is the same on both screens and click **Approve** on the Mac.

If your devices do not share a clipboard, turn on **Show QR code instead** on the Mac and tap **Scan Mac QR code** on the iPad.

### Bluetooth

1. On the Mac, click **Start connections** and turn on **Allow Bluetooth LE pairing**.
2. On the iPad, choose **Bluetooth LE**, allow Bluetooth access, select your Mac, paste the pairing key and tap **Connect**.
3. Compare the code and click **Approve** on the Mac.

Bluetooth needs no network at all.

## Settings

Tap **Settings** on the iPad to change pointer and scroll speed, scrolling direction, tap and hold timing, and to switch gestures on or off. **Use Mac click, drag and scroll settings** copies your Mac's own trackpad preferences.

On the Mac, the companion window lets you pause input control, switch off pinch, navigation or momentum, and adjust how long scrolling coasts.

## If something does not work

- **The pointer does not move.** Allow Smart Trackpad under System Settings → Privacy & Security → Accessibility, then click **Check again**. Make sure **Allow input control** is on.
- **The Mac does not appear over Wi-Fi.** Guest, hotel and many university or office networks block devices from seeing each other. Use the cable or Bluetooth instead, or open **Enter address and key manually** on the iPad.
- **The cable does not connect.** Unlock both devices and tap **Trust** on the iPad if asked. The Mac window shows what it sees: *No iPad or board connected by cable* means a cable or trust problem; *iPad on cable · open Smart Trackpad on it and choose Wired* means the iPad app is not waiting.
- **"Cannot connect" after pasting a key.** A new key is created every time connections are started on the Mac. Copy the current one.
- **Something is stuck.** Click **Release all input** in the companion window. Input is also released automatically when the iPad disconnects, goes to the background, or the Mac sleeps.

To report a problem, use **Copy connection diagnostics** in the iPad settings and **Copy diagnostics** in the Mac window.

## Privacy and safety

- Wi-Fi and Bluetooth connections are encrypted with a one-time key and must be approved on the Mac every time.
- The iPad sends pointer movements, gestures and button presses. It never sees your screen, documents or clipboard.
- The Mac only tells the iPad which of the supported apps is in front, to choose the buttons.
- Only one device can control the Mac at a time.

## Good to know

Smart Trackpad works well in everyday use, but it is not identical to Apple's built-in trackpad. Zoom and the three-finger gestures rely on undocumented macOS behavior and may need an update after a macOS upgrade. There is no Force Touch, haptic feedback, rotation, Launchpad or App Exposé gesture.

## Dedicated board (experimental)

Instead of an iPad you can use a [Waveshare ESP32-S3-Touch-LCD-7B](https://www.waveshare.com/esp32-s3-touch-lcd-7b.htm), a 7-inch touch screen with its own processor. It shows the same trackpad surface and the same button panel, and it talks to the same Mac companion.

- Plug the board's port marked **USB** into the Mac with a USB-C **data** cable. The companion finds it by itself; there is nothing to select or pair. A charge-only cable powers the screen but never connects.
- **Settings** and **Disconnect** are at the top of the button panel.
- **Wi-Fi (experimental):** while the board is on the cable, click **Remember this board** in the Mac window. Then, on the board, open Settings → Wireless, choose your network and type its password. From then on the board connects to that Mac by itself whenever the cable is unplugged and the Mac app is running, with no key and no approval. **Forget board** on the Mac, or **Forget Mac** on the board, undoes it.
- The cable always takes priority when it is plugged in. Bluetooth is not available on the board yet.
- On the board, Mission Control uses four fingers and three fingers drag.

Installing the firmware needs the ESP-IDF toolchain; see [`firmware/waveshare-esp32s3-7inch/README.md`](firmware/waveshare-esp32s3-7inch/README.md).

## For developers

```
apps/iPadTrackpad            iPad interface and touch handling
apps/MacTrackpadCompanion    Mac menu-bar app and input posting
apps/Shared                  Wi-Fi, Bluetooth and cable connections
packages/TrackpadProtocol    Messages exchanged between the devices
packages/GestureCore         Gesture recognition, independent of Apple frameworks
firmware/waveshare-esp32s3-7inch   Board firmware (ESP-IDF, C)
```

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen); run `xcodegen generate` after changing it or adding files.

## License

Smart Trackpad is licensed under **PolyForm Noncommercial 1.0.0** — see [LICENSE](LICENSE). Commercial use requires a separate license from the copyright holder. Third-party material keeps its own terms, including `assets/lucide/LICENSE`. The board firmware downloads LVGL, TinyUSB and Espressif components at build time; they are not part of this repository and keep their own MIT and Apache-2.0 licenses.
