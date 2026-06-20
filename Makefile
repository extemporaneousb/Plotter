PYTHON ?= python3
VENV ?= .venv
PORT ?=
BAUD ?= 115200
ARTIFACTS ?= artifacts
AXIS ?= X
DISTANCE ?= 1.0
FEED ?= 60
DRAW_FEED ?= 180
TRAVEL_FEED ?= 500
ARM_MOTION ?= 0
NO_DRY_RUN ?= 0
COMMANDED ?= $(DISTANCE)
MEASURED ?=
ARM_PEN ?= 0
ARM_SETTINGS ?= 0
ARM_UNLOCK ?= 0
ARM_RESET ?= 0
ARM_HOME ?= 0
PEN_COMMAND ?=
PEN_DOWN ?=
PEN_UP ?=
KNOWN_PEN_UP ?= M3 S40
KNOWN_PEN_DOWN ?= M3 S720
X_STEPS ?= 39.86843
Y_STEPS ?= 35.79098
DWELL ?= 1.0
COUNT ?= 3
SPACING ?= 5
GROUP_GAP ?= 15
STATUS_COUNT ?= 40
STATUS_INTERVAL ?= 0.25
HOMING_PULL_OFF ?= 10
X_MAX_TRAVEL ?= 400
WORKSPACE_X_TRAVEL ?= 533.4
WORKSPACE_Y_TRAVEL ?= 215.9
HTTP_PORT ?= 8765
BRIDGE_PID ?= $(ARTIFACTS)/bridge.pid
BRIDGE_LOG ?= $(ARTIFACTS)/bridge.log
BRIDGE_SCREEN ?= plotter-bridge

BIN := $(VENV)/bin
PIP := $(BIN)/python -m pip
PLOTTERCTL := $(BIN)/plotterctl
PYTEST := $(BIN)/pytest
RUFF := $(BIN)/ruff
INSTALL_STAMP := $(VENV)/.install-stamp
SCALE_SNAPSHOT := $(shell if [ -f "$(ARTIFACTS)/controller_snapshot_after_settings.json" ]; then echo "$(ARTIFACTS)/controller_snapshot_after_settings.json"; else echo "$(ARTIFACTS)/controller_snapshot.json"; fi)

.PHONY: help venv install test lint check launch install-shortcuts app preview-app standby-app live-app ports status watch-status unlock soft-reset home-preview home-xy bridge-standby bridge-standby-bg bridge-standby-restart bridge-preview bridge-preview-bg bridge-preview-restart bridge-live-bg bridge-live-restart bridge-stop bridge-server mock-probe mock-snapshot probe snapshot jog-preview jog measure-jog-preview measure-jog line-preview draw-line pen-preview pen-trial pen-cycle-preview pen-cycle save-pen-config pen-up pen-down configured-line-preview draw-config-line measure-pattern-preview draw-measure-pattern scale-report settings-plan apply-settings xy-homing-plan apply-xy-homing-settings homing-tune-plan apply-homing-tune workspace-travel-plan apply-workspace-travel hard-limits-off hard-limits-on clean require-port require-motion-arm require-pen-arm require-settings-arm require-unlock-arm require-reset-arm require-home-arm require-pen-command require-pen-cycle require-measured

