# bbx32-smoke

Minimal Python utility for probing an OpenBuilds BlackBox X32 / grblHAL-style controller over USB serial.

This tool is intentionally separate from the larger application scaffold. Its job is to de-risk the connection before you build the real control/calibration stack.

## Install

```bash
make install
```

or manually:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

## List ports

```bash
make ports
```

On macOS, prefer `/dev/cu.*` ports for initiating serial connections.

## Passive probe

```bash
make probe PORT=/dev/cu.usbmodemXXXX
```

The passive probe sends:

```text
$I
$G
?
$$
$#
```

It does not move the machine, unlock alarms, home axes, write settings, or actuate the pen.

## No-motion G-code test

```bash
make no-motion PORT=/dev/cu.usbmodemXXXX
```

This sends basic modal commands and a tiny dwell. It should not move the machine.

## Motion tests

Motion tests require `ARM=1`.

```bash
make micro-x PORT=/dev/cu.usbmodemXXXX ARM=1
make square PORT=/dev/cu.usbmodemXXXX ARM=1
```

Use only after clearing the machine and confirming you can stop it.

## G-code check mode

```bash
make check PORT=/dev/cu.usbmodemXXXX FILE=path/to/file.gcode
```

This toggles GRBL check mode around the streamed file. It is intended to parse and validate candidate G-code without executing motion.
