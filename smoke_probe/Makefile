PYTHON ?= python3
VENV ?= .venv
PORT ?=
BAUD ?= 115200
FILE ?=
ARM ?= 0
BIN := $(VENV)/bin
BBX := $(BIN)/bbx32-smoke

.PHONY: help venv install ports probe no-motion micro-x square hold reset check clean

help:
	@echo "Targets:"
	@echo "  make install"
	@echo "  make ports"
	@echo "  make probe PORT=/dev/cu.usbmodemXXXX"
	@echo "  make no-motion PORT=/dev/cu.usbmodemXXXX"
	@echo "  make micro-x PORT=/dev/cu.usbmodemXXXX ARM=1"
	@echo "  make square PORT=/dev/cu.usbmodemXXXX ARM=1"
	@echo "  make check PORT=/dev/cu.usbmodemXXXX FILE=path/to/file.gcode"
	@echo "  make hold PORT=/dev/cu.usbmodemXXXX"
	@echo "  make reset PORT=/dev/cu.usbmodemXXXX"

venv:
	$(PYTHON) -m venv $(VENV)
	$(BIN)/python -m pip install --upgrade pip setuptools wheel

install: venv
	$(BIN)/python -m pip install -e .

ports: install
	$(BBX) ports

require-port:
	@if [ -z "$(PORT)" ]; then echo "ERROR: set PORT=/dev/cu.usbmodemXXXX"; exit 2; fi

require-file:
	@if [ -z "$(FILE)" ]; then echo "ERROR: set FILE=path/to/file.gcode"; exit 2; fi

probe: install require-port
	$(BBX) probe --port "$(PORT)" --baud $(BAUD)

no-motion: install require-port
	$(BBX) no-motion --port "$(PORT)" --baud $(BAUD)

micro-x: install require-port
	@if [ "$(ARM)" != "1" ]; then echo "ERROR: motion requires ARM=1"; exit 2; fi
	$(BBX) micro-x --port "$(PORT)" --baud $(BAUD) --arm-motion

square: install require-port
	@if [ "$(ARM)" != "1" ]; then echo "ERROR: motion requires ARM=1"; exit 2; fi
	$(BBX) square --port "$(PORT)" --baud $(BAUD) --arm-motion

check: install require-port require-file
	$(BBX) check --port "$(PORT)" --baud $(BAUD) --file "$(FILE)"

hold: install require-port
	$(BBX) hold --port "$(PORT)" --baud $(BAUD)

reset: install require-port
	$(BBX) reset --port "$(PORT)" --baud $(BAUD)

clean:
	rm -rf $(VENV) build dist *.egg-info __pycache__
