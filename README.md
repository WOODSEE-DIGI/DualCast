# DualCast

Dual-display NDI screen capture and switching for macOS — built for streaming
coding sessions (or anything else) from a two-Mac setup.

Two small apps, one repo:

| App | Runs on | What it does |
|---|---|---|
| **DualCast** | The Mac with the displays | Captures each display via ScreenCaptureKit and sends it as an independent NDI source (2560×1440 @ 30 fps by default). |
| **DualCast Switcher** | The streaming Mac | Receives both NDI sources and re-broadcasts the selected one as a **single** NDI source (`DualCast Active Display`) so your streaming software sees one stable camera. Switch inputs with global hotkeys — including from an Elgato Stream Deck. |

```
┌──────────────┐   2× NDI 1440p30   ┌───────────────────┐   1× NDI   ┌───────────┐
│   DualCast   │ ─────────────────► │ DualCast Switcher │ ─────────► │  Ecamm /  │
│ (coding Mac) │  Studio Display +  │  (streaming Mac)  │  selected  │ OBS / any │
│              │       BenQ         │   ⌃⌥⌘1 / ⌃⌥⌘2     │   source   │ NDI input │
└──────────────┘                    └───────────────────┘            └───────────┘
```

## Features

- Each display is a separate NDI source — zero-config discovery via mDNS
- Content-adaptive frame delivery: static screens use near-zero bandwidth
- Live previews, per-source fps/receiver stats, and LIVE/PREVIEW tally badges
- Switcher keeps both inputs at full bandwidth for **zero-latency switching**
- Global hotkeys (⌃⌥⌘1 = Slot A, ⌃⌥⌘2 = Slot B, ⌃⌥⌘3 = toggle) work while
  backgrounded and need no Accessibility permission
- libndi is bundled — no NDI runtime install required on either Mac

## Requirements

- macOS 14.0 or later, Apple Silicon or Intel
- Both Macs on the same (preferably gigabit, wired) network
- Screen Recording permission on the Mac running DualCast
- Any NDI-capable receiver: Ecamm Live, OBS + obs-ndi/DistroAV,
  NDI Studio Monitor, …

## Setup

1. **Coding Mac:** launch DualCast, grant screen recording when prompted,
   press **Start All**. Each display appears on the network as
   `YOURMAC (DualCast <Display Name>)`.
2. **Streaming Mac:** launch DualCast Switcher, assign Slot A/B to the two
   sources, press **Start** (auto-starts on later launches).
3. **Streaming software:** add `STREAMINGMAC (DualCast Active Display)` as
   your camera/NDI source — once. Switching happens upstream in the Switcher.
4. **Stream Deck (optional):** add the built-in **System → Hotkey** action
   with ⌃⌥⌘1 and ⌃⌥⌘2 on two keys. No plugin needed.

## Building from source

```sh
brew install xcodegen
xcodegen generate
xcodebuild -scheme DualCast -configuration Release build
xcodebuild -scheme DualCastSwitcher -configuration Release build
```

## License

PolyForm Noncommercial 1.0.0 — free for personal/noncommercial use.
See [LICENSE](LICENSE).

NDI® is a registered trademark of the Vizrt Group. This product bundles the
NDI runtime (see `Vendor/NDI/libndi_licenses.txt`) and is not affiliated with
or endorsed by Vizrt.
