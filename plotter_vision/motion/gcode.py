from __future__ import annotations


def format_mm(value: float) -> str:
    return f"{value:.3f}".rstrip("0").rstrip(".")


def build_relative_jog_commands(
    *,
    axis: str,
    distance_mm: float,
    feed_mm_min: float,
    return_to_start: bool = False,
) -> list[str]:
    normalized_axis = axis.upper()
    commands = [
        "G21",
        "G91",
        "G94",
        f"G1 F{format_mm(feed_mm_min)}",
        f"G1 {normalized_axis}{format_mm(distance_mm)}",
    ]
    if return_to_start:
        commands.extend(
            [
                "G4 P0.05",
                f"G1 {normalized_axis}{format_mm(-distance_mm)}",
                "G4 P0.05",
            ]
        )
    commands.append("G90")
    return commands


def build_relative_xy_move_commands(
    *,
    x_mm: float,
    y_mm: float,
    feed_mm_min: float,
) -> list[str]:
    axes: list[str] = []
    if abs(x_mm) >= 0.000_001:
        axes.append(f"X{format_mm(x_mm)}")
    if abs(y_mm) >= 0.000_001:
        axes.append(f"Y{format_mm(y_mm)}")
    if not axes:
        raise ValueError("Relative XY move requires a non-zero X or Y distance.")

    return [
        "G21",
        "G91",
        "G94",
        f"G1 F{format_mm(feed_mm_min)}",
        f"G1 {' '.join(axes)}",
        "G90",
    ]


def build_parallel_line_motion_commands(
    *,
    line_axis: str,
    line_distance_mm: float,
    spacing_mm: float,
    count: int,
    draw_feed_mm_min: float,
    travel_feed_mm_min: float,
) -> list[list[str]]:
    if count < 1:
        raise ValueError("count must be at least 1.")
    normalized_line_axis = line_axis.upper()
    if normalized_line_axis not in {"X", "Y"}:
        raise ValueError("line_axis must be X or Y.")
    spacing_axis = "Y" if normalized_line_axis == "X" else "X"

    lines: list[list[str]] = []
    for index in range(count):
        line_commands = [
            f"G1 F{format_mm(draw_feed_mm_min)}",
            f"G1 {normalized_line_axis}{format_mm(line_distance_mm)}",
        ]
        if index < count - 1:
            line_commands.extend(
                [
                    f"G1 F{format_mm(travel_feed_mm_min)}",
                    f"G1 {normalized_line_axis}{format_mm(-line_distance_mm)}",
                    f"G1 {spacing_axis}{format_mm(spacing_mm)}",
                ]
            )
        lines.append(line_commands)
    return lines
