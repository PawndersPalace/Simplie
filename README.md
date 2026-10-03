# Simplie

A lightweight macOS menu bar system monitor for battery, memory, storage, uptime, active processes, and VPN controls.

## Build and launch

Requires macOS 13 or later and the Swift toolchain.

```sh
./build-app.sh
open dist/Simplie.app
```

The menu bar item shows the battery percentage when available. Simplie supports direct connection controls and location selection for ExpressVPN and Mullvad when their command-line tools are installed, and connect/disconnect for Cloudflare WARP. It detects installed common VPN apps; providers without a supported control interface can be opened from Simplie, but their connection and location controls remain in their own app. macOS-configured VPN profiles are also listed when present.