<p align="center">
  <img src="appicon.png" width="128" height="128" alt="MacFanControl icon">
</p>

<h1 align="center">MacFanControl</h1>

<p align="center">
  A native macOS menu bar app for monitoring temperatures and controlling fan speeds on Apple Silicon Macs.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/chip-Apple%20Silicon-orange" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/swift-6.0-F05138" alt="Swift 6.0">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

---

## Features

- **Real-time monitoring** — Reads 400+ SMC temperature sensors and fan RPM directly, no kernel extensions required
- **Menu bar integration** — Lives in the menu bar with a compact status dropdown; Dock icon only appears when the dashboard is open
- **Manual fan control** — Set custom RPM, full speed, or auto per fan via a privileged helper daemon
- **Temperature-based profiles** — Create named profiles with rules like "if sensor X reaches Y degrees, set fan Z to W rpm"
  - Hysteresis with 3°C deadband prevents rapid toggling
  - Highest RPM wins when multiple rules target the same fan
  - Fans return to auto when no rules trigger
- **Safe by design**
  - Read-only monitoring requires no privileges
  - Fan writes go through a separate privileged helper with a 10-second watchdog — if the app crashes, fans revert to auto
  - RPM values are double-clamped (evaluator + helper)
  - Taking fan control is an explicit, acknowledged action

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon Mac (M1 / M2 / M3 / M4 / M5 series)

## Installation

1. Download `MacFanControl-vX.X.X.zip` from [Releases](../../releases)
2. Unzip and move `MacFanControl.app` to `/Applications/`
3. Launch the app (right-click → Open on first launch since it's ad-hoc signed)
4. Click **"Install helper"** in the status bar when prompted — this installs the privileged daemon needed for fan control

Temperature monitoring works immediately. Fan control becomes available after the helper is installed.

## Building from Source

Requires the Swift toolchain (`/usr/bin/swift`), no Xcode needed.

```bash
bash scripts/build.sh
```

The app bundle is assembled at `build/MacFanControl.app`.

Helper install/uninstall scripts are available in `scripts/` for development, but normal users don't need them — the app handles installation via its UI.

## Usage

1. **Monitor** — The dashboard shows all detected temperature sensors and fan speeds. No privileges needed.
2. **Take fan control** — Click "Take fan control..." in the dashboard or menu bar. This activates the privileged helper.
3. **Manual control** — Use the slider to set a custom RPM, or click "Full speed" / "Auto" per fan.
4. **Profiles** — Create temperature-based profiles that automatically adjust fan speeds:
   - Select a profile from the dropdown in the Fans panel or the menu bar "Profiles" submenu
   - Each rule maps a sensor threshold to a target RPM for a specific fan
   - Profiles are persisted to `~/Library/Application Support/MacFanControl/profiles.json`

## Architecture

```
┌─────────────────────┐     ┌──────────────────────────┐
│  MacFanControlApp   │     │  MacFanControlHelper     │
│  (SwiftUI GUI)      │────▶│  (launchd root daemon)   │
│                     │ XPC │                          │
│  • SMC reads (user) │     │  • SMC writes (root)     │
│  • Profile engine   │     │  • 300ms reconciliation   │
│  • Menu bar extra   │     │  • 10s watchdog           │
└─────────────────────┘     └──────────────────────────┘
         │                              │
         └──────────┬───────────────────┘
                    ▼
            ┌──────────────┐
            │  AppleSMC    │
            │  (IOKit)     │
            └──────────────┘
```

- **MacFanControlCore** — Shared library: SMC access (via C shim), fan/sensor readers, protocol definitions, profile evaluator
- **MacFanControlApp** — SwiftUI app with menu bar extra, dashboard, profile editor
- **MacFanControlHelper** — Privileged launchd daemon for fan writes, communicates via `NSXPCConnection`
- **SMCShim** — Minimal C target wrapping IOKit's `SMCKeyData_t` struct

## Apple Silicon SMC Notes

On M-series Macs, the SMC driver has specific behaviors:

- Fan RPM keys use `flt` type (IEEE 754 float), not the `fpe2` format from Intel Macs
- Writing `F0md=1` (manual mode) triggers a **session-scoped latch** — auto-mode reads become degraded until reboot
- `thermalmonitord` clobbers `F0Tg` every ~1.4 seconds, so the helper uses a 300ms reconciliation loop to maintain custom targets
- Reads work as a normal user; writes require root

## License

MIT
