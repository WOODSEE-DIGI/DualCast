# DualCast Permissions & Runtime Setup

This file explains what macOS permissions and Apple Developer capabilities are
required for DualCast, DualCast Switcher, the camera extension, and the audio
driver to work.

## Runtime permissions (user grants these on first use)

| App | Permission | Why | Trigger |
|-----|------------|-----|---------|
| **DualCast** | Screen Recording | Capture displays | `CGRequestScreenCaptureAccess()` on launch |
| **DualCast** | Camera | Capture FaceTime / USB webcams | `AVCaptureDevice.requestAccess(for: .video)` |
| **DualCast** | Microphone | Capture system audio | `NSMicrophoneUsageDescription` + audio capture |
| **DualCast Switcher** | Camera Extension | Activate virtual cameras | `OSSystemExtensionRequest` when you tap "Activate Cameras" |

## Apple Developer capabilities (must be enabled in the developer portal)

These are tied to the team ID `3BMZ2ULZ54` and bundle IDs already set in
`project.yml`.

| Capability | Required by | Bundle ID |
|------------|-------------|-----------|
| **App Groups** | Switcher + Camera Extension share source assignments | `com.woodseedigi.DualCastSwitcher` and `com.woodseedigi.DualCastSwitcher.CameraExtension` must both include `group.com.woodseedigi.DualCast` |
| **System Extension Install** | Switcher activates the camera extension | `com.woodseedigi.DualCastSwitcher` |

If these capabilities are not enabled in the portal, the app will build and
sign but the camera extension activation will fail at runtime.

## Code signing

Automatic signing is configured with team ID `3BMZ2ULZ54` in `project.yml`.
To build on a different Mac, that Mac must have a valid Apple Development
certificate for that team in Keychain Access.

## Audio driver installation

The audio driver is a traditional AudioServerPlugIn (HAL plugin), not a system
extension. It must be copied to `/Library/Audio/Plug-Ins/HAL` and `coreaudiod`
must be restarted. Use the provided script:

```bash
sudo ./scripts/install-audio-driver.sh
```

## Build everything

```bash
./scripts/build-all.sh
```

## Quick troubleshooting

- **"Camera extension failed to activate"** → Check that `System Extension
  Install` and `App Groups` capabilities are enabled for the Switcher App ID in
  the Apple Developer portal, and that the provisioning profile is up to date.
- **"DualCast Audio not appearing in Sound settings"** → Run
  `sudo ./scripts/install-audio-driver.sh` and check Console.app for
  `DualCastAudioDriver` logs.
- **"No NDI sources found"** → Verify screen recording/camera permission was
  granted and that the sender and receiver are on the same network/Tailscale
  tailnet.
