Argus resource-monitor audit — 17 September 2026

Original audit of commit `1126706`. Application source was not modified during that audit. This report covers all five resource monitors, their display paths, preferences, tests, and a lighter review of build/release configuration. Findings and line references below describe that baseline. All 15 confirmed findings have since been addressed; see the [fixes and verification record](resource-monitor-fixes.md).

Several readings are materially inaccurate. Retain the native AppKit/SwiftUI application and the MetricsCore boundary, but repair the measurement contracts before undertaking larger structural changes.

| Monitor | Verdict |
| --- | --- |
| CPU utilisation | Host tick-delta arithmetic and rollover handling look sound. Per-application percentages are wrong on non-1:1 Mach timebases, and the displayed source categories overlap. |
| CPU temperature and frequency | Returned plausible values on the local Apple Silicon Mac. Temperature is the maximum valid candidate sensor; frequency is an active-residency-weighted value across recognised CPU complexes. Neither is independently calibrated. Private sensor layouts and Intel coverage remain limitations. |
| Memory | No confirmed arithmetic defect in the host app/wired/compressed calculation, pressure mapping, swap reading or process-footprint ranking. These are different accounting scopes and should not be expected to sum exactly. Failed host reads are incorrectly represented as zero. |
| Network | Individual interface deltas use the correct clock conversion and handle counter decreases. Aggregation mixes physical and virtual layers. IPv6-only identity is unsupported, SSID permission handling is missing, and the per-process collector has failure/cancellation weaknesses. |
| Storage | Volume-capacity arithmetic is reasonable. Throughput combines physical and file-backed virtual devices and calculates deltas after aggregation, producing incorrect results when the device set changes. |
| Battery and energy | Charge percentage and mV × mA → watts arithmetic are sound. Charged-state decoding and zero-current handling need fixes. Application watts measure CPU energy, not total application power. |
| History graphs | Real timestamps are collected, but rendering fills time before the first sample and bridges unobserved gaps. |

Findings are ordered by urgency and practical repair value. S means hours, M roughly a day, and L several days, including verification. Risk is the risk of changing the implementation. Confidence is high for all listed findings; hardware qualifications below are deliberately separate.

