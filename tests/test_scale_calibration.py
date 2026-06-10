from __future__ import annotations

import pytest

from plotter_vision.calibration.scale import build_scale_observation


def test_scale_observation_estimates_steps_without_writing() -> None:
    observation = build_scale_observation(
        axis="X",
        commanded_mm=1.0,
        measured_mm=2.0,
        current_steps_per_mm=250.0,
    )

    assert observation.axis == "X"
    assert observation.observed_multiplier == 2.0
    assert observation.correction_multiplier == 0.5
    assert observation.estimated_steps_per_mm == 125.0
    assert "no controller settings" in observation.note


@pytest.mark.parametrize(
    ("axis", "commanded", "measured"),
    [
        ("Z", 1.0, 1.0),
        ("X", 0.0, 1.0),
        ("X", 1.0, 0.0),
    ],
)
def test_scale_observation_rejects_invalid_inputs(
    axis: str,
    commanded: float,
    measured: float,
) -> None:
    with pytest.raises(ValueError):
        build_scale_observation(
            axis=axis,
            commanded_mm=commanded,
            measured_mm=measured,
        )
