# Fixed Camera Polygon Drawing Plan

## Goal

Use a locked USB camera view, red-magnet paper fiducials, and measured plotter motion to draw
camera-derived face imagery as physical polygon strokes.

The endpoint is not "send image to plotter." The endpoint is:

1. register the paper plane from fixed fiducials,
2. learn the transform between plotter logical millimeters and the registered paper plane,
3. reduce the face image into bounded shaded polygons,
4. expand shaded polygons into plotter-safe outlines and hatch strokes,
5. execute through the bridge with the same dry-run, simulation, and arming gates as existing
   machine actions.

## Coordinate Spaces

- Camera normalized space: raw fixed-camera observations in `[0, 1]`.
- Paper normalized space: homography-normalized paper rectangle where fiducials define stable
  corners or registration points.
- Logical plotter millimeters: calibrated workspace coordinates used by planning code.
- Controller machine millimeters: GRBL `G53` coordinates after homing.

The red magnets are fiducials for camera-to-paper registration. They are not enough by themselves
to prove machine motion. Machine motion still needs pen-tip or drawn-mark observations paired with
commanded logical millimeter points.

## Image Processing

The image-to-drawing path should use a triangulated or polygonal approximation, then shade regions
with hatch density. A practical first implementation is:

- detect/crop the face from the computer camera,
- convert to grayscale/luminance,
- build a constrained polygon mesh or simplified contour regions,
- assign each polygon a shade value,
- convert shade to hatch spacing,
- submit the resulting paper-normalized polygon program to the bridge.

Current implementation:

- the macOS app detects the largest face in the latest camera frame,
- crops and downsamples it to a small top-to-bottom luminance raster,
- submits that raster to `POST /draw/face`,
- the bridge converts darker cells into shaded triangular polygons,
- the existing polygon planner expands shade into hatch strokes and runs the same simulation and
  machine safety gates as `/draw/polygon`.

For the geometry transform, the camera-paper registration is a homography. The machine-paper model
can start as affine and should move to homography only if residuals show real perspective or
non-planar error after fixed-camera registration.

## Safety Boundary

The macOS app can select cameras, show fiducials, and send typed observations or drawing programs.
It must not send raw G-code. Bridge endpoints own:

- workspace validation,
- pen up/down insertion,
- hatch/outline expansion,
- simulation/preview,
- real motion arming checks,
- controller transcripts and event logs.
