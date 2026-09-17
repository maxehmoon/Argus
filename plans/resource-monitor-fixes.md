Argus resource-monitor fixes — 17 September 2026

All 15 confirmed findings in the [original audit](resource-monitor-audit.md) are addressed. The existing native UI and MetricsCore structure are retained. The start-at-login feature remains in General settings.

| Audit finding | Resolution |
| --- | --- |
| 1. Process CPU units | Convert Mach tick deltas to nanoseconds with the cached system timebase. Keep application percentages normalised to whole-machine capacity in the UI. |
| 2. Overlapping CPU categories | Show ranked applications without adding overlapping kernel or synthetic residual rows. Application disk I/O likewise no longer subtracts unrelated physical-device totals. |
| 3. Duplicate network accounting | Sample one primary interface, selected from the IPv4 route or the IPv6 route when IPv4 has none. The UI labels this scope; external application rankings are separately labelled. |
| 4. Disk layers and device lifetime | Exclude file-backed and virtual block devices. Calculate deltas per stable registry ID before aggregation; seed new devices, discard removed devices and reset changed counters. Cache device classification, not activity readings. |
| 5. Energy semantics | Label application estimates as CPU power. All-zero lifetime energy counters produce an unavailable state; unchanged non-zero counters remain valid idle readings. |
| 6. Fabricated history | Draw only observed timestamps, including a dot for a single sample. Preserve missing samples and break gaps relative to the recorded sampling cadence. Secondary series retain their timestamp alignment. |
| 7. Collector lifetime and retry loop | Apply a minimum one-second iteration cadence even on immediate failure. Bound nettop to four seconds and 8 MiB output; cancellation kills and reaps the child. Missing, incomplete and malformed output is unavailable. |
| 8. Failure as zero | CPU, memory and rate measurements are optional. Warm-up, failed and stale reads display a dash and leave graph gaps. Failed rate reads reset their baseline; genuine zero activity remains zero. |
| 9. IPv6 and connection state | Accept IPv4 and IPv6 primary routes and local addresses. Connection status comes from NWPathMonitor independently of address availability. |
| 10. Battery decoding | Use external-power, charging and native charged flags. Display “Not Charging” without guessing the cause. Preserve zero current and signed-current power calculations. |
| 11. Motion controls | Gate graph scrolling, shimmer and transitions on panel visibility, the app preference and live Reduce Motion changes. Keep sampling active. |
| 12. Wi-Fi name permission | Add an explicit Settings action and macOS usage descriptions. Request authorisation only after that action; do not request location updates. Refresh network metadata after authorisation changes. |
| 13. Duplicate process scans | CPU, disk and CPU power share the recent process batch. Consecutive sampling reuses the previous endpoint; stale intervals and cancellation discard the pair. |
| 14. Verification | Add deterministic regression cases for units, counter/device lifetime, availability, IPv6 routes, battery flags/current, graph gaps, parser failures and command lifetime, plus a preference notification test. |
| 15. Documentation | Correct the storage menu-bar value and battery-history claim. Document measurement scopes, missing data, hardware-dependent telemetry and Wi-Fi permissions. |

Verification

- Debug build and all **43 tests passed**: 39 MetricsCore tests and 4 application preference tests.
- Universal **Release build passed** for arm64 and x86_64, with the application deployment target set to macOS 13.0.
- A live probe returned available CPU, memory, primary-interface throughput, physical-disk throughput, application CPU, application CPU power and application network readings after warm-up.
- A local 100-call warm sampler probe measured **0.141 ms median / 0.608 ms maximum** with all system options enabled. This measures collector latency on this Mac, not whole-app CPU consumption or energy use.
- Inspected the General settings UI: start-at-login and the optional Wi-Fi permission action are present. Neither system setting was changed during verification.
- `git diff --check` passed. Build output contained only the existing App Intents metadata and signed Sparkle stripping notices, with no Swift source warnings.

Limits

Intel and macOS 13 compatibility were compiled, not exercised on separate hardware. IPv6-only routing, VPN/device changes, counter failures and battery transitions have deterministic coverage but were not induced on the user's machine. Private temperature/frequency sensors remain hardware-dependent and uncalibrated; the audit found no validated arithmetic defect in those readers. Actual login launch, the macOS permission prompt, full discharge cycles and extended UI/energy profiling were not performed.

The application source and tests are updated in the working tree; no release was published and no installed application was replaced.
