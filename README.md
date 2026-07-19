<p align="center">
  <img src="Resources/AppIcon-source.png" width="144" alt="Argus app icon">
</p>

<h1 align="center">Argus</h1>

<p align="center">
  Native, lightweight system monitoring for your Mac menu bar.
</p>

<p align="center">
  <code>macOS 13+</code>&nbsp;&nbsp;·&nbsp;&nbsp;<code>Swift 6</code>&nbsp;&nbsp;·&nbsp;&nbsp;<code>AppKit + SwiftUI</code>&nbsp;&nbsp;·&nbsp;&nbsp;<code>No third-party dependencies</code>
</p>

Argus keeps the stats you care about visible without turning system monitoring
into a system burden. Enable only the widgets you want, glance at live values in
the menu bar, and open a focused native panel when you need the detail.

Named after the many-eyed watchman of Greek mythology, Argus is designed to be
quiet, observant, and always close at hand.

## Highlights

- **Five focused widgets:** CPU, memory, network, storage, and battery.
- **Live history:** Smooth graphs with configurable 30-second, 1-minute,
  3-minute, and 5-minute windows.
- **Top applications:** See the processes using the most CPU, memory, network,
  disk activity, or energy.
- **Useful detail:** CPU temperature and speed, memory composition, network
  identity, disk capacity, battery health, power state, and more.
- **Native throughout:** Built with AppKit and focused SwiftUI views, with no Electron,
  browser engine, Node.js runtime, or third-party packages.
- **Made for macOS:** SF Symbols, native menus, system materials, keyboard
  shortcuts, persistent settings, and full Reduce Motion support.

## Widgets

| Widget | Menu-bar glance | Open-panel detail |
| --- | --- | --- |
| **CPU** | Overall usage | History, temperature, processor speed, load averages, uptime, and top applications |
| **Memory** | Memory usage | History, pressure, app/wired/compressed/free memory, swap, and top applications |
| **Network** | Received and sent rates | Traffic history, connection and interface details, local/public IP, totals, and top applications |
| **Storage** | Read and write activity | Activity history, volume usage and capacity, and top applications |
| **Battery** | Charge and charging state | Charge history, time remaining, health, power information, and top energy users |

Open Settings with <kbd>⌘</kbd><kbd>,</kbd> to choose widgets, sampling cadence,
graph duration, animation preferences, and whether public-IP information is
shown.

## Lightweight by design

Argus avoids doing expensive work until it can provide useful information:

- A single configurable timer updates enabled menu-bar widgets every 1, 2, or
  5 seconds.
- Disabled widgets skip their corresponding system queries.
- Application rankings are sampled only while their panel is open.
- Network process traffic uses a short-lived `nettop` sample only while the
  Network panel is open.
- CPU and memory data come from native Mach and `libproc` counters.
- There is no persistent helper process, web renderer, or continuously running
  worker queue.

Open panels update once per second. Their animations stop when closed, and
rendered menu-bar values update only when their displayed text changes.

## Privacy

System statistics and preferences stay on your Mac. Argus contains no analytics,
advertising, tracking, or user-data collection.

Public IP and country lookup is optional and can be disabled in Settings. When
enabled, Argus contacts `ipwho.is`; `country.is` and `ipify.org` are fallback
providers. Per-application network traffic is read locally using macOS's
`nettop` utility.

## Build from source

### Requirements

- macOS 13 Ventura or newer
- Xcode 16 or newer

```sh
git clone https://github.com/maxehmoon/Argus.git
cd Argus
./Scripts/build-app.sh
open dist/Argus.app
```

The script creates a universal Release build at `dist/Argus.app` and signs it
ad hoc for local use.

Run the test suite with:

```sh
xcodebuild \
  -project Metrics.xcodeproj \
  -scheme Metrics \
  -destination 'platform=macOS' \
  test
```

### Distribution signing

To create a hardened build with a Developer ID certificate:

```sh
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  ./Scripts/build-app.sh
```

Public distribution outside the Mac App Store also requires Apple notarization
and stapling before release.

## Project structure

```text
Sources/Metrics/       Menu-bar UI, settings, and AppKit/SwiftUI views
Sources/MetricsCore/   Native samplers, formatters, and process ranking
Tests/                 Unit tests for sampling, formatting, and preferences
Resources/             App metadata, privacy manifest, and icon assets
Scripts/               Local build and signing workflow
```