help:
	@echo "Plotter Vision targets:"
	@echo "  make install                         Create/update .venv and install dev deps"
	@echo "  make check                           Run tests and lint"
	@echo "  make launch                          Reuse live bridge, restart dry-run bridge, or start standby; then open app"
	@echo "  make install-shortcuts               Install the Plotter Vision launcher"
	@echo "  make app                             Build and relaunch the native camera app"
	@echo "  make preview-app                     Restart dry-run hardware-standby bridge and relaunch app"
	@echo "  make standby-app [PORT=/dev/cu...]   Start dry-run serial-capable bridge and relaunch app"
	@echo "  make live-app PORT=/dev/cu... ARM_HOME=1 ARM_MOTION=1 ARM_PEN=1 ARM_UNLOCK=1 NO_DRY_RUN=1"
	@echo "  make ports                           List serial ports"
	@echo "  make status PORT=/dev/cu...          Read one no-motion status report"
	@echo "  make watch-status PORT=/dev/cu...    Watch Pn while pressing limit switches"
	@echo "  make unlock PORT=/dev/cu... ARM_UNLOCK=1"
	@echo "  make soft-reset PORT=/dev/cu... ARM_RESET=1"
	@echo "  make home-preview                    Preview configured XY homing command"
	@echo "  make home-xy PORT=/dev/cu... ARM_HOME=1 NO_DRY_RUN=1"
	@echo "  make bridge-standby                  Run foreground dry-run serial-capable bridge"
	@echo "  make bridge-standby-bg               Start dry-run serial-capable bridge in background"
	@echo "  make bridge-standby-restart          Restart dry-run serial-capable bridge from current code"
	@echo "  make bridge-preview                  Run foreground mock dry-run bridge for camera app"
	@echo "  make bridge-preview-bg               Start mock dry-run bridge in background"
	@echo "  make bridge-preview-restart          Restart mock dry-run bridge from current code"
	@echo "  make bridge-live-bg PORT=/dev/cu... ARM_HOME=1 ARM_MOTION=1 ARM_PEN=1 ARM_UNLOCK=1 NO_DRY_RUN=1"
	@echo "  make bridge-live-restart PORT=/dev/cu... ARM_HOME=1 ARM_MOTION=1 ARM_PEN=1 ARM_UNLOCK=1 NO_DRY_RUN=1"
	@echo "  make bridge-stop                     Stop background bridge"
	@echo "  make bridge-server PORT=/dev/cu... ARM_HOME=1 ARM_MOTION=1 ARM_PEN=1 ARM_UNLOCK=1 NO_DRY_RUN=1"
	@echo "  make mock-probe                      Run safe mock controller probe"
	@echo "  make mock-snapshot                   Save safe mock snapshot JSON"
	@echo "  make probe PORT=/dev/cu.usbmodemXXX  Run safe real controller probe"
	@echo "  make snapshot PORT=/dev/cu...        Save safe real controller snapshot JSON"
	@echo "  make jog-preview AXIS=X DISTANCE=1   Preview tiny relative jog commands"
	@echo "  make jog PORT=/dev/cu... ARM_MOTION=1 NO_DRY_RUN=1"
	@echo "  make measure-jog PORT=/dev/cu... ARM_MOTION=1 NO_DRY_RUN=1"
	@echo "  make line-preview AXIS=X DISTANCE=20 Preview manual-pen calibration line"
	@echo "  make draw-line PORT=/dev/cu... ARM_MOTION=1 NO_DRY_RUN=1"
	@echo "  make pen-preview PEN_COMMAND='M3 S1000'"
	@echo "  make pen-trial PORT=/dev/cu... PEN_COMMAND='M3 S1000' ARM_PEN=1 NO_DRY_RUN=1"
	@echo "  make pen-cycle PORT=/dev/cu... PEN_DOWN='M3 S1000' PEN_UP='M3 S0' ARM_PEN=1 NO_DRY_RUN=1"
	@echo "  make save-pen-config                 Save known-good M3 S720/S40 pen config"
	@echo "  make pen-down PORT=/dev/cu... ARM_PEN=1 NO_DRY_RUN=1"
	@echo "  make pen-up PORT=/dev/cu... ARM_PEN=1 NO_DRY_RUN=1"
	@echo "  make draw-config-line PORT=/dev/cu... ARM_MOTION=1 ARM_PEN=1 NO_DRY_RUN=1"
	@echo "  make measure-pattern-preview         Preview separated X/Y measurement pattern"
	@echo "  make draw-measure-pattern PORT=/dev/cu... DRAW_FEED=180 TRAVEL_FEED=500 ARM_MOTION=1 ARM_PEN=1 NO_DRY_RUN=1"
	@echo "  make scale-report AXIS=X COMMANDED=1 MEASURED=actual_mm"
	@echo "  make settings-plan X_STEPS=39.86843 Y_STEPS=35.79098"
	@echo "  make apply-settings PORT=/dev/cu... ARM_SETTINGS=1"
	@echo "  make xy-homing-plan                  Plan XY-only homing settings"
	@echo "  make apply-xy-homing-settings PORT=/dev/cu... ARM_SETTINGS=1"
	@echo "  make homing-tune-plan HOMING_PULL_OFF=10 X_MAX_TRAVEL=400"
	@echo "  make apply-homing-tune PORT=/dev/cu... ARM_SETTINGS=1"
	@echo "  make workspace-travel-plan WORKSPACE_X_TRAVEL=533.4 WORKSPACE_Y_TRAVEL=215.9"
	@echo "  make apply-workspace-travel PORT=/dev/cu... ARM_SETTINGS=1"
	@echo "  make hard-limits-off PORT=/dev/cu... ARM_SETTINGS=1"
	@echo "  make hard-limits-on PORT=/dev/cu... ARM_SETTINGS=1"
	@echo "  make clean                           Remove local env/cache/artifacts"

$(BIN)/python:
	$(PYTHON) -m venv $(VENV)
	$(PIP) install --upgrade pip setuptools wheel

$(INSTALL_STAMP): pyproject.toml $(BIN)/python
	$(PIP) install -e '.[dev]'
	touch $(INSTALL_STAMP)

