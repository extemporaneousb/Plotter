#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))


def main() -> int:
    from plotter_vision.calibration.workflow_contract import (
        calibration_workflow_contract_markdown,
        extract_generated_workflow_contract,
        replace_generated_workflow_contract,
    )

    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true", help="Rewrite docs/ARCHITECTURE.md.")
    parser.add_argument("--check", action="store_true", help="Fail if docs/ARCHITECTURE.md is stale.")
    args = parser.parse_args()
    if not args.write and not args.check:
        parser.error("pass --write or --check")

    path = REPO_ROOT / "docs" / "ARCHITECTURE.md"
    original = path.read_text(encoding="utf-8")
    generated = calibration_workflow_contract_markdown()
    if args.check:
        current = extract_generated_workflow_contract(original)
        if current != generated:
            print("docs/ARCHITECTURE.md workflow contract is stale", file=sys.stderr)
            return 1
    if args.write:
        updated = replace_generated_workflow_contract(original)
        if updated != original:
            path.write_text(updated, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
