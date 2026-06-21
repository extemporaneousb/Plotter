from __future__ import annotations

from typing import Literal

from pydantic import BaseModel

from plotter_vision.drawing.polygons import (
    DrawingProgram,
    PaperPointNorm,
    PointMarkPrimitive,
    PolylinePrimitive,
    SimpleShapePrimitive,
)


CapabilityTestKind = Literal[
    "center_crosshair",
    "line_length",
    "square_closure",
    "triangle",
    "multi_shape_coordinate_sheet",
]


class CapabilityTestDefinition(BaseModel):
    kind: CapabilityTestKind
    label: str
    program: DrawingProgram
    residual_roles: list[str]


def build_capability_test_definition(kind: CapabilityTestKind) -> CapabilityTestDefinition:
    if kind == "center_crosshair":
        return CapabilityTestDefinition(
            kind=kind,
            label="Center crosshair and coordinate marks",
            program=DrawingProgram(
                point_marks=[
                    PointMarkPrimitive(center=PaperPointNorm(x=0.5, y=0.5), mark_size_mm=6.0),
                    PointMarkPrimitive(center=PaperPointNorm(x=0.25, y=0.5), mark_size_mm=4.0),
                    PointMarkPrimitive(center=PaperPointNorm(x=0.75, y=0.5), mark_size_mm=4.0),
                    PointMarkPrimitive(center=PaperPointNorm(x=0.5, y=0.25), mark_size_mm=4.0),
                    PointMarkPrimitive(center=PaperPointNorm(x=0.5, y=0.75), mark_size_mm=4.0),
                ]
            ),
            residual_roles=["center", "x_axis", "y_axis"],
        )

    if kind == "line_length":
        return CapabilityTestDefinition(
            kind=kind,
            label="Horizontal and vertical line length test",
            program=DrawingProgram(
                polylines=[
                    PolylinePrimitive(
                        role="outline",
                        points=[PaperPointNorm(x=0.20, y=0.45), PaperPointNorm(x=0.80, y=0.45)],
                    ),
                    PolylinePrimitive(
                        role="outline",
                        points=[PaperPointNorm(x=0.50, y=0.20), PaperPointNorm(x=0.50, y=0.80)],
                    ),
                ]
            ),
            residual_roles=["line_endpoints", "axis_scale"],
        )

    if kind == "square_closure":
        return CapabilityTestDefinition(
            kind=kind,
            label="Square closure test",
            program=DrawingProgram(
                polylines=[
                    PolylinePrimitive(
                        role="outline",
                        closed=True,
                        points=[
                            PaperPointNorm(x=0.32, y=0.32),
                            PaperPointNorm(x=0.68, y=0.32),
                            PaperPointNorm(x=0.68, y=0.68),
                            PaperPointNorm(x=0.32, y=0.68),
                        ],
                    )
                ]
            ),
            residual_roles=["corners", "closure"],
        )

    if kind == "triangle":
        return CapabilityTestDefinition(
            kind=kind,
            label="Triangle test",
            program=DrawingProgram(
                simple_shapes=[
                    SimpleShapePrimitive(
                        kind="triangle",
                        center=PaperPointNorm(x=0.5, y=0.5),
                        size_norm=0.42,
                    )
                ]
            ),
            residual_roles=["corners", "angles"],
        )

    return CapabilityTestDefinition(
        kind=kind,
        label="Multi-shape coordinate sheet",
        program=DrawingProgram(
            point_marks=[
                PointMarkPrimitive(center=PaperPointNorm(x=0.5, y=0.5), mark_size_mm=5.0),
            ],
            polylines=[
                PolylinePrimitive(
                    role="outline",
                    points=[PaperPointNorm(x=0.15, y=0.5), PaperPointNorm(x=0.85, y=0.5)],
                ),
                PolylinePrimitive(
                    role="outline",
                    points=[PaperPointNorm(x=0.5, y=0.15), PaperPointNorm(x=0.5, y=0.85)],
                ),
                PolylinePrimitive(
                    role="outline",
                    closed=True,
                    points=[
                        PaperPointNorm(x=0.18, y=0.18),
                        PaperPointNorm(x=0.38, y=0.18),
                        PaperPointNorm(x=0.38, y=0.38),
                        PaperPointNorm(x=0.18, y=0.38),
                    ],
                ),
            ],
            simple_shapes=[
                SimpleShapePrimitive(
                    kind="triangle",
                    center=PaperPointNorm(x=0.72, y=0.72),
                    size_norm=0.24,
                )
            ],
        ),
        residual_roles=["origin", "axis_scale", "closure", "angles"],
    )


def build_capability_test_program(kind: CapabilityTestKind) -> DrawingProgram:
    return build_capability_test_definition(kind).program