venv: $(BIN)/python

install: $(INSTALL_STAMP)

test: install
	$(PYTEST)

lint: install
	$(RUFF) check .

check: test lint

launch:
	HTTP_PORT="$(HTTP_PORT)" scripts/plotter_launcher.sh smart

install-shortcuts:
	scripts/install_launcher_shortcuts.sh

app:
	macos/PlotterVisionCameraDemo/run.sh

preview-app: standby-app

standby-app: bridge-standby-restart app

live-app: bridge-live-bg app

ports: install
	$(PLOTTERCTL) ports

status: install require-port
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) status \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--count 1 \
		--interval-s 0 \
		--transcript $(ARTIFACTS)/status_transcript.jsonl

watch-status: install require-port
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) status \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--count $(STATUS_COUNT) \
		--interval-s $(STATUS_INTERVAL) \
		--transcript $(ARTIFACTS)/watch_status_transcript.jsonl

require-unlock-arm:
	@if [ "$(ARM_UNLOCK)" != "1" ]; then \
		echo "ERROR: unlock requires ARM_UNLOCK=1"; \
		exit 2; \
	fi

require-reset-arm:
	@if [ "$(ARM_RESET)" != "1" ]; then \
		echo "ERROR: soft reset requires ARM_RESET=1"; \
		exit 2; \
	fi

require-home-arm:
	@if [ "$(ARM_HOME)" != "1" ] || [ "$(NO_DRY_RUN)" != "1" ]; then \
		echo "ERROR: real homing requires ARM_HOME=1 NO_DRY_RUN=1"; \
		exit 2; \
	fi

unlock: install require-port require-unlock-arm
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) unlock \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--arm-unlock \
		--transcript $(ARTIFACTS)/unlock_transcript.jsonl

soft-reset: install require-port require-reset-arm
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) soft-reset \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--arm-reset \
		--transcript $(ARTIFACTS)/soft_reset_transcript.jsonl

home-preview: install
	$(PLOTTERCTL) home-xy --dry-run

home-xy: install require-port require-home-arm
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) home-xy \
		--arm-homing \
		--no-dry-run \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--transcript $(ARTIFACTS)/home_xy_transcript.jsonl

bridge-standby: install save-pen-config
	mkdir -p $(ARTIFACTS)
	@controller_args=""; \
	if [ -n "$(PORT)" ]; then controller_args="--controller-port $(PORT)"; fi; \
	$(PLOTTERCTL) bridge-server \
		--host 127.0.0.1 \
		--http-port $(HTTP_PORT) \
		$$controller_args \
		--baud $(BAUD) \
		--dry-run \
		--config-path $(ARTIFACTS)/machine_config.json \
		--workspace-x-max $(WORKSPACE_X_TRAVEL) \
		--workspace-y-max $(WORKSPACE_Y_TRAVEL) \
		--event-log $(ARTIFACTS)/bridge_events.jsonl \
		--transcript-dir $(ARTIFACTS)/bridge_transcripts \
		--calibration-dir $(ARTIFACTS)/calibration_sessions

bridge-standby-bg: install save-pen-config
	mkdir -p $(ARTIFACTS)
	@if ! command -v screen >/dev/null 2>&1; then \
		echo "ERROR: bridge-standby-bg requires screen for a detached standby bridge."; \
		exit 2; \
	fi
	@if [ -f "$(BRIDGE_PID)" ] && kill -0 "$$(cat "$(BRIDGE_PID)")" 2>/dev/null; then \
		echo "Bridge already running at http://127.0.0.1:$(HTTP_PORT) pid=$$(cat "$(BRIDGE_PID)")"; \
	elif curl --max-time 1 -fsS "http://127.0.0.1:$(HTTP_PORT)/health" >/dev/null 2>&1; then \
		echo "Bridge already responding at http://127.0.0.1:$(HTTP_PORT)"; \
	else \
		rm -f "$(BRIDGE_LOG)"; \
		screen -S "$(BRIDGE_SCREEN)" -X quit >/dev/null 2>&1 || true; \
		screen -dmS "$(BRIDGE_SCREEN)" /bin/sh -c 'cd "$(CURDIR)" && echo $$$$ > "$(BRIDGE_PID)" && controller_args=""; if [ -n "$(PORT)" ]; then controller_args="--controller-port $(PORT)"; fi; exec $(PLOTTERCTL) bridge-server \
			--host 127.0.0.1 \
			--http-port $(HTTP_PORT) \
			$$controller_args \
			--baud $(BAUD) \
			--dry-run \
			--config-path $(ARTIFACTS)/machine_config.json \
			--workspace-x-max $(WORKSPACE_X_TRAVEL) \
			--workspace-y-max $(WORKSPACE_Y_TRAVEL) \
			--event-log $(ARTIFACTS)/bridge_events.jsonl \
			--transcript-dir $(ARTIFACTS)/bridge_transcripts \
			--calibration-dir $(ARTIFACTS)/calibration_sessions \
			> "$(BRIDGE_LOG)" 2>&1'; \
		ready=0; \
		for _ in 1 2 3 4 5 6 7 8 9 10; do \
			if curl --max-time 1 -fsS "http://127.0.0.1:$(HTTP_PORT)/health" >/dev/null 2>&1; then \
				ready=1; \
				break; \
			fi; \
			sleep 0.2; \
		done; \
		if [ "$$ready" = "1" ] && kill -0 "$$(cat "$(BRIDGE_PID)")" 2>/dev/null; then \
			echo "Started standby bridge at http://127.0.0.1:$(HTTP_PORT) pid=$$(cat "$(BRIDGE_PID)")"; \
			echo "Log: $(BRIDGE_LOG)"; \
		else \
			echo "Standby bridge failed to start. Log:"; \
			cat "$(BRIDGE_LOG)"; \
			kill "$$(cat "$(BRIDGE_PID)")" 2>/dev/null || true; \
			rm -f "$(BRIDGE_PID)"; \
			exit 1; \
		fi; \
	fi

