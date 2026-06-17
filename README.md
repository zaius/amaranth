# Amaranth

A macOS menu‑bar app for controlling Aputure amaran lights over Bluetooth Mesh.

## What it is

- SwiftUI `MenuBarExtra` app
- Talks to the standard Bluetooth SIG Mesh proxy service (0x1828) via Nordic's open‑source `NordicMesh` library
- Bootstraps its mesh credentials (NetKey, AppKey, fixture list) by importing them from the amaran Desktop app's SQLite database on first launch, so the lights stay paired with the official apps
- Currently supports on/off (Generic OnOff), brightness (Light Lightness), and an experimental colour‑temperature slider (Light CTL Temperature)

## Requirements

- macOS 13 (Ventura) or newer
- Xcode 15 / Swift 5.9 or newer
- The amaran Desktop app has already been used at least once on this Mac to pair the light into a mesh network

## Build

```sh
cd Amaranth
./build.sh           # release by default
./build.sh debug     # debug build
```

This produces `Amaranth.app` inside `.build/.../debug/` or `.build/.../release/`. The script ad‑hoc code‑signs it so the system can attach a Bluetooth permission entry.

## Run

```sh
open .build/arm64-apple-macosx/debug/Amaranth.app
```

On first launch you'll see a lightbulb glyph in the menu bar. Click it; macOS will ask for Bluetooth permission. Grant it from System Settings → Privacy & Security → Bluetooth, then re‑open the menu.

## Layout

```
Amaranth/
  Package.swift
  Info.plist
  build.sh
  Sources/Amaranth/
    AmaranthApp.swift    # @main, MenuBarExtra wiring
    MenuView.swift       # the dropdown UI
    MeshController.swift # ObservableObject; bearer + send + status delegate
    MeshImporter.swift   # amaran.db -> SIG Mesh CDB JSON
```

## Known limitations / TODO

- CCT slider currently sends a standard `Light CTL Temperature Set` (opcode 0x8264). The Verge's composition data does not expose a Light CTL Server, so it may ignore this message and we'll need to fall back to Telink's vendor command channel (model 0x0211/0x0000).
- No Online Status (live state pushed by the proxy node) yet — we only refresh by polling `GenericOnOffGet` / `LightLightnessGet` on connect and on user request.
- Storage uses `~/Documents/MeshNetwork.json` (NordicMesh's default). Should move to `~/Library/Application Support/Amaranth/`.
- The bundle is not sandboxed; entitlements aren't needed for personal use.

## Other projects

https://github.com/aarondfrancis/amaran
https://github.com/wesbos/amaran-BLE-control
