# Tachometer

**Detroit Automation Academy** — on-device analytics for macOS High Sierra (10.13).

Tachometer measures what Academy apps cost the machine they run on. It samples
the CPU counters and memory of Academy app families (bundle IDs under
`com.detroitautomationacademy.*`) twice a second via `libproc`, attributes
every helper process to its family with a contract role label (`shell`,
`renderer`, `gpu`, `helper` — Distro files/36 §3), and reports each process
two ways: **% of one thread** (the Activity Monitor scale) and **% of all
hardware** (the share of the whole machine). A session summary separates
steady-state cost from view-switch spikes using owner-placed marks (⌘J, or
automatic on focus change). An in-app scorer reads the stored samples
against the Academy budget table (`budgets-v1.json`, files/36 §5) and
writes `verdicts.json` — report only; it enforces nothing, and a budget
with no data reads NO DATA, never a silent pass.

Data posture, enforced in code: samples are plain-text JSON Lines in a
segmented, single-writer store under
`~/Library/Application Support/com.detroitautomationacademy.analytics/samples/`
(8 MiB segments sealed with SHA-256 into `manifest.json`; 256 MiB / 7-day
retention; `writer.lock` O_EXCL — a second writer is refused, never
merged). The app's bundle ID is `com.detroitautomationacademy.analytics`
(the store root and the `analytics-self` budget key on that identity);
its display name is Tachometer. The app contains **no network code** —
nothing is transmitted anywhere. Sampling runs only while the app is
open; quitting is the off switch. Tachometer's own row is in the table
and in its own sample stream: the measurer is measured, and its
self-budget (≤2% of one thread, ≤50 MB) is scored like every other.

## Build

- `./build.sh check` — syntax-check all sources against the MacOSX 10.13 SDK.
- `./build.sh app` — assemble `Tachometer.app` (macOS only, system clang).
- `tests/test_cpumath.c` — the portable delta-math core's test harness
  (`gcc -std=c99 tests/test_cpumath.c Tachometer/CPUMath.c -lm`).
- `tests/test_contract_shape.py` — merge-contract conformance: feeds the
  emitted record shape to the files/36 reference scorer and asserts the
  `analytics-self` and `minion-avatar` budgets score from it.

CI builds on the `build-test` branch and publishes prerelease test builds.
Publisher: Detroit Automation Academy. Unsigned test builds; the High
Sierra rig run is the behavioral verdict.
