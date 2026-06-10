from __future__ import annotations

from pathlib import Path

from plotter_vision.bridge.server import BridgeRuntimeConfig, FaceRasterDrawRequest, PlotterBridge
from plotter_vision.config import MachineConfig
from plotter_vision.drawing import DrawingFrameMM, LuminanceRaster, RasterPolygonOptions


def test_bridge_dry_run_face_raster_draw_returns_polygon_preview(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = PlotterBridge(
        BridgeRuntimeConfig(
            dry_run=True,
            mock=True,
            config_path=config_path,
            event_log_path=tmp_path / "events.jsonl",
            transcript_dir=tmp_path / "transcripts",
            workspace_x_max=533.4,
            workspace_y_max=215.9,
        )
    )

    response = bridge.draw_face_raster(
        FaceRasterDrawRequest(
            request_id="face-dry",
            raster=LuminanceRaster(
                samples=[
                    [1.0, 0.65, 0.35, 0.9],
                    [0.85, 0.2, 0.1, 0.7],
                    [0.95, 0.45, 0.25, 0.8],
                    [1.0, 0.8, 0.5, 0.95],
                ]
            ),
            frame=DrawingFrameMM(
                origin_x_mm=20.0,
                origin_y_mm=20.0,
                width_mm=80.0,
                height_mm=80.0,
            ),
            options=RasterPolygonOptions(
                auto_contrast=False,
                darkness_threshold=0.3,
                min_hatch_spacing_mm=6.0,
                max_hatch_spacing_mm=12.0,
            ),
            max_segment_mm=25.0,
        )
    )

    assert response.status == "completed"
    assert response.raster_summary is not None
    assert response.raster_summary.selected_cell_count > 0
    assert response.summary is not None
    assert response.summary.draw_segment_count > 0
    assert response.simulation is not None
    assert response.simulation.status == "ok"
    assert response.machine_status is not None
    assert response.machine_status.status == "dry_run"


def test_face_raster_draw_rejects_all_light_input(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = PlotterBridge(
        BridgeRuntimeConfig(
            dry_run=True,
            mock=True,
            config_path=config_path,
            event_log_path=tmp_path / "events.jsonl",
            transcript_dir=tmp_path / "transcripts",
            workspace_x_max=533.4,
            workspace_y_max=215.9,
        )
    )

    response = bridge.draw_face_raster(
        FaceRasterDrawRequest(
            request_id="face-empty",
            raster=LuminanceRaster(samples=[[1.0, 0.96], [0.98, 1.0]]),
            options=RasterPolygonOptions(auto_contrast=False, darkness_threshold=0.2),
        )
    )

    assert response.status == "failed"
    assert response.error == "Face raster produced no drawable dark regions."
    assert response.raster_summary is not None
    assert response.raster_summary.polygon_count == 0


def _machine_with_pen() -> MachineConfig:
    machine = MachineConfig()
    machine.set_axis_travel(x_travel_mm=533.4, y_travel_mm=215.9)
    machine.max_calibration_line_mm = 120.0
    machine.pen.up_command = "M3 S40"
    machine.pen.down_command = "M3 S720"
    return machine


def _write_machine_config(tmp_path: Path) -> Path:
    config_path = tmp_path / "machine_config.json"
    _machine_with_pen().save_json(config_path)
    return config_path
