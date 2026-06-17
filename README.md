# Amaranth

A macOS menu‑bar app for controlling Aputure amaran lights over Bluetooth Mesh.

## What it is

- SwiftUI `MenuBarExtra` app
- Talks to the standard Bluetooth SIG Mesh proxy service (0x1828) via Nordic's open‑source `NordicMesh` library
- Bootstraps its mesh credentials (NetKey, AppKey, fixture list) by importing them from the amaran Desktop app's SQLite database on first launch, so the lights stay paired with the official apps
- Currently supports on/off (Generic OnOff), brightness (Light Lightness), and an experimental colour‑temperature slider (Light CTL Temperature)
- Ships with [Sentry](https://sentry.io) crash reporting and [Sparkle](https://sparkle-project.org) auto‑updates

## Requirements

- macOS 13 (Ventura) or newer
- Xcode 15 / Swift 5.9 or newer
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
just clean      # remove .build/ and release/
```

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
  Sources/Amaranth/
    AmaranthApp.swift    # @main, MenuBarExtra wiring, Sentry start
    Updater.swift        # Sparkle updater + "Check for Updates…"
    MenuView.swift       # the dropdown UI
    MeshController.swift # ObservableObject; bearer + send + status delegate
    MeshImporter.swift   # amaran.db -> SIG Mesh CDB JSON
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
- No Online Status (live state pushed by the proxy node) yet — we only refresh by polling `GenericOnOffGet` / `LightLightnessGet` on connect and on user request.
- Storage uses `~/Documents/MeshNetwork.json` (NordicMesh's default). Should move to `~/Library/Application Support/Amaranth/`.

## Other projects

https://github.com/aarondfrancis/amaran
https://github.com/wesbos/amaran-BLE-control
