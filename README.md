# Amaranth

A minimalist macOS menu‑bar app for controlling amaran lights.

<img width="482" height="253" alt="Screenshot 2026-06-18 at 3 42 08 PM" src="https://github.com/user-attachments/assets/4730026a-cc7d-419f-8d0d-15e40b8f39b3" />

## Demo
https://github.com/user-attachments/assets/af4c5a46-0e02-4f4a-9ca8-207739718523

## What it is

- SwiftUI `MenuBarExtra` app
- Talks to the standard Bluetooth SIG Mesh proxy service (0x1828) via Nordic's open‑source `NordicMesh` library
- Bootstraps its mesh credentials (NetKey, AppKey, fixture list) by importing them from the amaran Desktop app's SQLite database on first launch, so the lights stay paired with the official apps
- Currently supports on/off (Generic OnOff), brightness (Light Lightness), and an experimental colour‑temperature slider (Light CTL Temperature)
- Reads each fixture's **true** state back over the Telink vendor status channel, so the UI reflects changes made by another app or a physical control — not just what we last commanded
- Ships a **Control Center control** to toggle the light (macOS 26+; see below)
- Ships with [Sentry](https://sentry.io) crash reporting and [Sparkle](https://sparkle-project.org) auto‑updates

## Requirements

- macOS 26 (Tahoe) or newer (required by the Control Center control)
- Xcode 26 or newer
- Build tooling: [`xcodegen`](https://github.com/yonaskolb/XcodeGen), [`just`](https://github.com/casey/just), and (for releases) [`create-dmg`](https://github.com/sindresorhus/create-dmg)
  ```sh
  brew install xcodegen just
  npm install -g create-dmg @sentry/cli
  ```
- The amaran Desktop app has already been used at least once on this Mac to pair the light into a mesh network

## Build & run

The Xcode project is generated from `project.yml` by XcodeGen — it isn't checked in.

```sh
just            # generate the project, build (Debug), and (re)launch the app
just build      # generate + build only
just generate   # just regenerate Amaranth.xcodeproj
just reset-controls  # reset Control Center's cache if the control gets wedged
just clean      # remove .build/ and release/
```

## Control Center control

A WidgetKit control extension (`AmaranthControl.appex`, embedded in the app)
toggles the light from Control Center on macOS 26+. The extension never touches
Bluetooth — only one process can hold the mesh proxy, and the menu‑bar agent
already does. They share state through an App Group container
(`P9U2E575US.group.so.kel.Amaranth`): the agent publishes the fixture roster +
on/off state and calls `ControlCenter.reloadControls`; tapping the control runs
`ToggleLightIntent` in the extension's background process, which writes a one‑shot
command + fires a Darwin notification, and `ControlBridge` in the agent applies it
over the live bearer.

**Gotchas worth not re‑discovering:**

- **Exactly one registered copy of the app must exist.** If two bundles claim
  `so.kel.Amaranth`, LaunchServices/`linkd` can't resolve which owns the App Intents and
  control taps silently do nothing** (no icon, no dispatch). If the control wedges
  (usually after changing its structure), reset its Control Center cache and re‑add the
  control:
  ```sh
  just reset-controls   # = rm -rf ~/Library/Containers/so.kel.Amaranth.Control && killall ControlCenter chronod
  ```
- **It's a `ControlWidgetButton`, not a `ControlWidgetToggle`.** A `SetValueIntent` on a
  toggle doesn't reliably dispatch here (its `value` never resolves). The button reads
  the current state and sends the opposite; the value provider drives the bulb icon so
  it still reflects on/off.
- **Proxy filter is set to reject‑list ("forward everything"), not accept‑list.**
  `MeshController` used to `add` the Verge's reply addresses to the proxy accept list,
  but the Verge reports a smaller filter size than requested, making NordicMesh's
  `ProxyFilter` compute a negative `prefix` length and trap — crashing the whole agent
  on connect. See `proxyDidConnect`.

## Layout

```
amaranth/
  project.yml              # XcodeGen project definition (targets, deps, signing)
  Info.plist               # bundle info + Sparkle feed/key
  ExportOptions.plist      # Developer ID export config for releases
  justfile                 # build / run / package / release recipes
  Resources/AppIcon.icns   # app icon (regen with scripts/make-icon.swift)
  scripts/make-icon.swift  # renders the icon
  .github/workflows/release.yml
  Amaranth.entitlements    # App Group entitlement (shared container)
  Control/                 # control extension Info.plist + entitlements
  Sources/Amaranth/
    AmaranthApp.swift    # @main, MenuBarExtra wiring, Sentry start
    Updater.swift        # Sparkle updater + "Check for Updates…"
    MenuView.swift       # the dropdown UI
    MeshController.swift # ObservableObject; bearer + send + status delegate
    MeshImporter.swift   # amaran.db -> SIG Mesh CDB JSON
    ControlBridge.swift  # applies Control Center toggle commands to the mesh
  Sources/Shared/        # compiled into BOTH the app and the control extension
    SharedStore.swift    # App Group container IPC: roster / state / command
  Sources/AmaranthControl/   # the Control Center control extension
    LightToggleControl.swift # ControlWidget + on/off value provider
    Intents.swift            # ToggleLightIntent
```

## Releasing

Releases are cut by pushing a version tag. GitHub Actions
(`.github/workflows/release.yml`) then builds, signs, notarizes, staples,
packages a DMG, attaches it to a GitHub Release, and publishes the Sparkle
appcast to GitHub Pages. The same build/package steps are in `just package`,
so you can produce a notarized DMG locally too.

```sh
just release 0.2.0     # bump project.yml, commit, tag v0.2.0, push → CI does the rest
# or, by hand:
git tag v0.2.0 && git push origin v0.2.0
```

- **Versioning** — `MARKETING_VERSION` (the X.Y.Z from the tag) becomes
  `CFBundleShortVersionString`; `CFBundleVersion` is the git commit count (a
  monotonic integer Sparkle uses to decide what's newer). The short git SHA is
  baked into the bundle (`GitCommit`) and attached to Sentry events.
- **Downloads** — the DMG lives on the GitHub Release
  (`…/releases/download/vX.Y.Z/Amaranth-X.Y.Z.dmg`); `appcast.xml` is served
  from GitHub Pages at the `SUFeedURL` in `Info.plist`.

### One‑time setup

1. **GitHub Pages** — repo *Settings → Pages → Build and deployment → Source:
   GitHub Actions*. The appcast deploys to `https://zaius.github.io/amaranth/appcast.xml`
   (this is the `SUFeedURL` in `Info.plist` — update both if the repo moves).

2. **Notary keychain profile** (for building/notarizing locally with `just package`):
   ```sh
   xcrun notarytool store-credentials amaranth-notary \
     --apple-id david@kel.so --team-id P9U2E575US
   ```
   Use an [app‑specific password](https://account.apple.com) (Sign‑In and
   Security → App‑Specific Passwords). You can reuse the same app‑specific
   password as other apps under this team.

3. **Repository secrets** (*Settings → Secrets and variables → Actions → Secrets*):

   | Secret | Value |
   | --- | --- |
   | `DEVELOPER_ID_CERT_P12_BASE64` | `base64 -i DeveloperID.p12` of your exported *Developer ID Application* cert |
   | `DEVELOPER_ID_CERT_PASSWORD` | password set when exporting that `.p12` |
   | `KEYCHAIN_PASSWORD` | any throwaway string (used for the CI keychain) |
   | `NOTARY_APPLE_ID` | `david@kel.so` |
   | `NOTARY_TEAM_ID` | `P9U2E575US` |
   | `NOTARY_PASSWORD` | the app‑specific password from step 2 |
   | `SPARKLE_PRIVATE_KEY` | the Sparkle EdDSA private key (see below) |
   | `SENTRY_AUTH_TOKEN` | *(optional)* token (org `kelso`, scope `project:releases`) to upload dSYMs |
   | `SENTRY_ORG` | *(optional)* `kelso` — only used if `SENTRY_AUTH_TOKEN` is set |
   | `SENTRY_PROJECT` | *(optional)* `amaranth-macos` — only used if `SENTRY_AUTH_TOKEN` is set |

   The Sentry upload is best-effort: if any of these are wrong, the build logs a
   warning and still ships the release. (`SENTRY_ORG`/`SENTRY_PROJECT` must be the
   slugs, not the numeric IDs from the DSN.)

4. **Sparkle keys** — already generated for this repo. The public key is in
   `Info.plist` (`SUPublicEDKey`); the matching private key is in your login
   keychain under the `amaranth` account. To re‑export it for the
   `SPARKLE_PRIVATE_KEY` secret:
   ```sh
   .build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account amaranth -x key.txt
   ```

## Known limitations / TODO

- CCT slider currently sends a standard `Light CTL Temperature Set` (opcode 0x8264). The Verge's composition data does not expose a Light CTL Server, so it may ignore this message and we'll need to fall back to Telink's vendor command channel (model 0x0211/0x0000).
- Storage uses `~/Documents/MeshNetwork.json` (NordicMesh's default). Should move to `~/Library/Application Support/Amaranth/`.

## Reading live state

We *do* read the light's true state, over the Telink vendor status channel
(the SIG Generic OnOff Server is useless — `GenericOnOffGet` always reports
"on"). `MeshController` sends a vendor **status request** (opcode 0x26,
sub‑opcode 0x0E) on connect, every 10 s, and ~200 ms after each on/off command;
the fixture replies with a 0x26 **status report** carrying real on/off
(`(low64 >> 8) & 1`), brightness, and CCT (sub‑opcode 0x02) or HSI (0x01). The
decode (`AputureVendorMessage.decodeStatus`) is cross‑checked against the two
reimplementations linked below — aarondfrancis/amaran (`decodePacket`) and
wesbos/amaran‑BLE‑control (`decodeStatus`).

The catch (documented thoroughly by wesbos): fixtures address every status
reply to the *official app's* provisioner unicast `0x0001`, never to whoever
asked. We receive them anyway because the proxy filter is set to forward
everything (see `proxyDidConnect`), and — unlike the ESP‑IDF stack wesbos had
to patch — NordicMesh delivers messages to the **global** `MeshNetworkDelegate`
regardless of destination (the destination filter only gates per‑model
callbacks). So `handle(message:source:)` sees the `0x26` report as an
`UnknownMessage` and decodes it; no library patch needed.

## Other projects

https://github.com/aarondfrancis/amaran
https://github.com/wesbos/amaran-BLE-control