bridge-standby-restart:
	mkdir -p $(ARTIFACTS)
	@if [ -f "$(BRIDGE_PID)" ] && ! kill -0 "$$(cat "$(BRIDGE_PID)")" 2>/dev/null; then \
		rm -f "$(BRIDGE_PID)"; \
	fi
	@pid="$$(lsof -tiTCP:$(HTTP_PORT) -sTCP:LISTEN 2>/dev/null | head -n 1)"; \
	if [ -n "$$pid" ]; then \
		health="$$(curl --max-time 1 -fsS "http://127.0.0.1:$(HTTP_PORT)/health" 2>/dev/null || true)"; \
		if printf "%s" "$$health" | grep -q '"dry_run": true'; then \
			kill "$$pid"; \
			rm -f "$(BRIDGE_PID)"; \
			echo "Stopped stale dry-run bridge pid=$$pid"; \
			sleep 0.2; \
		else \
			echo "Refusing to stop live bridge on http://127.0.0.1:$(HTTP_PORT)."; \
			echo "$$health"; \
			echo "Disarm or stop it intentionally before replacing it."; \
			exit 2; \
		fi; \
	fi
	$(MAKE) bridge-standby-bg

bridge-preview: install save-pen-config
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) bridge-server \
		--host 127.0.0.1 \
		--http-port $(HTTP_PORT) \
		--mock \
		--dry-run \
		--config-path $(ARTIFACTS)/machine_config.json \
		--workspace-x-max $(WORKSPACE_X_TRAVEL) \
		--workspace-y-max $(WORKSPACE_Y_TRAVEL) \
		--event-log $(ARTIFACTS)/bridge_events.jsonl \
		--transcript-dir $(ARTIFACTS)/bridge_transcripts \
		--calibration-dir $(ARTIFACTS)/calibration_sessions

bridge-preview-bg: install save-pen-config
	mkdir -p $(ARTIFACTS)
	@if [ -f "$(BRIDGE_PID)" ] && kill -0 "$$(cat "$(BRIDGE_PID)")" 2>/dev/null; then \
		echo "Bridge already running at http://127.0.0.1:$(HTTP_PORT) pid=$$(cat "$(BRIDGE_PID)")"; \
	elif curl --max-time 1 -fsS "http://127.0.0.1:$(HTTP_PORT)/health" >/dev/null 2>&1; then \
		echo "Bridge already responding at http://127.0.0.1:$(HTTP_PORT)"; \
	else \
		$(PLOTTERCTL) bridge-server \
			--host 127.0.0.1 \
			--http-port $(HTTP_PORT) \
			--mock \
			--dry-run \
			--config-path $(ARTIFACTS)/machine_config.json \
			--workspace-x-max $(WORKSPACE_X_TRAVEL) \
			--workspace-y-max $(WORKSPACE_Y_TRAVEL) \
			--event-log $(ARTIFACTS)/bridge_events.jsonl \
			--transcript-dir $(ARTIFACTS)/bridge_transcripts \
			--calibration-dir $(ARTIFACTS)/calibration_sessions \
			> "$(BRIDGE_LOG)" 2>&1 & \
		echo $$! > "$(BRIDGE_PID)"; \
		ready=0; \
		for _ in 1 2 3 4 5 6 7 8 9 10; do \
			if curl --max-time 1 -fsS "http://127.0.0.1:$(HTTP_PORT)/health" >/dev/null 2>&1; then \
				ready=1; \
				break; \
			fi; \
			sleep 0.2; \
		done; \
		if [ "$$ready" = "1" ] && kill -0 "$$(cat "$(BRIDGE_PID)")" 2>/dev/null; then \
			echo "Started bridge at http://127.0.0.1:$(HTTP_PORT) pid=$$(cat "$(BRIDGE_PID)")"; \
			echo "Log: $(BRIDGE_LOG)"; \
		else \
			echo "Bridge failed to start. Log:"; \
			cat "$(BRIDGE_LOG)"; \
			kill "$$(cat "$(BRIDGE_PID)")" 2>/dev/null || true; \
			rm -f "$(BRIDGE_PID)"; \
			exit 1; \
		fi; \
	fi

