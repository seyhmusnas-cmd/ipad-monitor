# ipad-monitor

Turn an old iPad that no longer gets updates into a **USB touchscreen second monitor for your Mac**.

The first-generation iPad mini stopped at iOS 9.3. Sidecar, Duet and friends no longer support it, and current Xcode can't even build apps for it. This project brings it back to life:

- 🖥 **A real second display.** macOS sees a new 1024×768 "iPad mini" monitor. Drag windows onto it, arrange it next to your main display.
- 🔌 **USB, no Wi-Fi needed.** Video goes over the Lightning cable through `usbmuxd`, and the iPad charges while you use it.
- 🎞 **Hardware H.264 both ways.** The Mac encodes with VideoToolbox; the iPad's A5 chip decodes in hardware. ~30 fps at a few KB per frame.
- 👆 **Touch control.** Tap to click, drag, two-finger scroll, two-finger tap to right-click.
- 📍 **Menu bar app.** MonitorHost lives in the menu bar, starts at login and reconnects on its own.

Tested on an **iPad mini (1st gen, iPad2,7) running iOS 9.3.6** with a Mac mini (Apple Silicon) on **macOS 27 and Xcode 27**.

## How it works

```
 Mac                                                        iPad (iOS 9, armv7)
 ┌──────────────────────────────────────────────┐           ┌──────────────────────────────┐
 │ CGVirtualDisplay "iPad mini" 1024×768        │           │ Monitor.app                  │
 │   → ScreenCaptureKit (only changed frames)   │   USB     │   ← TCP :2345 (loopback)     │
 │   → VideoToolbox H.264                       │ ───────►  │   → AVSampleBufferDisplay-   │
 │   → usbmuxd tunnel to iPad port 2345         │ usbmuxd   │     Layer (hardware decode)  │
 │                                              │           │                              │
 │ CGEvent mouse clicks / drags / scrolls   ◄───┼───────────┼── touch gestures + acks      │
 └──────────────────────────────────────────────┘           └──────────────────────────────┘
```

- Frames are only encoded after the iPad acknowledges the previous one, and anything captured in between is dropped *before* encoding. Latency never builds up and the H.264 stream stays valid.
- When the screen goes idle for 0.3 s, the last frame is resent as a high-quality key frame, so text that got soft while scrolling becomes crisp again.
- The iPad app only listens on the loopback interface, so it can't be reached over Wi-Fi, only through the USB tunnel.

## What you need

- A Mac with macOS 14 or later and Xcode. Tested on Apple Silicon; Intel Macs should work but haven't been tried.
- An old iPad and its USB cable. Tested only on the iPad mini 1; other 32-bit iPads stuck on iOS 9 or 10 (iPad 2, 3, 4) should work the same way but haven't been tried. 64-bit iPads on iOS 11 or later can't run this build as is, because it's 32-bit only.
- An **Apple Developer account**. Tested with a paid account, where the provisioning profile lasts a year. Free accounts haven't been tried.

## Setup

### 1. Get the iOS 9.3 SDK

```bash
./scripts/fetch-sdk.sh
```

