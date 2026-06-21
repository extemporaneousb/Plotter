# Fixed Camera Polygon Drawing Plan

## Goal

Use a locked USB camera view, red-magnet paper fiducials, and measured plotter motion to draw
capability-test programs and camera-derived portrait imagery as physical strokes.

The endpoint is not "send image to plotter." The endpoint is:

1. register the paper plane from fixed fiducials,
2. localize the visible cap marker in that paper plane,
3. learn the transform between plotter logical millimeters and the registered paper plane by drawing,
   measuring in video, adjusting, and drawing again,
4. persist the learned binding and residuals for future initialization,
5. express capabilities tests and portrait/image-to-shape output as `DrawingProgram` data,
6. preview the simulated pen motion on the plotter video stream,
7. execute through the bridge only after the same dry-run, simulation, residual, and arming gates as
   existing machine actions pass.

The canonical path is:

```text
DrawingProgram -> Planner -> Simulator -> VideoProjector -> Preview Overlay
  -> Executor -> Vision Observer -> Residual Solver -> Persisted Binding
```

## Coordinate Spaces

- Camera image space: raw fixed-camera observations in `[0, 1]`.
- Paper space: the homography-normalized paper rectangle where fiducials define stable corners or
  registration points.
- Drawing/logical millimeters: the shape-language planning frame used by Python drawing code.
- Machine coordinates: controller coordinates used by the bridge for execution.
- Display space: app-side fit/fill/rotation and overlay rendering; it is not motion authority.

The red magnets are fiducials for camera-to-paper registration. They are not enough by themselves
to prove machine motion. Machine motion still needs pen-tip or drawn-mark observations paired with
commanded logical millimeter points. The cap marker provides live carriage evidence, but cap-only
motion is still relative session evidence; absolute paper-plane drawing needs ink or pen-tip
observations with residuals.

## Image Processing

The image-to-drawing path should prefer contours, outlines, simple polylines, and explicit shape
primitives as the baseline representation. Hatch density is optional shading behavior, not the core
contract. A practical first implementation is:

- detect/crop the face from the computer camera,
- convert to grayscale/luminance,
- build simplified contour regions or bounded primitive sets,
- optionally assign shade values to selected regions,
- submit the resulting paper-normalized `DrawingProgram` to the bridge.

Capabilities tests use the same representation. They should start with simple marks, lines,
triangles, squares, and coordinate annotations, then expand to multi-shape programs that exercise
continuity, closure, scale, and residual measurement.

Current implementation:

- the macOS app detects the largest face in the latest camera frame,
- crops and downsamples it to a small top-to-bottom luminance raster,
- submits that raster to `POST /draw/face`,
- the bridge converts darker cells into shaded triangular polygons,
- the existing polygon planner expands shade into hatch strokes and runs the same simulation and
  machine safety gates as `/draw/polygon`.

For the geometry transform, the camera-paper registration is a homography. The machine-paper model
can start as affine and should move to homography only if residuals show real perspective or
non-planar error after fixed-camera registration. Learned parameters should persist as initialization
values, but camera pose remains session-specific and must be refreshed after camera movement.

## Safety Boundary

The macOS app can select cameras, show fiducials, and send typed observations or drawing programs.
It must not send raw G-code. Bridge endpoints own:

- workspace validation,
- pen up/down insertion,
- drawing-program expansion, including optional hatch/outline generation,
- simulation/preview,
- real motion arming checks,
- controller transcripts and event logs,
- residual solving and persisted visual position binding.

Preview routes must force dry-run behavior, return simulated geometry only, avoid controller
transcripts, and never move hardware. Preview success is not execution readiness; execution readiness
comes from the bridge's safety gates plus current persisted binding evidence.
