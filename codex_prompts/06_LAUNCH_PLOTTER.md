# Codex launch prompt: Plotter Vision

Use this when the user asks Codex to launch the Plotter Vision app from this repository.

Safe preview launch:

```bash
make launch
```

That restarts the mock dry-run bridge and relaunches the native camera app.

Live hardware launch requires an explicit current controller port and explicit arming confirmation.
Do not reuse an old remembered `/dev/cu.*` value without checking the current machine.

```bash
make ports
PLOTTER_LIVE_CONFIRM=LIVE make launch-live PORT=/dev/cu.usbserial-XXXX
```

Stop the background bridge:

```bash
make launch-stop
```