This downloads `iPhoneOS9.3.sdk` (~56 MB, headers and `.tbd` stubs only) from [theos/sdks](https://github.com/theos/sdks) into `vendor/` and patches a copy so today's linker accepts it. It isn't part of this repo because it contains Apple's files.

### 2. Build the install tool and find your iPad's UDID

```bash
./tools/build.sh
```

Plug in the iPad, unlock it and tap **Trust** if it asks. Then:

```bash
./tools/mdinstall list
```

```
0a1b2c3d4e5f…  [USB]  My iPad  iPad2,7  iOS 9.3.6
```

Xcode's own device tools can't talk to iOS 9 devices anymore, so `mdinstall` uses macOS's MobileDevice framework directly. It can also show the device's live log (`mdinstall syslog - 30`) and download crash reports (`mdinstall crashes - Monitor ./out`).

### 3. Create a provisioning profile

On [developer.apple.com](https://developer.apple.com/account/resources):

1. **Devices → +**: register the iPad with the UDID from step 2.
2. **Identifiers → + → App IDs → App**: create an explicit Bundle ID, e.g. `com.yourname.ipadmonitor`. No capabilities needed.
3. **Profiles → + → iOS App Development**: pick that App ID, your Apple Development certificate and the iPad. Download it into the `ipad/` folder. `*.mobileprovision` files are git-ignored because they contain your UDIDs and team ID.

### 4. Build and install the iPad app

```bash
./ipad/build.sh ipad/YourProfile.mobileprovision install
```

The bundle ID comes from the profile, and the signing certificate is picked automatically from the ones in the profile that are in your keychain. A **Monitor** icon appears on the iPad.

### 5. Install MonitorHost on the Mac

```bash
./mac/build.sh install
```

This installs `~/Applications/MonitorHost.app`, starts it and registers it to open at login. macOS then asks for two permissions:

- **Screen Recording**: needed to capture the virtual display. Relaunch MonitorHost from its menu after allowing it.
- **Accessibility**: needed to turn touches into clicks.

If you have no Apple Development certificate, the app is ad-hoc signed, and macOS will forget these permissions every time you rebuild it.

### 6. Use it

Open **Monitor** on the iPad. Within a second it shows the new display. Arrange it in **System Settings → Displays**, or use **Display Settings…** in the menu bar.

## Using it

| On the iPad | On the Mac |
|---|---|
| Tap | Click (tap twice quickly to double-click) |
| Drag with one finger | Click and drag: move windows, select text |
| Drag with two fingers | Scroll |
| Tap with two fingers | Right click |

The MonitorHost menu shows the connection status and frame rate, and has:

- **Resolution**: 1024×768 (1:1 on the iPad), 1280×960 or 1600×1200 (more room, smaller text).
- **Display Settings…**
- **Open at Login**
- **Show Log**: `~/Library/Logs/MonitorHost.log`
- Shortcuts to grant any permission that's missing.

### Environment variables

For running `MonitorHost.app/Contents/MacOS/MonitorHost` by hand:

| Variable | Effect |
|---|---|
| `MONITOR_UDID=<udid>` | Only use this device (default: the first USB device with the app open) |
| `MONITOR_BITRATE=10` | H.264 bit rate in Mbit/s (default 6) |
| `MONITOR_CODEC=jpeg` | Use JPEG instead of H.264 |
| `MONITOR_MIRROR=1` | Mirror the main display instead of creating a virtual one |
| `MONITOR_BENCH=1` | Benchmark: keep sending frames even when nothing changes |

## Performance

Measured on the iPad mini 1 over USB at 1024×768:

| | JPEG | H.264 |
|---|---|---|
| Frame rate while scrolling | ~22 fps (the iPad's ceiling) | 18–29 fps (capture is capped at 30) |
| Data per frame | 90–117 KB | 3–16 KB |
| USB traffic | ~2 MB/s | 0.1–0.3 MB/s |
| Mac CPU | ~10% | ~1.5% |

With JPEG, decoding on the A5's CPU is the bottleneck (~45 ms per frame). With H.264 the decoder is hardware, and even a worst-case stream where every frame is a 300–600 KB key frame still runs at 23–39 fps.

## Troubleshooting

- **"Monitor app isn't open on the iPad".** The app has to be in the foreground. Installing a new build also closes it.
- **The app opens and closes right away.** Usually the provisioning profile or certificate has expired (after a year with a paid account). Make a new profile and run step 4 again. `./tools/mdinstall syslog - 30` shows the reason while you tap the app.
- **The connection drops and the iPad logs `Auth fail` for the cable.** iOS 9 doesn't recognize the authentication chip in some newer Lightning cables and adapters. An older USB-A to Lightning cable is the safest choice.
- **Touches do nothing.** Allow MonitorHost under **System Settings → Privacy & Security → Accessibility**. The menu shows a shortcut when it's missing.

## Notes for the curious

Building for iOS 9 with Xcode 27 needed a few workarounds:

- **No armv7 in the SDK.** Current clang still compiles armv7, but the bundled iOS SDK has no armv7 stubs. The iOS 9.3 SDK fills the gap. Its `.tbd` files list `i386`/`x86_64` next to the ARM architectures, which makes the new linker think they're Simulator libraries, so `fetch-sdk.sh` strips those entries.
- **SIGILL on launch.** The new linker doesn't set the low bit that marks the entry point as Thumb code, so the CPU jumps into Thumb code in ARM mode. Building with `-marm` avoids Thumb entirely; the A5 runs ARM code fine.
- **Installing.** CoreDevice (`devicectl`) reports pairing as "unsupported" for iOS 9 devices, so `mdinstall` uses the classic `AMDeviceSecureTransferPath` / `AMDeviceSecureInstallApplication` calls.
- **Virtual display.** `CGVirtualDisplay` is an undocumented CoreGraphics API, also used by BetterDisplay and Chromium. A future macOS could break it. If it does, MonitorHost falls back to mirroring the main display, and an HDMI dummy plug is a hardware alternative.

## Credits

- [theos/sdks](https://github.com/theos/sdks) for the iOS 9.3 SDK.
- Chromium's `virtual_display_mac_util.mm` for the `CGVirtualDisplay` declarations.
- [ios-deploy](https://github.com/ios-control/ios-deploy) and [libimobiledevice](https://libimobiledevice.org) for documenting the MobileDevice and usbmuxd protocols.

## License

[MIT](LICENSE)
