# Argus

Argus is a native macOS menu-bar utility with configurable CPU, memory, network,
storage, and battery widgets. Swap and load-average data appear inside the
relevant detail panels. It is implemented in Swift with AppKit and focused
SwiftUI views, with no web renderer, Node.js runtime, persistent helper process,
or third-party dependencies.

## Build

Requirements: macOS 13 or newer and Xcode 16 or newer.

CI separately compiles the application for its macOS 13 deployment target and
runs the test suites on the current hosted macOS test runtime.

```sh
xcodebuild \
  -project Metrics.xcodeproj \
  -scheme Metrics \
  -derivedDataPath .build \
  test
./Scripts/build-app.sh
open dist/Argus.app
```

The build script creates an ad-hoc-signed local app. Set `CODE_SIGN_IDENTITY` to
an Apple Developer ID certificate name to produce a hardened build that is ready
for notarization. Normal Gatekeeper distribution also requires notarizing and
stapling the app.

## Runtime design

- One coalescing configurable timer while menus are closed; two seconds by
  default.
- The open menu refreshes its summary and top-15 application ranking every
  second.
- Direct Mach host counters for CPU and memory.
- Memory details use resident internal-minus-purgeable pages for App Memory and
  the native free-page counter for Free.
- Direct routing-socket statistics for 64-bit per-interface network counters.
- CPU and memory application scans run only while their menu is open and use
  low-overhead `libproc` counters. Helper processes are grouped by their outer
  application bundle.
- Per-application network traffic is sampled with a one-second `nettop` process
  only while the Network menu is open; macOS has no supported public API for
  these counters.
- No continuously running worker queue or helper process while menus are closed.
- Disabled widgets skip their corresponding system query. Storage and battery
  values are cached for 30 seconds when enabled; disabled status items and
  popup views are not constructed.
- A lazy native Settings window controls widget visibility, background refresh
  cadence, and popup motion. New optional widgets default off.
- Status-bar labels update only when their rendered value changes.
- Network throughput uses a stable, centered received/sent readout in the status
  bar and equal-weight received/sent values in its popup summary.
- Local network identity and the optional public-IP result are invalidated when
  the active network path changes. Public-IP lookup providers are disclosed in
  Settings and can be disabled.
- Rank changes use short identity-preserving move/enter/exit transitions.
  Popup headline values use SwiftUI's native numeric content transition on
  macOS 14 and newer, with a static AppKit fallback on macOS 13. Menu animations
  stop when the menu closes; all transitions respect the macOS Reduce Motion
  setting.