bridge-preview-restart:
	mkdir -p $(ARTIFACTS)
	@if [ -f "$(BRIDGE_PID)" ] && ! kill -0 "$$(cat "$(BRIDGE_PID)")" 2>/dev/null; then \
		rm -f "$(BRIDGE_PID)"; \
	fi
	@pid="$$(lsof -tiTCP:$(HTTP_PORT) -sTCP:LISTEN 2>/dev/null | head -n 1)"; \
	if [ -n "$$pid" ]; then \
		health="$$(curl --max-time 1 -fsS "http://127.0.0.1:$(HTTP_PORT)/health" 2>/dev/null || true)"; \
		if printf "%s" "$$health" | grep -q '"dry_run": true' && printf "%s" "$$health" | grep -q '"controller": "mock"'; then \
			kill "$$pid"; \
			rm -f "$(BRIDGE_PID)"; \
			echo "Stopped stale mock dry-run bridge pid=$$pid"; \
			sleep 0.2; \
		else \
			echo "Refusing to stop non-preview bridge on http://127.0.0.1:$(HTTP_PORT)."; \
			echo "$$health"; \
			echo "Stop it intentionally before replacing it with a dry-run preview bridge."; \
			exit 2; \
		fi; \
	fi
	$(MAKE) bridge-preview-bg

bridge-live-bg: install require-port require-home-arm require-motion-arm require-pen-arm require-unlock-arm save-pen-config
	mkdir -p $(ARTIFACTS)
	@if ! command -v screen >/dev/null 2>&1; then \
		echo "ERROR: bridge-live-bg requires screen for a detached live bridge."; \
		exit 2; \
	fi
	@if [ -f "$(BRIDGE_PID)" ] && kill -0 "$$(cat "$(BRIDGE_PID)")" 2>/dev/null; then \
		echo "Bridge already running at http://127.0.0.1:$(HTTP_PORT) pid=$$(cat "$(BRIDGE_PID)")"; \
	elif curl --max-time 1 -fsS "http://127.0.0.1:$(HTTP_PORT)/health" >/dev/null 2>&1; then \
		echo "Bridge already responding at http://127.0.0.1:$(HTTP_PORT)"; \
	else \
		rm -f "$(BRIDGE_LOG)"; \
		screen -S "$(BRIDGE_SCREEN)" -X quit >/dev/null 2>&1 || true; \
		screen -dmS "$(BRIDGE_SCREEN)" /bin/sh -c 'cd "$(CURDIR)" && echo $$$$ > "$(BRIDGE_PID)" && exec $(PLOTTERCTL) bridge-server \
			--host 127.0.0.1 \
			--http-port $(HTTP_PORT) \
			--controller-port "$(PORT)" \
			--baud $(BAUD) \
			--arm-homing \
			--arm-motion \
			--arm-pen \
			--arm-unlock \
			--no-dry-run \
			--config-path $(ARTIFACTS)/machine_config.json \
			--workspace-x-max $(WORKSPACE_X_TRAVEL) \
			--workspace-y-max $(WORKSPACE_Y_TRAVEL) \
			--event-log $(ARTIFACTS)/bridge_events.jsonl \
			--transcript-dir $(ARTIFACTS)/bridge_transcripts \
			--calibration-dir $(ARTIFACTS)/calibration_sessions \
			> "$(BRIDGE_LOG)" 2>&1'; \
		ready=0; \
		for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do \
			if curl --max-time 1 -fsS "http://127.0.0.1:$(HTTP_PORT)/health" >/dev/null 2>&1; then \
				ready=1; \
				break; \
			fi; \
			sleep 0.25; \
		done; \
		if [ "$$ready" = "1" ] && [ -f "$(BRIDGE_PID)" ] && kill -0 "$$(cat "$(BRIDGE_PID)")" 2>/dev/null; then \
			echo "Started live bridge at http://127.0.0.1:$(HTTP_PORT) pid=$$(cat "$(BRIDGE_PID)")"; \
			echo "Log: $(BRIDGE_LOG)"; \
		else \
			echo "Live bridge failed to start. Log:"; \
			cat "$(BRIDGE_LOG)" 2>/dev/null || true; \
			screen -S "$(BRIDGE_SCREEN)" -X quit >/dev/null 2>&1 || true; \
			rm -f "$(BRIDGE_PID)"; \
			exit 1; \
		fi; \
	fi

