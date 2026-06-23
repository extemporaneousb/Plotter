from __future__ import annotations

from importlib import import_module
from typing import Any

_EXPORT_MODULES = {
    "DrawingSafeZone": "plotter_vision.calibration.readiness",
    "ObservedGeometrySample": "plotter_vision.calibration.binding",
    "PaperFrameRegistration": "plotter_vision.calibration.paper",
    "SafeZoneEvaluation": "plotter_vision.calibration.readiness",
    "SafeZoneMarginsMM": "plotter_vision.calibration.readiness",
    "ScaleObservation": "plotter_vision.calibration.scale",
    "VisualCapObservation": "plotter_vision.calibration.readiness",
    "VisualPositionBinding": "plotter_vision.calibration.binding",
    "VisualProbeCapSnapshot": "plotter_vision.calibration.probe_evidence",
    "VisualProbeRun": "plotter_vision.calibration.probe_evidence",
    "VisualProbeSample": "plotter_vision.calibration.probe_evidence",
    "VisualProbeSummary": "plotter_vision.calibration.probe_evidence",
    "VisualReadinessState": "plotter_vision.calibration.readiness",
    "build_scale_observation": "plotter_vision.calibration.scale",
    "build_visual_readiness_state": "plotter_vision.calibration.readiness",
    "evaluate_cap_inside_safe_zone": "plotter_vision.calibration.readiness",
    "paper_corner_norm": "plotter_vision.calibration.paper",
    "solve_visual_position_binding": "plotter_vision.calibration.binding",
}

__all__ = list(_EXPORT_MODULES)


def __getattr__(name: str) -> Any:
    if name not in _EXPORT_MODULES:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
    value = getattr(import_module(_EXPORT_MODULES[name]), name)
    globals()[name] = value
    return value
