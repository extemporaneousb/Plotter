from __future__ import annotations

import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GENERATED_DOC_ROOTS = {"artifacts"}

EXPECTED_MARKDOWN_DOCS = {
    "AGENTS.md",
    "README.md",
    "docs/ARCHITECTURE.md",
    "docs/RUNBOOK.md",
    "docs/ROADMAP.md",
    "docs/decisions/0001-network-transport.md",
    "macos/PlotterVision/README.md",
}

RETIRED_DOCS = {
    "codex_prompts/04_PROJECT_CONTRACT.md",
    "docs/REPOSITORY_PLAN.md",
    "docs/NETWORK_TRANSPORT_DEFERRED.md",
}

EXPECTED_ROUTED_DOCS = [
    "AGENTS.md",
    "README.md",
    "docs/ARCHITECTURE.md",
    "docs/RUNBOOK.md",
    "docs/ROADMAP.md",
]


def test_documentation_structure_is_exact() -> None:
    actual = {
        path.relative_to(ROOT).as_posix()
        for path in ROOT.rglob("*.md")
        if not any(part.startswith(".") for part in path.relative_to(ROOT).parts)
        and path.relative_to(ROOT).parts[0] not in GENERATED_DOC_ROOTS
    }

    assert actual == EXPECTED_MARKDOWN_DOCS
    for retired in RETIRED_DOCS:
        assert not (ROOT / retired).exists()


def test_blackdog_routes_exact_durable_docs() -> None:
    blackdog_config = tomllib.loads((ROOT / "blackdog.toml").read_text(encoding="utf-8"))

    assert blackdog_config["taxonomy"]["doc_routing_defaults"] == EXPECTED_ROUTED_DOCS