bridge-live-restart:
	mkdir -p $(ARTIFACTS)
	@pid="$$(lsof -tiTCP:$(HTTP_PORT) -sTCP:LISTEN 2>/dev/null | head -n 1)"; \
	if [ -n "$$pid" ]; then \
		echo "Stopping bridge on http://127.0.0.1:$(HTTP_PORT) pid=$$pid"; \
		kill "$$pid"; \
		sleep 0.3; \
	fi; \
	screen -S "$(BRIDGE_SCREEN)" -X quit >/dev/null 2>&1 || true; \
	rm -f "$(BRIDGE_PID)"
	$(MAKE) bridge-live-bg

bridge-stop:
	@if [ -f "$(BRIDGE_PID)" ]; then \
		pid="$$(cat "$(BRIDGE_PID)")"; \
		if kill -0 "$$pid" 2>/dev/null; then \
			kill "$$pid"; \
			echo "Stopped bridge pid=$$pid"; \
		else \
			echo "No running bridge for pid=$$pid"; \
		fi; \
		rm -f "$(BRIDGE_PID)"; \
	else \
		echo "No bridge pid file found."; \
	fi
	@screen -S "$(BRIDGE_SCREEN)" -X quit >/dev/null 2>&1 || true

bridge-server: install require-port require-home-arm require-motion-arm require-pen-arm require-unlock-arm save-pen-config
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) bridge-server \
		--host 127.0.0.1 \
		--http-port $(HTTP_PORT) \
		--controller-port "$(PORT)" \
		--baud $(BAUD) \
		--arm-homing \
		--arm-motion \
		--arm-pen \
		--arm-unlock \
		--no-dry-run \
		--config-path $(ARTIFACTS)/machine_config.json \
		--workspace-x-max $(WORKSPACE_X_TRAVEL) \
		--workspace-y-max $(WORKSPACE_Y_TRAVEL) \
		--event-log $(ARTIFACTS)/bridge_events.jsonl \
		--transcript-dir $(ARTIFACTS)/bridge_transcripts \
		--calibration-dir $(ARTIFACTS)/calibration_sessions

mock-probe: install
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) probe --mock --transcript $(ARTIFACTS)/mock_probe_transcript.jsonl

mock-snapshot: install
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) snapshot --mock \
		--out $(ARTIFACTS)/mock_snapshot.json \
		--transcript $(ARTIFACTS)/mock_snapshot_transcript.jsonl

require-port:
	@if [ -z "$(PORT)" ]; then \
		echo "ERROR: set PORT=/dev/cu.usbmodemXXXX or PORT=/dev/cu.usbserialXXXX"; \
		exit 2; \
	fi

probe: install require-port
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) probe \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--transcript $(ARTIFACTS)/controller_probe_transcript.jsonl

snapshot: install require-port
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) snapshot \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--out $(ARTIFACTS)/controller_snapshot.json \
		--transcript $(ARTIFACTS)/controller_snapshot_transcript.jsonl

jog-preview: install
	$(PLOTTERCTL) jog \
		--axis "$(AXIS)" \
		--distance $(DISTANCE) \
		--feed $(FEED) \
		--return-to-start \
		--dry-run

require-motion-arm:
	@if [ "$(ARM_MOTION)" != "1" ] || [ "$(NO_DRY_RUN)" != "1" ]; then \
		echo "ERROR: real jog requires ARM_MOTION=1 NO_DRY_RUN=1"; \
		exit 2; \
	fi

require-pen-arm:
	@if [ "$(ARM_PEN)" != "1" ] || [ "$(NO_DRY_RUN)" != "1" ]; then \
		echo "ERROR: real pen actuation requires ARM_PEN=1 NO_DRY_RUN=1"; \
		exit 2; \
	fi

require-settings-arm:
	@if [ "$(ARM_SETTINGS)" != "1" ]; then \
		echo "ERROR: settings writes require ARM_SETTINGS=1"; \
		exit 2; \
	fi

jog: install require-port require-motion-arm
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) jog \
		--axis "$(AXIS)" \
		--distance $(DISTANCE) \
		--feed $(FEED) \
		--return-to-start \
		--arm-motion \
		--no-dry-run \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--transcript $(ARTIFACTS)/jog_$(AXIS)_$(DISTANCE)_transcript.jsonl

