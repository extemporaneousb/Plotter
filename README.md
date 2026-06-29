# Plotter Vision

Mac-local control, calibration, and drawing workflow for one physical two-axis
servo pen plotter driven by an OpenBuilds BlackBox X32 controller running
grblHAL-compatible firmware.

The project is safety-first. Controller contact starts with passive serial
interrogation, real transcripts, dry-run defaults, explicit arming gates, and a
Python-owned bridge that keeps machine action separate from the native macOS
operator UI.

## Current Surfaces

- `plotterctl`: root CLI for passive probes, guarded hardware actions, bridge
  startup, and debug snapshots.
- `plotter_vision.bridge`: local HTTP bridge and machine-action boundary. It
  owns routing, safety validation, calibration state, planning, simulation,
  execution, artifacts, and trust decisions.
- `macos/PlotterVision`: native operator app. It owns camera presentation,
  operator interaction, overlays, app diagnostics, and typed bridge calls. It
  does not own serial transport or hardware command semantics.

The normal app launch is app-owned: `make launch` builds/opens the native app,
and the app starts a dry-run hardware-standby bridge child on an ephemeral
localhost port.

## Quick Start

```bash
make install
make check
make launch
```

For passive hardware contact:

```bash
make ports
make probe PORT=/dev/cu.usbmodemXXXX
make snapshot PORT=/dev/cu.usbmodemXXXX
```

For a timestamped diagnostic bundle:

```bash
make debug-snapshot
```

## Documentation Map

- [Architecture](docs/ARCHITECTURE.md): canonical system contract, authority
  boundaries, workflow state machine, route families, artifact freshness, and
  safety invariants.
- [Runbook](docs/RUNBOOK.md): launch procedures, app-owned bridge discovery,
  observability checks, passive probing, hardware setup notes, and known
  machine-specific settings.
- [Roadmap](docs/ROADMAP.md): current package shape, staged status,
  architectural debt, and maintenance backlog.
- [Network Transport Decision](docs/decisions/0001-network-transport.md):
  decision record for keeping Wi-Fi/network transport out of scope until the
  actual protocol is verified.
- [macOS App Notes](macos/PlotterVision/README.md): build/run/debug notes for
  the native app only.

## Development Contract

Architecture facts live in `docs/ARCHITECTURE.md`. Operational procedures live
in `docs/RUNBOOK.md`. Backlog and sequencing live in `docs/ROADMAP.md`.

Do not duplicate the canonical setup flow, safety model, route contract, or
artifact schema across multiple documents. If one of those facts changes,
change the owning document and link to it from local context.