| # | Priority / category | Finding and impact | Effort | Fix risk | Evidence |
| --- | --- | --- | --- | --- | --- |
| 1 | P1 / correctness | Process CPU divides Mach ticks by nanoseconds; usage was understated by 41.67× on this Mac. | S | Low | [counter capture](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/ProcessStatsSampler.swift:213), [percentage](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/ProcessStatsSampler.swift:356) |
| 2 | P2 / correctness | CPU source rows count application kernel work again in “System & Kernel” and subtract it from user-only CPU. | M | Medium | [source breakdown](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/Metrics/MenuBarController.swift:621) |
| 3 | P2 / correctness | Network rates and totals sum both physical interfaces and virtual tunnels, permitting duplicate accounting. | M | Medium | [interface selection](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/SystemStatsSampler.swift:453), [aggregation](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/SystemStatsSampler.swift:309) |
| 4 | P2 / correctness | Disk totals mix physical and virtual layers; aggregate deltas lose real activity or introduce jumps when devices appear/disappear. | M | Medium | [driver enumeration](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/SystemStatsSampler.swift:375), [sum](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/SystemStatsSampler.swift:403), [delta](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/SystemStatsSampler.swift:356) |
| 5 | P2 / correctness | “Top Energy Users” presents CPU-only power as general application power; unsupported telemetry looks like inactivity. | S | Low | [energy source](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/ProcessStatsSampler.swift:221), [presentation](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/Metrics/MenuBarController.swift:715) |
| 6 | P2 / correctness | Graphs draw readings over periods before collection began and across sampling gaps. | S | Low | [path construction](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/Metrics/MenuViews.swift:195) |
| 7 | P2 / performance and reliability | Immediate nettop failures cause an unpaced relaunch loop; a blocked child has no timeout or cancellation path. | M | Medium | [child lifetime](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/NetworkProcessSampler.swift:29), [read/wait](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/NetworkProcessSampler.swift:49), [refresh loop](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/Metrics/MenuBarController.swift:560) |
| 8 | P2 / correctness | Failed CPU, memory, network and disk reads become ordinary zero measurements. | M | Medium | [CPU failure](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/SystemStatsSampler.swift:180), [memory failure](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/SystemStatsSampler.swift:227), [network failure](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/SystemStatsSampler.swift:270), [disk failure](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/SystemStatsSampler.swift:330) |
| 9 | P2 / correctness | Working IPv6-only connections appear offline because metadata and connection state require IPv4. | M | Medium | [IPv4-only lookup](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/AdditionalStatsSampler.swift:191), [address filtering](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/AdditionalStatsSampler.swift:209), [offline label](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/Metrics/MenuBarController.swift:913) |
| 10 | P2 / correctness | Battery charged state is guessed from 99.5%; valid zero current is discarded. | S | Low | [state decoder](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/AdditionalStatsSampler.swift:329), [current decoder](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/AdditionalStatsSampler.swift:432) |
| 11 | P2 / accessibility | History ignores Reduce Motion; loading shimmer also ignores the application's animation preference. | S | Low | [history timeline](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/Metrics/MenuViews.swift:70), [shimmer](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/Metrics/MenuViews.swift:1239), [enablement](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/Metrics/MenuBarController.swift:203) |
| 12 | P2 / functionality | SSID is read without any Location Services authorisation flow, so ordinary recent-macOS installations cannot show it. | M | Low | [SSID read](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/AdditionalStatsSampler.swift:241), [application metadata](/Users/maxmoon/Documents/Code/Personal/Argus/Resources/Info.plist:4) |
| 13 | P3 / performance | The battery panel captures all processes twice per update instead of reusing the preceding snapshot. | S | Low | [energy sampling](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/MetricsCore/ProcessStatsSampler.swift:114) |
| 14 | P2 / verification | Tests exercise synthetic arithmetic and host plausibility, but not native units, device topology, unavailable states or scheduling failures. | M | Low | [synthetic CPU test](/Users/maxmoon/Documents/Code/Personal/Argus/Tests/MetricsCoreTests/SystemStatsSamplerTests.swift:83), [host smoke test](/Users/maxmoon/Documents/Code/Personal/Argus/Tests/MetricsCoreTests/SystemStatsSamplerTests.swift:34) |
| 15 | P3 / documentation | README promises battery history and storage activity in the menu bar; implementation has no battery graph and displays storage capacity percentage. | S | Low | [README](/Users/maxmoon/Documents/Code/Personal/Argus/README.md:38), [battery exclusion](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/Metrics/MenuBarController.swift:299), [storage title](/Users/maxmoon/Documents/Code/Personal/Argus/Sources/Metrics/MenuBarController.swift:1405) |

1. Process CPU units

`proc_pid_rusage` supplies CPU time in Mach units, whereas batch timestamps use `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)`. A local self-process probe compared these counters with POSIX `getrusage`: the timebase was 125/3, and approximately 164.6 ms CPU over 300 ms elapsed became 1.316% in the current formula instead of 54.853%, before normalisation by processor count. Apple's [rusage implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c#L1187-L1206) and [task accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c#L6387-L6392) confirm the units.

Convert counter deltas using a cached timebase, or express both sides in matching units. Test at least 1:1 and 125:3 ratios, PID reuse and counter decreases. Preserve the deliberate distinction between a process percentage per core and a machine-wide percentage.

2. CPU source categories

Applications include both user and system CPU, but the presentation adds the machine's complete system CPU separately. For example, 10% host user + 20% host system can be displayed as 30% application + 20% system. The current unit defect can obscure the overlap. The process and host measurement windows can also differ, so exact subtraction is not inherently valid.

Use combined application CPU with clearly described unattributed total, or retain separate user/system process counters for disjoint categories. Align intervals before computing a residual, and account for rows omitted by the display limit.

3. Network scope