measure-jog-preview: install
	$(PLOTTERCTL) jog \
		--axis "$(AXIS)" \
		--distance $(DISTANCE) \
		--feed $(FEED) \
		--dry-run

measure-jog: install require-port require-motion-arm
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) jog \
		--axis "$(AXIS)" \
		--distance $(DISTANCE) \
		--feed $(FEED) \
		--arm-motion \
		--no-dry-run \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--transcript $(ARTIFACTS)/measure_jog_$(AXIS)_$(DISTANCE)_transcript.jsonl

line-preview: install
	$(PLOTTERCTL) draw-line \
		--axis "$(AXIS)" \
		--distance $(DISTANCE) \
		--feed $(FEED) \
		--dry-run

draw-line: install require-port require-motion-arm
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) draw-line \
		--axis "$(AXIS)" \
		--distance $(DISTANCE) \
		--feed $(FEED) \
		--arm-motion \
		--no-dry-run \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--transcript $(ARTIFACTS)/draw_line_$(AXIS)_$(DISTANCE)_transcript.jsonl

require-pen-command:
	@if [ -z "$(PEN_COMMAND)" ]; then \
		echo "ERROR: set PEN_COMMAND='M3 S...' or PEN_COMMAND='M5'"; \
		exit 2; \
	fi

pen-preview: install require-pen-command
	$(PLOTTERCTL) pen-trial \
		--command "$(PEN_COMMAND)" \
		--label pen \
		--dry-run

pen-trial: install require-port require-pen-command require-pen-arm
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) pen-trial \
		--command "$(PEN_COMMAND)" \
		--label pen \
		--arm-pen \
		--no-dry-run \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--transcript $(ARTIFACTS)/pen_trial_transcript.jsonl

require-pen-cycle:
	@if [ -z "$(PEN_DOWN)" ] || [ -z "$(PEN_UP)" ]; then \
		echo "ERROR: set PEN_DOWN='M3 S...' and PEN_UP='M3 S...' or 'M5'"; \
		exit 2; \
	fi

pen-cycle-preview: install require-pen-cycle
	$(PLOTTERCTL) pen-cycle \
		--down-command "$(PEN_DOWN)" \
		--up-command "$(PEN_UP)" \
		--dwell-s $(DWELL) \
		--dry-run

pen-cycle: install require-port require-pen-cycle require-pen-arm
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) pen-cycle \
		--down-command "$(PEN_DOWN)" \
		--up-command "$(PEN_UP)" \
		--dwell-s $(DWELL) \
		--arm-pen \
		--no-dry-run \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--transcript $(ARTIFACTS)/pen_cycle_transcript.jsonl

save-pen-config: install
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) save-pen-config \
		--up-command "$(KNOWN_PEN_UP)" \
		--down-command "$(KNOWN_PEN_DOWN)" \
		--out $(ARTIFACTS)/machine_config.json

pen-up: install require-port require-pen-arm
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) pen-trial \
		--command "$(KNOWN_PEN_UP)" \
		--label up \
		--arm-pen \
		--no-dry-run \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--transcript $(ARTIFACTS)/pen_up_transcript.jsonl

pen-down: install require-port require-pen-arm
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) pen-trial \
		--command "$(KNOWN_PEN_DOWN)" \
		--label down \
		--arm-pen \
		--no-dry-run \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--transcript $(ARTIFACTS)/pen_down_transcript.jsonl

configured-line-preview: install save-pen-config
	$(PLOTTERCTL) draw-config-line \
		--axis "$(AXIS)" \
		--distance $(DISTANCE) \
		--feed $(FEED) \
		--config-path $(ARTIFACTS)/machine_config.json \
		--dry-run

draw-config-line: install require-port require-motion-arm require-pen-arm save-pen-config
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) draw-config-line \
		--axis "$(AXIS)" \
		--distance $(DISTANCE) \
		--feed $(FEED) \
		--config-path $(ARTIFACTS)/machine_config.json \
		--arm-motion \
		--arm-pen \
		--no-dry-run \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--transcript $(ARTIFACTS)/draw_config_line_$(AXIS)_$(DISTANCE)_transcript.jsonl

measure-pattern-preview: install save-pen-config
	$(PLOTTERCTL) draw-measure-pattern \
		--line-distance $(DISTANCE) \
		--spacing $(SPACING) \
		--group-gap $(GROUP_GAP) \
		--count $(COUNT) \
		--draw-feed $(DRAW_FEED) \
		--travel-feed $(TRAVEL_FEED) \
		--config-path $(ARTIFACTS)/machine_config.json \
		--dry-run

