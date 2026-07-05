from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

CalibrationWorkflowPhase = Literal[
    "needs_cap",
    "motion_calibration",
    "motion_validated",
    "pen_ready",
    "drawing_training",
    "drawing_retry",
    "drawing_validated",
    "ready_to_draw",
]
CalibrationWorkflowActivity = Literal[
    "idle",
    "confirming_cap",
    "awaiting_field_registration_probe",
    "registering_border",
    "running_field_registration_probe",
    "awaiting_motion_probe",
    "running_motion_probe",
    "awaiting_motion_observation",
    "awaiting_pen_ready",
    "awaiting_drawing_preview",
    "awaiting_drawing_run",
    "running_drawing_batch",
    "awaiting_drawing_observation",
    "fitting_model",
    "validating_model",
    "awaiting_model_promotion",
    "awaiting_drawing_authority",
    "running_machine_action",
]
CalibrationWorkflowHealth = Literal["nominal", "stale", "blocked", "stale_and_blocked"]

CALIBRATION_WORKFLOW_PHASES: tuple[CalibrationWorkflowPhase, ...] = (
    "needs_cap",
    "motion_calibration",
    "motion_validated",
    "pen_ready",
    "drawing_training",
    "drawing_retry",
    "drawing_validated",
    "ready_to_draw",
)
CALIBRATION_WORKFLOW_ACTIVITIES: tuple[CalibrationWorkflowActivity, ...] = (
    "idle",
    "confirming_cap",
    "awaiting_field_registration_probe",
    "registering_border",
    "running_field_registration_probe",
    "awaiting_motion_probe",
    "running_motion_probe",
    "awaiting_motion_observation",
    "awaiting_pen_ready",
    "awaiting_drawing_preview",
    "awaiting_drawing_run",
    "running_drawing_batch",
    "awaiting_drawing_observation",
    "fitting_model",
    "validating_model",
    "awaiting_model_promotion",
    "awaiting_drawing_authority",
    "running_machine_action",
)
CALIBRATION_WORKFLOW_HEALTH_VALUES: tuple[CalibrationWorkflowHealth, ...] = (
    "nominal",
    "stale",
    "blocked",
    "stale_and_blocked",
)

GENERATED_WORKFLOW_CONTRACT_BEGIN = "<!-- CALIBRATION_WORKFLOW_CONTRACT:BEGIN -->"
GENERATED_WORKFLOW_CONTRACT_END = "<!-- CALIBRATION_WORKFLOW_CONTRACT:END -->"


@dataclass(frozen=True)
class CalibrationWorkflowTransition:
    source: str
    target: str
    action: str
    activity: CalibrationWorkflowActivity


CALIBRATION_WORKFLOW_TRANSITIONS: tuple[CalibrationWorkflowTransition, ...] = (
    CalibrationWorkflowTransition(
        "[*]",
        "needs_cap",
        "open workflow",
        "confirming_cap",
    ),
    CalibrationWorkflowTransition(
        "needs_cap",
        "motion_calibration",
        "confirm_green_cap",
        "awaiting_field_registration_probe",
    ),
    CalibrationWorkflowTransition(
        "motion_calibration",
        "motion_calibration",
        "run_field_registration_probe + lock_drawing_border",
        "awaiting_motion_probe",
    ),
    CalibrationWorkflowTransition(
        "motion_calibration",
        "motion_validated",
        "run_motion_calibration + validate_motion",
        "awaiting_pen_ready",
    ),
    CalibrationWorkflowTransition(
        "motion_validated",
        "pen_ready",
        "confirm_pen_ready",
        "awaiting_drawing_preview",
    ),
    CalibrationWorkflowTransition(
        "pen_ready",
        "drawing_training",
        "preview_batch",
        "awaiting_drawing_run",
    ),
    CalibrationWorkflowTransition(
        "drawing_training",
        "drawing_training",
        "run_batch + observe_ink + fit_model + validate_metrics",
        "awaiting_drawing_preview",
    ),
    CalibrationWorkflowTransition(
        "drawing_training",
        "drawing_retry",
        "weak_or_missing_ink_evidence",
        "awaiting_drawing_run",
    ),
    CalibrationWorkflowTransition(
        "drawing_retry",
        "drawing_training",
        "redraw_same_batch",
        "awaiting_drawing_observation",
    ),
    CalibrationWorkflowTransition(
        "drawing_training",
        "drawing_validated",
        "model_gates_pass",
        "awaiting_model_promotion",
    ),
    CalibrationWorkflowTransition(
        "drawing_validated",
        "ready_to_draw",
        "promote_current_model + drawing_authority",
        "idle",
    ),
)


def calibration_workflow_mermaid() -> str:
    lines = ["```mermaid", "stateDiagram-v2"]
    for transition in CALIBRATION_WORKFLOW_TRANSITIONS:
        lines.append(
            f"    {transition.source} --> {transition.target}: "
            f"{transition.action} / activity={transition.activity}"
        )
    lines.extend(
        [
            "    state \"health overlay: nominal | stale | blocked | stale_and_blocked\" as workflow_health",
            "    motion_calibration --> workflow_health: stale evidence",
            "    drawing_training --> workflow_health: blocked recovery",
            "    drawing_validated --> workflow_health: drawing authority missing",
            "```",
        ]
    )
    return "\n".join(lines)


def calibration_workflow_contract_markdown() -> str:
    return "\n\n".join(
        [
            GENERATED_WORKFLOW_CONTRACT_BEGIN,
            "Generated from `plotter_vision.calibration.workflow_contract`.",
            calibration_workflow_mermaid(),
            _literal_list("Allowed workflow phases", CALIBRATION_WORKFLOW_PHASES),
            _literal_list("Allowed workflow activities", CALIBRATION_WORKFLOW_ACTIVITIES),
            _literal_list("Allowed workflow health values", CALIBRATION_WORKFLOW_HEALTH_VALUES),
            GENERATED_WORKFLOW_CONTRACT_END,
        ]
    )


def replace_generated_workflow_contract(document: str) -> str:
    start = document.index(GENERATED_WORKFLOW_CONTRACT_BEGIN)
    end = document.index(GENERATED_WORKFLOW_CONTRACT_END) + len(GENERATED_WORKFLOW_CONTRACT_END)
    return (
        document[:start].rstrip()
        + "\n\n"
        + calibration_workflow_contract_markdown()
        + "\n\n"
        + document[end:].lstrip()
    )


def extract_generated_workflow_contract(document: str) -> str:
    start = document.index(GENERATED_WORKFLOW_CONTRACT_BEGIN)
    end = document.index(GENERATED_WORKFLOW_CONTRACT_END) + len(GENERATED_WORKFLOW_CONTRACT_END)
    return document[start:end].strip()


def _literal_list(title: str, values: tuple[str, ...]) -> str:
    return f"{title}:\n\n```text\n" + "\n".join(values) + "\n```"