The only interface exclusion is loopback. A VPN's virtual interface and its underlying physical interface can both account for a transfer. The duplication follows from the interface selection and Apple's [tunnel output accounting](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/if_utun.c#L2753-L2759); a live VPN transfer was not induced during this audit. The rates also describe all selected interfaces while the metadata describes one primary interface.

Define the user-facing scope explicitly: selected/default-route traffic, or non-overlapping physical-interface traffic. Do not combine logical and physical layers. Test a physical interface plus tunnel, multiple physical interfaces, counter reset and interface replacement. Clarify what the lifetime traffic totals cover.

4. Disk scope and device lifetime

A filtered local IOKit probe found both an internal NVMe block device and `AppleDiskImageDevice` in the matching set. Image activity and backing physical activity can therefore contribute to the same displayed total. Apple's [driver statistics](https://raw.githubusercontent.com/apple-oss-distributions/IOStorageFamily/main/IOBlockStorageDriver.h) are cumulative for each driver instance.

Separately, subtracting totals after aggregation is invalid when the set changes. If disk A advances from 1 GB to 1.1 GB and a disk with a 10 GB lifetime counter disappears, the aggregate falls and Argus reports zero, losing A's 100 MB. An added device with existing counters can produce a spike.

Choose one storage layer, retain counters by stable registry identity, calculate deltas for surviving devices, seed new devices, then sum. Test removal, addition, reset, virtual images and external physical drives. Keep system-volume capacity separate from all-physical-disk throughput, as the current UI already intends.

5. Energy semantics

Nanojoules divided by nanoseconds correctly gives watts. The problem is scope: Apple's [Recount documentation](https://github.com/apple-oss-distributions/xnu/blob/main/doc/observability/recount.md#L2-L11) describes CPU resource accounting, including [CPU energy](https://github.com/apple-oss-distributions/xnu/blob/main/doc/observability/recount.md#L65-L73). It does not measure an application's entire GPU, Neural Engine, memory, network and storage power demand.

Label this as estimated CPU power. Show unsupported telemetry separately from an empty ranking and avoid implying equivalence to Activity Monitor's Energy Impact or total battery drain.

6–8. History, scheduling and missing measurements

Start a graph at its first observed timestamp; leave earlier time blank and break significant gaps. One newly collected point currently draws a full-width history. Use timestamped samples that can express warming up, valid, stale and unavailable states rather than manufacturing zeros when collection fails.

Give network process sampling an explicit cadence even on failure. Its normal delay currently comes entirely from nettop: launch failure or a quick non-zero exit removes that delay, so the open-panel loop repeatedly spawns processes and refreshes the UI. Add bounded child lifetime, cancellation that terminates the child, and a failure state. Closing a panel currently only discards the eventual result; it does not cancel the detached blocking read. A hung child was not deliberately induced.

9–12. Network metadata, battery and motion

Use monitored path status independently of address lookup, and support both address families. For SSID, add a contextual permission flow or explicitly omit/explain the field. Apple's [CoreWLAN guidance](https://developer.apple.com/forums/thread/732431?answerId=758114022) confirms the Location Services requirement; the current SDK header does too.

Use external-power, native charging and native charged flags to decode battery state. Apple's [power-source keys](https://github.com/apple-oss-distributions/IOKitUser/blob/main/ps.subproj/IOPSKeys.h) allow a battery to be charged below 100%; the present code labels that state “On Hold”. Preserve a present zero current and render 0 W instead of an unavailable value. The local health estimate agreed with System Information; no claim of a generally broken health formula is warranted.

Gate all decorative animation on panel visibility, application preference and the live Reduce Motion setting. Numeric/list transitions already perform part of this check; history and shimmer do not. Sampling should continue when animation is disabled.

13–15. Efficiency, verification and documentation

Reuse the last energy batch while its panel remains open, as CPU/storage sampling already attempt to do. The duplicated process enumeration is confirmed; no material whole-app CPU saving was measured for that change.

Add deterministic fixtures alongside the existing host smoke tests. Highest-value cases: Mach timebase conversion; CPU category accounting; physical/virtual network scope; device addition/removal/reset; unavailable counters; IPv6-only identity; charged/charging/on-battery states; zero current; one-point/gapped history; collector failure pacing and cancellation. These tests should accompany the corresponding fixes, before broad refactoring.

Correct README claims to match the implemented widgets and document hardware-dependent telemetry. Do not add missing features solely to satisfy the prose.

Measured baseline and limits

The command below completed successfully with Xcode 26.6 on the local Apple Silicon Mac. All 21 tests passed: 18 MetricsCore tests and 3 preference tests. The first sandboxed attempt could not access Xcode caches/dependencies; rerunning with normal access succeeded. This was an environment restriction, not a project build failure.

```sh
xcodebuild -project Metrics.xcodeproj -scheme Metrics \
  -destination 'platform=macOS' -derivedDataPath .build-review \
  CODE_SIGNING_ALLOWED=NO test
```

A small harness linked against the unchanged Debug MetricsCore library measured:

| Operation | Samples | Median | Maximum |
| --- | ---: | ---: | ---: |
| Newly constructed sampler, all metrics | 5 | 12.261 ms | 30.937 ms |
| Warm sampler, all metrics | 30 | 0.114 ms | 0.186 ms |
| Network identity invalidated before each read | 5 | 4.793 ms | 4.902 ms |
| Battery cache invalidated before each read | 5 | 0.400 ms | 0.567 ms |

These measure collector calls on this host, not application CPU consumption, energy impact or UI frame time. They do not justify calling steady-state system sampling expensive. Cold metadata reads can nevertheless occupy a significant part of a UI frame because the controller calls them synchronously on the main actor.

The nettop command successfully produced the repeated CSV header expected by the parser. The CPU hardware reader returned plausible temperature and frequency with normal system access. No changes to network configuration, mounted volumes, system power state or user preferences were made for diagnostic purposes.

No runtime validation was performed on Intel hardware, macOS 13, an IPv6-only network, active VPN traffic, hot-plug transitions or a complete battery discharge/charge cycle. Sensor calibration, long-running UI/energy profiling, third-party dependency internals, release publication and update installation were not audited end to end. Build/release files received a static review; this was not a dedicated security assessment.

Recommended direction

Retain the native application, core/UI separation, shared background cadence, optional queries, bounded history and existing actor isolation. A wholesale rewrite would discard useful working pieces without first resolving metric definitions.

First, land the unit and accounting fixes with deterministic tests. Then introduce a small explicit measurement model carrying value, unit, scope, timestamp/interval and availability. Keep per-device/per-interface baselines with the collector that owns them.

Next, give one sampling owner responsibility for cadence, cache invalidation, wake/re-enable baselines and cancellation; publish immutable results to the main actor. Expensive panel-only work remains demand-driven. This also prevents an external child process from controlling UI refresh cadence.

Finally, extract presentation calculations and the public-IP service from the 1,664-line controller, and split the 1,829-line view file by existing component boundaries as those areas change. Preserve the current appearance. Treat private SMC/IOReport adapters as optional capabilities with documented definitions; do not invent readings when a platform does not support them.

Considered and rejected

- `RUSAGE_INFO_V6` was suspected of being too new for macOS 13, but Ventura-era XNU defines and handles it. No compatibility finding is asserted on that basis.
- A possible frequency-table index shift was checked against local IOReport states; the local E/P state indices matched their tables. Cross-model support remains unverified.
- Initial nil hardware readings inside the sandbox were not treated as device failures; the same reader worked with normal access.
- A possible secondary-graph nil alignment defect is unreachable through the current enabled-storage sampling path, which always supplies a storage activity object.
- Core memory arithmetic, energy unit conversion, battery voltage/current unit conversion, PID-reuse checks, CPU tick rollover handling and the observed nettop CSV header were not found defective.
- A public-IP cache invalidation race remains an investigation lead, not a confirmed finding; cancellation behaviour was not reproduced deterministically.
- UI file size and main-actor sampling are restructuring opportunities, not evidence by themselves of major runtime overhead. No unnecessary framework migration or helper daemon is recommended.