draw-measure-pattern: install require-port require-motion-arm require-pen-arm save-pen-config
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) draw-measure-pattern \
		--line-distance $(DISTANCE) \
		--spacing $(SPACING) \
		--group-gap $(GROUP_GAP) \
		--count $(COUNT) \
		--draw-feed $(DRAW_FEED) \
		--travel-feed $(TRAVEL_FEED) \
		--config-path $(ARTIFACTS)/machine_config.json \
		--arm-motion \
		--arm-pen \
		--no-dry-run \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--transcript $(ARTIFACTS)/draw_measure_pattern_transcript.jsonl

require-measured:
	@if [ -z "$(MEASURED)" ]; then \
		echo "ERROR: set MEASURED=actual_mm"; \
		exit 2; \
	fi

scale-report: install require-measured
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) scale-report \
		--axis "$(AXIS)" \
		--commanded $(COMMANDED) \
		--measured $(MEASURED) \
		--snapshot $(SCALE_SNAPSHOT) \
		--out $(ARTIFACTS)/scale_$(AXIS)_$(COMMANDED)_observation.json

settings-plan: install
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) settings-plan \
		--x-steps $(X_STEPS) \
		--y-steps $(Y_STEPS) \
		--out $(ARTIFACTS)/settings_plan.json

apply-settings: install require-port require-settings-arm
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) apply-settings \
		--plan-path $(ARTIFACTS)/settings_plan.json \
		--arm-settings \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--transcript $(ARTIFACTS)/settings_write_transcript.jsonl \
		--verify-snapshot $(ARTIFACTS)/controller_snapshot_after_settings.json

xy-homing-plan: install
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) xy-homing-plan \
		--out $(ARTIFACTS)/xy_homing_plan.json

apply-xy-homing-settings: install require-port require-settings-arm
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) apply-xy-homing-settings \
		--plan-path $(ARTIFACTS)/xy_homing_plan.json \
		--arm-settings \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--transcript $(ARTIFACTS)/xy_homing_settings_transcript.jsonl \
		--verify-snapshot $(ARTIFACTS)/controller_snapshot_after_xy_homing_settings.json

homing-tune-plan: install
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) homing-tune-plan \
		--pull-off $(HOMING_PULL_OFF) \
		--x-max-travel $(X_MAX_TRAVEL) \
		--out $(ARTIFACTS)/homing_tune_plan.json

apply-homing-tune: install require-port require-settings-arm
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) apply-homing-tune \
		--plan-path $(ARTIFACTS)/homing_tune_plan.json \
		--arm-settings \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--transcript $(ARTIFACTS)/homing_tune_settings_transcript.jsonl \
		--verify-snapshot $(ARTIFACTS)/controller_snapshot_after_homing_tune.json

workspace-travel-plan: install
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) workspace-travel-plan \
		--x-max-travel $(WORKSPACE_X_TRAVEL) \
		--y-max-travel $(WORKSPACE_Y_TRAVEL) \
		--out $(ARTIFACTS)/workspace_travel_plan.json

apply-workspace-travel: install require-port require-settings-arm
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) apply-workspace-travel \
		--plan-path $(ARTIFACTS)/workspace_travel_plan.json \
		--arm-settings \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--transcript $(ARTIFACTS)/workspace_travel_settings_transcript.jsonl \
		--verify-snapshot $(ARTIFACTS)/controller_snapshot_after_workspace_travel.json

hard-limits-off: install require-port require-settings-arm
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) hard-limits-plan \
		--disabled \
		--out $(ARTIFACTS)/hard_limits_off_plan.json
	$(PLOTTERCTL) apply-hard-limits \
		--plan-path $(ARTIFACTS)/hard_limits_off_plan.json \
		--arm-settings \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--transcript $(ARTIFACTS)/hard_limits_off_transcript.jsonl \
		--verify-snapshot $(ARTIFACTS)/controller_snapshot_after_hard_limits_off.json

hard-limits-on: install require-port require-settings-arm
	mkdir -p $(ARTIFACTS)
	$(PLOTTERCTL) hard-limits-plan \
		--enabled \
		--out $(ARTIFACTS)/hard_limits_on_plan.json
	$(PLOTTERCTL) apply-hard-limits \
		--plan-path $(ARTIFACTS)/hard_limits_on_plan.json \
		--arm-settings \
		--port "$(PORT)" \
		--baud $(BAUD) \
		--transcript $(ARTIFACTS)/hard_limits_on_transcript.jsonl \
		--verify-snapshot $(ARTIFACTS)/controller_snapshot_after_hard_limits_on.json

clean:
	rm -rf $(VENV) .pytest_cache .ruff_cache build dist *.egg-info $(ARTIFACTS)
