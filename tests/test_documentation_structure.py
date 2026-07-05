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

CANONICAL_WORKFLOW_DOCS = [
    "README.md",
    "docs/ARCHITECTURE.md",
    "docs/RUNBOOK.md",
    "docs/ROADMAP.md",
    "macos/PlotterVision/README.md",
]


def _removed_workflow_contract_terms() -> tuple[str, ...]:
    return (
        "legacy" + "_phase",
        "legacy" + "Phase",
        "machine" + "_video" + "_agreement",
        "Machine" + "-" + "Video",
        "machine" + "-" + "video",
        "machine" + "Video" + "Agreement",
        "Machine" + "Video" + "Agreement",
        "drawing" + "_border" + "_locked",
        "stale" + "_downstream",
        "run" + "_machine" + "_video" + "_probe",
        "needs" + "_drawing" + "_border",
        "validate" + "_cap" + "_target",
        "Validate" + " Cap" + " Target",
        "AG" + "REE",
        "EST" + "IMATE",
    )


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


def test_canonical_docs_use_current_workflow_contract_terms() -> None:
    docs_text = "\n".join((ROOT / path).read_text(encoding="utf-8") for path in CANONICAL_WORKFLOW_DOCS)
    architecture = (ROOT / "docs" / "ARCHITECTURE.md").read_text(encoding="utf-8")

    for term in _removed_workflow_contract_terms():
        assert term not in docs_text
    assert "`phase` is the progress plateau" in architecture
    assert "`activity` is the current operation or wait state" in architecture
    assert "`health` carries meta-state" in architecture
    assert "conditions are not workflow phases" in architecture
    assert "field registration probe" in architecture
    assert "machine-to-camera basis" in architecture
