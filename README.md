# cc-system-usage (MenuMon)

A tiny macOS menu bar app that shows, at a glance:

- **Claude usage %** — the real 5-hour rate-limit percentage, read from the
  Claude desktop app's own local usage cache (the same number shown in its
  "Current session" bar), plus the time left until the window resets.
- **Weekly ("All models") usage %** — the same idea for the 7-day window.
- **Memory %** — system memory used, sampled once a minute, with a
  "Free Up Memory" button that runs macOS's `purge` (via the OS's own admin
  prompt — this app never sees your password).
- A dropdown panel with CPU load, top processes, memory breakdown, and a
  per-model cost estimate derived from your local `~/.claude/projects`
  transcripts.

No network calls, no telemetry — everything is read from files already on
your Mac.

## Build

Requires Xcode Command Line Tools (Swift 6) and macOS 14+. No Xcode project
needed — this is a plain SwiftPM package.

```bash
./build.sh
open build/MenuMon.app
```

`--dump` prints the same numbers as the panel to stdout, for debugging:

```bash
./.build/release/MenuMon --dump
```

## Configuration

Optional overrides at `~/.config/menumon/config.json`:

```json
{
  "pricing": {
    "claude-opus-5": { "input": 5, "output": 25 }
  },
  "fiveHourCostBudget": 0,
  "fiveHourTokenBudget": 0
}
```

- `pricing` — USD per million tokens for any model ID not in the built-in
  table (cache rates are derived: read = 0.1x input, write = 1.25x/2x input
  for 5m/1h TTL).
- `fiveHourCostBudget` / `fiveHourTokenBudget` — only used as a fallback if
  the Claude desktop app's usage cache isn't found on disk.

## How the real usage numbers are read

- **5-hour %**: `~/Library/Application Support/Claude/plan-usage-history.json`
  (the desktop app's own cache — ground truth, refreshed whenever the app
  checks in).
- **5-hour reset time**: computed, not read — Anthropic resets this window on
  a fixed UTC grid (00:00, 05:00, 10:00, 15:00, 20:00), verified against a
  real `resetsAt` timestamp found in the app's IndexedDB store. Deterministic,
  no file access needed.
- **Weekly %**: same `plan-usage-history.json` cache (`sd` field).
- **Weekly reset time**: best-effort parse of the app's IndexedDB
  write-ahead log for the real `resetsAt` value. This is an internal,
  undocumented Chromium storage format that gets compacted over time, so
  this can legitimately return "unavailable" — the app never fabricates a
  countdown it can't back with real data.

## License

Personal utility script — no license file included; use at your own risk.
