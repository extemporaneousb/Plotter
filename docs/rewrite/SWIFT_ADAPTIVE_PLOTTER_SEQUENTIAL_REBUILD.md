# Swift Adaptive Plotter: Sequential Rebuild Plan

## Prompt for the implementation team

You are rebuilding Plotter as one native Swift 6 macOS product. Execute this plan sequentially. Do not port the current application by surface area. The existing repository and runtime artifacts are evidence for hardware behavior, diagnostics, geometry experiments, and failure cases; they are not the new module, route, workflow, screen, or test specification.

Follow the repository's `AGENTS.md`, repo-local Plotter skill, and Blackdog task-worktree contract. Use a branch-backed task worktree before every retained edit. Update the owning architecture/development document before changing a contract. Land each phase only after its exit evidence is complete and the worktree is clean. Run the narrowest relevant validation plus `make check` where the legacy repository still owns that command.

## Fixed product and architecture contract

The live product is Swift-only on macOS.

Python may consume immutable exported run bundles offline for research, analysis, or experiments. Python must not acquire live camera frames, open the live serial port, own runtime state, calibrate, decide safety, plan, execute, promote a model, write the live ledger, gate the UI, or provide a runtime result to the Swift application.

Use one application process and direct typed calls. The initial targets are:

```text
PlotterModel       Pure typed geometry, drawing, model, fitting, and planning
PlotterRuntime     Devices, measurement, run interpreter, and durable ledger
PlotterApp         SwiftUI operator surface and composition root
PlotterTestSupport Test-only controller, clock, camera, and paper simulators
```

The only initial actors are:

- `RunInterpreter`: active run transitions, plan revision, frontiers, selected model/state, checkpoint decisions, blockers.
- `MachineController`: serial connection, parser/controller state, command serialization, arming, fixed machine safety gates.
- `VisionWorker`: reusable non-`Sendable` image-processing resources; function-like exact-frame measurements only.
- `RunLedger`: SQLite sequence, transactions, schema, and content-addressed artifact references; no domain decisions.

`CameraCapture` is confined to its AVFoundation serial queue and publishes immutable stamped frames.

Use these coordinate spaces and never route motion through display geometry:

```text
SourceRasterSpace -> vectorize/place -> FieldSpace logical drawing
CameraPixelSpace -> CameraPlaneSpace -> FieldRegistration -> FieldSpace observation
MachineSpace -> AdaptiveDrawingModel.forward -> FieldSpace predicted ink
FieldSpace/CameraPixelSpace -> PreviewSpace rendering only
```

Use exactly three program layers:

1. Immutable `DrawingProgram` with stable logical stroke IDs in `FieldSpace`.
2. Finite immutable `ExecutionPlan` revisions containing a closed vocabulary of bounded physical/observation instructions and ending at one checkpoint.
3. Controller-specific command batches containing exact serial bytes and acknowledgement/terminal-state requirements.

Track four execution facts explicitly:

```text
commanded frontier
controller-completed frontier
ink-verified frontier
ambiguous stroke/block set
```

Controller completion is not independent physical proof and is not ink success. Work that is controller-completed but not ink-verified is inspection-required, not remaining and not safe to redraw automatically.

## Absolute prohibitions

- Do not reintroduce Python into any live product path.
- Do not recreate the old backend/frontend split inside Swift with localhost HTTP, services, DTO mirrors, buses, duplicated stores, or client/server names.
- Do not port a legacy workflow, screen, route, object, compatibility layer, or test because old code or documentation mentions it.
- Do not add portrait controls, optional camera tools, broad vector formats, capability menus, or other optional UI before the adaptive ink-feedback vertical slice works.
- Do not add model complexity without independent validation data and grouped holdout improvement above the measured repeatability floor.
- Do not treat “calibrated” as a Boolean or flag disconnected from current execution authority, freshness, applicability, and blockers.
- Do not treat cap/marker movement, preview geometry, controller `ok`, controller `Idle`, or commanded pen state as proof of drawing success.
- Do not fit an independent reverse correction map. Invert the one causal forward model numerically and forward-check it.
- Do not change an accepted model during a pen-down stroke.
- Do not buffer commands beyond an inspection checkpoint or automatically resend an ambiguous command/stroke.
- Do not use software “E-stop” wording. `Hold Now`, `Abort Run`, and `Controller Reset` must name their actual semantics; emergency stop is physical hardware only.
- Do not create managers, repositories, factories, protocols, plugin systems, or wrapper layers without a demonstrated second implementation or distinct lifecycle/invariant.

## Phase execution protocol

For every phase:

1. Re-read current architecture and evidence; do not assume prior file paths are still current.
2. Write the phase's contract and deletion/migration disposition before implementation.
3. Keep the change a vertical capability increment, not a broad port.
4. Record deterministic fixtures and an evidence manifest with build/configuration hashes.
5. Run automated tests, simulation, replay, and only the explicitly authorized physical trial level.
6. Do not advance with an unexplained blocker, uncommitted implementation work, failing validation, or unreplayable physical action.

## Phase 1 — Forensic baseline and replacement boundary

### Objective

Freeze the useful old-system evidence and define the exact boundary of the replacement without creating product code or a migration compatibility layer.

### Scope and explicit non-goals

- Inspect current main, Blackdog state, launch paths, hardware/configuration artifacts, transcripts, camera/viewer patterns, drawing/portrait paths, persistence, readiness meanings, and test inventory.
- Select a small representative controller transcript corpus: passive startup, status, motion success, alarm/limit, timeout, hold/reset, disconnect, pen response, and configuration snapshots.
- Create a machine-readable evidence manifest with original paths, timestamps, hashes, provenance, and “historical/not currently verified” status.
- Produce a source/test disposition map: retain as fixture/reference, redesign, delete at cutover, or physically verify.
- Define the new app tree as `macos/AdaptivePlotter/`; it must not import or call the legacy Swift/Python product.
- Non-goal: no new serial connection, camera capture, machine motion, model fitting, or operator screen.
- Non-goal: do not copy all artifacts into Git; preserve the full archive read-only and commit only curated small fixtures/manifests.

### Domain objects and module changes

- Documentation and fixture manifest only.
- Define schemas for `EvidenceManifestEntry`, `MachineConfigurationHypothesis`, and `LegacyBehaviorFixture` in documentation; do not prematurely build a framework for them.
- Record the intended target/actor/object ownership contract in the architecture document.

### Acceptance criteria

- Every live legacy launch path and authority duplication is named with file evidence.
- Hardware values such as travel, baud, pin polarity, pen commands, homing, and settle time are labeled hypotheses, not defaults.
- Representative fixtures cover every parser/safety behavior intended for native reproduction.
- The deletion list includes Python bridge/server/live modules, Swift HTTP client/supervisor/DTOs, wizard, compatibility routes, portrait fallbacks, and route/string-contract tests.
- The new tree has no dependency edge to legacy live code; if the tree does not yet exist, the rule is documented and testable in phase 2.

### Tests and recorded evidence required before advancing

- `git status`, source-file inventory, line-count concentration, route/caller scan, test collection count.
- Fixture hashes verified against the read-only archive.
- Artifact freshness/process/device scan recorded; historical evidence must not be described as current live state.
- A review checklist confirms that cap readiness, binding, model readiness, workflow readiness, and execution authority were not collapsed into one term.

### Required observable UI/debug outputs

- No product UI in this phase.
- Deliver an inspectable forensic report, evidence manifest, and planned `RuntimeSnapshot` field list that identifies all facts the future operator workspace must expose.

### Retain/delete/migration decisions

- Retain selected transcripts, hardware observations, overlay/ink-inspection references, provenance schemas, deterministic geometry cases.
- Temporarily retain legacy source read-only until the phase 8 proof-based cutover.
- Do not migrate mutable latest-pointer artifacts as authority; they may become imported historical evidence only.

### Risks or assumptions to resolve before phase 2

- Full artifacts may be too large or contain contradictory configuration; curate rather than bulk-import.
- Actual controller/camera may be disconnected. Phase 2 begins from transcript simulation and passive contact only.
- Confirm the supported Mac/CPU/Xcode inventory before setting the final deployment matrix.

## Phase 2 — Swift-native foundations

### Objective

Create the one-process Swift product skeleton, native passive controller path, fixed safety envelope, minimal durable ledger, and deterministic simulator without camera or drawing.

### Scope and explicit non-goals

- Create an Xcode macOS app plus local targets `PlotterModel`, `PlotterRuntime`, `PlotterApp`, and test support.
- Enable Swift 6 strict concurrency.
- Implement IOKit serial discovery, BSD `/dev/cu.*` byte link, `MachineController`, GRBL/grblHAL-tolerant parser, and simulated/transcript links.
- Implement passive `$I`, `$G`, `?`, `$$`, `$#` interrogation only.
- Implement separate motion/pen arming state, fixed feed/distance/workspace policy values, and typed controller snapshots/blockers.
- Implement `RunLedger` SQLite schema for run/event/command/configuration and content hashes.
- Create one minimal window showing passive connection evidence.
- Non-goal: no motion, homing, unlock, settings write, pen actuation, camera, drawing, model, or old bridge call.

### Domain objects and module changes

- `MachineConfiguration`, `SafetyPolicy`, `ControllerState`, `MachineSnapshot`, `ControllerOperation`, `ControllerReply`.
- `MachineLink` is the only initial runtime protocol: BSD hardware, simulated GRBL, transcript replay.
- `MachineController` actor and `RunLedger` actor.
- `OperatorWorkspace` with presentation-only state and immutable controller projection.
- `RunInterpreter` may exist as a very small composition/run-lifecycle shell; do not add drawing behavior.

### Acceptance criteria

- New application runs with no Python process, HTTP listener, virtual environment, or source-checkout dependency.
- Passive probe sends exactly the allowed queries and records raw TX/RX, timings, parser outcomes, build/config IDs, and blockers.
- Multiple-port ambiguity is visible and requires selection; no auto-connect to an ambiguous device.
- Motion and pen operations are impossible from the product surface and API until later explicit phase gates.
- A ledger write failure prevents any future machine-affecting operation.

### Tests and recorded evidence required before advancing

- Parser golden tests against curated real transcripts, including unknown grblHAL fields, errors, alarms, pins, and timeouts.
- Pseudo-terminal and simulated-link tests for fragmentation, delayed/missing replies, disconnect, and reconnect.
- SQLite migration, transaction, crash/reopen, ordering, hash, WAL/export tests.
- Swift strict-concurrency build; no data-race warnings hidden with unsafe annotations.
- Optional authorized physical evidence: passive-only exported run bundle matching expected controller identity/configuration.

### Required observable UI/debug outputs

- Device list and exact selected BSD path/identity.
- Connection state, controller greeting/build, parser state, raw configuration snapshot, pins/alarm/state, evidence age.
- Separate motion/pen arm states, both off and unavailable.
- Exact blocker and raw transcript access.
- Developer diagnostics: byte stream, parse decisions, command timing, ledger transaction timing.

### Retain/delete/migration decisions

- Retain legacy Python controller transcripts only as fixtures.
- Do not wrap or call the Python controller.
- Do not build a compatibility DTO or route layer.

### Risks or assumptions to resolve before phase 3

- Verify signed/notarized app access to camera/serial under the chosen sandbox policy.
- Measure passive parser behavior on the actual grblHAL firmware before enabling any motion.
- If Intel support is required, add it to CI now; otherwise document Apple Silicon as the product baseline.

## Phase 3 — Canonical geometry and DrawingProgram

### Objective

Create the pure typed geometry, immutable logical drawing, field registration baseline, forward-model baseline, inverse command geometry, and non-moving preview.

### Scope and explicit non-goals

- Implement typed points, vectors, paths, covariances, transforms, and identities for SourceRaster, CameraPixel, CameraPlane, Field, Machine, Tool, and Preview spaces.
- Implement polyline-only `DrawingProgram` with stable IDs, ordering constraints, source provenance, canonical encoding, and content hash.
- Implement `FieldRegistration` with a tested baseline transform. Homography is the default candidate, not a forced legacy assumption.
- Implement affine `AdaptiveDrawingModel` value and distinct `ModelCandidate`; no learned model authority yet.
- Implement pure path sampling, residual value types, affine-seeded inversion, workspace/applicability checks, and preview projection.
- Non-goal: no camera frames, cap detection, serial motion, ink, spline, backlash learning, pen model, portrait, SVG, or plan interpreter generalization.

### Domain objects and module changes

- `Point2<Space>`, `VectorPath<Space>`, `MeasuredPoint2<Space>`, typed transforms.
- `DrawingProgram`, `LogicalStroke`, `StrokeStyle`, `DrawingSourceProvenance`.
- `FieldRegistration`, affine `AdaptiveDrawingModel`, `ModelCandidate`, `ModelApplicability`.
- Pure `CoordinateTransforms`, `PathSampler`, `CommandInverter`, `PlanCompiler` preview components.
- `PreviewSpace` remains in `PlotterApp`; model code never imports it.

### Acceptance criteria

- Illegal space mixing has no public API.
- Editing program geometry/style/order changes the hash; replaying canonical input produces the same hash.
- Registration degeneracy/orientation/identity mismatches return typed blockers.
- Affine forward/inverse round trip stays inside a declared numerical budget across the full field.
- Long straight/diagonal paths remain continuous and subdivision is controlled by transformed chord error.
- Preview cannot open the serial link or write a controller command record.

### Tests and recorded evidence required before advancing

- Property/parameterized tests for transform composition, orientation, finite values, bounds, covariance, degenerate geometry, reflection, and hashes.
- Synthetic registration fits with redundant holdouts; compare similarity/affine/homography candidates.
- Inverse continuation and forward-check tests near field interior/boundary and refusal outside applicability.
- Golden `DrawingProgram` and preview artifacts for one line, one polyline, a border-adjacent line, and a full-field diagonal.

### Required observable UI/debug outputs

- Static/non-moving canvas with Drawing Border, axes/origin, logical path, predicted path, applicability mask, and coordinate readout.
- Model/registration IDs and parameters labeled synthetic/unvalidated.
- Visible “DRAWING BLOCKED: no ink-validated execution authority” regardless of successful preview.
- Developer transform-chain and forward/inverse error readout.

### Retain/delete/migration decisions

- Retain useful legacy geometry cases as rewritten Swift fixtures.
- Do not port Python Pydantic schemas, primitive inventory, inverse tables, residual grid, or JSON compatibility.
- Delete any accidental `PaperSpace`/`PreviewSpace` leakage into command APIs before advancing.

### Risks or assumptions to resolve before phase 4

- Choose the simplest FieldRegistration model from held-out evidence; do not assume four-corner homography by tradition.
- Nominal FieldSpace millimetres are relational coordinates, not absolute ruler claims.

## Phase 4 — Camera and non-marking motion evidence

### Objective

Integrate exact-frame native camera evidence and bounded pen-up motion to establish current field/cap state and an initial affine motion map without claiming drawing success.

### Scope and explicit non-goals

- Implement AVFoundation `CameraCapture`, camera configuration identity, interruptions, sequence/timestamps, exact decision-frame retention, and `frame(newerThan:)`.
- Implement `VisionWorker` requests for field references and optional cap/marker localization with covariance/quality.
- Implement `RunAlignmentState` and distributed non-marking motion trials.
- Add explicitly armed, bounded, low-speed pen-up relative moves through `MachineController` with action-scoped safety.
- Estimate affine cap motion only from distributed non-collinear cap-centre observations; measure repeatability and direction/reversal behavior.
- Implement bounded fresh-frame/cap reacquisition with maximum attempts and total travel.
- Non-goal: no pen down, ink observation, cap-to-tip, model promotion for drawing, portrait, continuous servo, or continuous parameter update.

### Domain objects and module changes

- `StampedFrame`, `CameraConfiguration`, `StableFrameRequirement`, `MeasurementRequest/Result`, `CapObservation`, `FieldReferenceObservation`.
- `RunAlignmentState`, cap-evidence `FieldRegistration` version, affine motion candidate.
- Minimal `RunInterpreter` trial transitions and exact blockers.
- `CameraCapture` queue-confined class; `VisionWorker` actor remains measurement-only.

### Acceptance criteria

- Every observation names exact frame, camera config, capture time, freshness/stability, algorithm revision, covariance, and retained artifact/hash.
- Camera/format/orientation/exposure/focus changes invalidate dependent evidence.
- Affine cap map is full-rank and evaluated on held-out pen-up targets spanning the field.
- Bounded reacquisition stops on stale frames, attempt/travel budget, safety boundary, or weak evidence.
- The app remains categorically blocked for pen-down drawing and states that cap motion is not ink authority.

### Tests and recorded evidence required before advancing

- Recorded-frame injection, interruption, dropped/stale frame, orientation, device change, and exact-frame selection tests.
- Synthetic and physical cap/no-marker candidate experiments under lighting/occlusion variation.
- Simulated motion/camera coupling tests that keep controller and paper-scene simulation independent.
- Controlled physical pen-up 3x3 target trials approached from both directions; whole-trial holdouts and exported bundle.
- Measure cap repeatability, frame-burst covariance, command-to-controller completion timing, and any backlash signature.

### Required observable UI/debug outputs

- Direct pan/zoom camera canvas; Drawing Border, cap/feature observation, estimated pose, uncertainty ellipse, frame age, and motion-intent overlay.
- Accepted/rejected non-marking trial table with reasons and affine parameters/holdout residual.
- Explicit banner: “CAP MOTION MEASURED — INK NOT VERIFIED — DRAWING BLOCKED.”
- Developer frame-selection reason, intermediate detection mask, dropped-frame count, transform chain, and controller transcript.

### Retain/delete/migration decisions

- Retain current viewer/pan/zoom/overlay techniques only as reference.
- Do not port `CameraModel.lastBuffer`, Swift-local readiness gates, green-cap requirement, or duplicate motion solver.
- If no marker method is reliable, retain manual/alternative field evidence and defer marker use; do not force green segmentation.

### Risks or assumptions to resolve before phase 5

- Physical pen-up safety, travel, baud, pins, and hold behavior must be reverified.
- Identify a safe isolated test region and verified clear-observation waypoint.
- Determine whether a fixed camera ROI is sufficient for the first ink slice or full registration is required.

## Phase 5 — Ink-observation training kernel

### Objective

Deliver the smallest complete vertical slice before any product breadth:

```text
one logical vector path
-> safe bounded draw
-> lift and clear
-> actual ink observation
-> goal residual and model innovation
-> accepted/rejected evidence decision
-> durable recorded replay
```

### Scope and explicit non-goals

- Verify and version an explicit pen profile; implement separate pen arming and pen commands through `MachineController`.
- Implement a first-class `TrainingTrial` for one isolated known stroke and clean baseline/post evidence.
- Implement finite physical/observation instructions sufficient for the trial: lift, travel, bounded draw, clear, stable frame, ink capture, checkpoint.
- Implement baseline/post differencing, reserved-region contamination check, centreline extraction, monotone correspondence, coverage/topology, covariance, goal residual, and model innovation.
- Record the checkpoint resolution while retaining the prior affine model; slow adaptation is not required yet.
- Implement Recorded Replay of the complete trial.
- Non-goal: no portrait, multi-stroke program, continuous adaptation, spline, rich pen model, plan branches, optional image UI, or legacy cutover.

### Domain objects and module changes

- `PenProfile`, `TrainingTrial`, `ObservationRegion`, `ClearancePath`, `InkObservation`, `ObservedCurve<FieldSpace>`.
- `InkPathMatcher`, `ResidualCalculator`, evidence-quality values, `EvidenceDecision`, `CheckpointResolution`.
- Initial finite `ExecutionPlan` values and `ControllerCommandBatch` provenance.
- `RunLedger` frame/observation/residual/checkpoint/model records and replay projection.

### Acceptance criteria

- Actual pen-down motion requires separately armed motion and pen plus current fixed safety/configuration evidence.
- A draw is never inspected until pen-up is requested, controller state is reconciled, and the full tool uncertainty envelope is outside the ROI.
- The post frame is demonstrably newer than motion/clear completion and passes measurable stability criteria.
- An isolated stroke yields stored intended, commanded, predicted, observed, corresponded, and accepted/rejected geometry.
- At minimum, the first accepted trial has unambiguous association, at least 80% expected-arclength coverage, no unexplained extra connected component in the reserved ROI, finite covariance, and both residuals. These are kernel gates, not final product tolerance.
- Rejected evidence remains visible and never triggers redraw or model mutation.
- Recorded Replay reconstructs the same commands, frames, residuals, decision, blockers, and projection without hardware.

### Tests and recorded evidence required before advancing

- Golden synthetic masks for clean, missing, extra, endpoint blob, crossing, contamination, occlusion, and no-ink cases.
- Freshness/clearance/pen-state/arming failure tests.
- Fault injection before/after command prepare/write/ack/Idle/lift/clear/frame/measurement/checkpoint.
- At least three repeated physical isolated strokes in separate reserved regions to begin measuring ink/process repeatability.
- Export one complete accepted run and one deliberately rejected/weak-evidence run.

### Required observable UI/debug outputs

- Live/replay canvas with intended, predicted, observed ink, residual arrows, coverage gaps, and observation ROI.
- Literal commanded, controller-completed, and ink-verified status plus ambiguity.
- Frame age/stability, pen commanded/unknown state, clear-region proof, evidence decision, and exact blocker.
- Developer baseline/post frames, difference/mask/centreline/correspondence, raw serial, and ledger event timing.

### Retain/delete/migration decisions

- Retain any legacy ink-inspection fixture that is useful, but rewrite the algorithm and thresholds around exact evidence/provenance.
- Do not reuse green-frame compatibility or make one frame establish broad model trust.
- New app must still have zero live Python/HTTP dependency; add a tracked forbidden-symbol/process test.

### Risks or assumptions to resolve before phase 6

- Establish camera/ink repeatability, ink width, and a declared drawing tolerance not below the observation floor.
- Determine whether cap-to-tip, contact lag, or registration dominates the first residual; do not fit them together.
- If clearance or pen-up cannot be established safely, stop here and redesign hardware/observation geometry.

## Phase 6 — Adaptive drawing model

### Objective

Add conservative, identifiable, immutable candidate/accepted model versions and prove that model changes improve independent ink evidence without corrupting authority.

### Scope and explicit non-goals

- Fix the estimation gauge: registration from independent references, affine intercept from cap centres, tool offset from paired cap/ink, pen terms from contact trials.
- Implement stateful continuous per-axis play/backlash state and learn only its widths/needed parameters from bidirectional trials.
- Implement minimal `PenMarkModel` metrics for onset/release/width/missing contact; keep it separate from XY correction.
- Implement covariance-weighted Huber fitting, grouped trial/frame-burst bootstrap, whole-stroke holdouts, identifiability/conditioning, applicability, correction/Jacobian/inverse gates.
- Implement atomic candidate accept/retain and visible before/after comparison.
- Add axis-separable pitch correction only if affine/backlash/offset holdouts show stable axis structure.
- Do not implement the 4x4 2D spline unless its exceptional evidence gate is already met.
- Non-goal: no neural/TPS/RBF production model, projective machine map, independent inverse, portrait, or mid-stroke update.

### Domain objects and module changes

- `AdaptiveDrawingModel`, `ModelCandidate`, `ModelValidationReport`, `RegimeCoverage`, `PredictiveBound`, `PenMarkModel`, backlash execution state.
- Pure `DrawingModelFitter` and damped trust-region `CommandInverter` with continuation/forward check.
- `ModelApplicability` and model-specific `RunBlocker` cases.
- RunLedger parent/candidate/accepted/rejected model lineage and grouped validation artifacts.

### Acceptance criteria

- Candidate and accepted model types cannot be confused in the public API.
- An accepted model records parent, exact evidence IDs, parameter covariance, applicability, holdouts, algorithm/configuration revisions, and trust bounds.
- Parameter promotion uses effective independent trials, not pixels or centreline points.
- Clustered predictive 95% bound fits the declared drawing error budget throughout the applicable region.
- Any new component improves grouped holdout beyond both bootstrap error and repeatability noise with no region exceeding its regression allowance.
- Unknown backlash state after reset/manual/ambiguous motion blocks execution until a bounded take-up/relocalization action.
- A rejected candidate leaves the prior model active and produces no plan mutation.

### Tests and recorded evidence required before advancing

- Synthetic parameter-recovery and confounding tests; gauge and affine-nullspace tests.
- Bidirectional cap grid; paired cap/ink distributed probes; direction x feed x pen-transition factorial ink trials.
- Region-, direction-, and time-grouped whole-stroke holdouts.
- Inverse convergence/refusal, full-border Jacobian/no-fold, long-line continuity, and forward-error tests.
- Recorded replay of candidate accepted, candidate rejected, insufficient evidence, and configuration-invalidated cases.

### Required observable UI/debug outputs

- Active/candidate model IDs, parameter groups, values, deltas, uncertainty, coverage, applicability, and exact contributing trials.
- Held-out prior/candidate predictions over the same observations with RMS/p95/max/coverage/topology comparisons.
- Acceptance/retention rationale and remaining error budget.
- Developer design-matrix singular values, cluster/bootstrap summaries, fit weights, inverse iteration/condition diagnostics.

### Retain/delete/migration decisions

- Retain legacy residual/action fixtures only as challenge cases.
- Delete any new implementation of bilinear residual cells, arbitrary categorical action offsets, or dual forward/inverse models.
- Store no mutable “latest calibration” file; current accepted model is a versioned run decision/pointer.

### Risks or assumptions to resolve before phase 7

- The simplest affine/offset model may be sufficient. That is a valid outcome.
- Axis-separable or 2D spatial complexity remains prohibited until physical holdouts demand it.
- Thresholds must be derived from the phase 5/6 repeatability corpus, not copied from this prompt as millimetre constants.

## Phase 7 — Typed execution plan and interpreter

### Objective

Generalize the working one-stroke kernel into a small finite execution language, bounded command commits, explicit frontiers/ambiguity, atomic checkpoints, and safe remaining-work planning.

### Scope and explicit non-goals

- Finalize the closed plan vocabulary: `liftPen`, `travel`, `draw`, `clearObservationRegion`, `waitForStableFrame`, `captureInk`, `checkpoint`.
- End every plan revision at one checkpoint. No latent branch graph, generic workflow node, arbitrary predicate, loop, `AcceptEvidence`, `UpdateModel`, or `ReplanRemaining` instruction.
- Implement checkpoint resolution as the atomic domain transaction that sets evidence disposition, frontiers/ambiguity, accepted state/model, and next planning basis.
- Implement successor plan compilation from immutable `DrawingProgram` and only unresolved work beyond the commanded frontier.
- Subdivide a logical stroke into bounded controller commit blocks while pinning one model/state basis for the whole stroke and preserving geometry.
- Implement orderly pause, Hold Now, Abort Run, controller reset consequences, and restart reconciliation outside the plan language.
- Non-goal: no broad scheduling optimizer, workflow framework, streaming portrait, or command buffering past checkpoint.

### Domain objects and module changes

- `ExecutionPlan`, `PlanInstruction`, `DrawBlock`, `ControllerCommandBatch`, `ExecutionFrontiers`, `StrokeDisposition`, `CheckpointResolution`, `PlanningBasis`, `RunBlocker`.
- `RunInterpreter` actor becomes the sole run-transition authority and must remain free of geometry/vision/parser/persistence implementation.
- `PlanCompiler` and controller compiler remain pure; `MachineController` remains the only sender.

### Acceptance criteria

- Plan validation proves travel/clear/inspection/pen invariants and exact version pinning.
- `inkVerified <= controllerCompleted <= commanded`; ambiguity can coexist but never becomes remaining automatically.
- Only one bounded pen-contact block is outstanding; no new block is sent until the prior block reaches the required controller state.
- A logical stroke never changes model mid-stroke, even across continuation blocks or partial recovery.
- Evidence/model/state/next-basis checkpoint facts commit atomically.
- Restart never resends a transmitted ambiguous block or redraws controller-completed-but-unverified work.

### Tests and recorded evidence required before advancing

- Compiler golden tests: same plan/model/config -> byte-identical command batches with explicit modal state.
- State-machine property tests and failure injection at every instruction/command/checkpoint boundary.
- Simulated alarm/hold/limit/disconnect/reset/stale camera/storage failure and partial stroke.
- Continuous versus bounded-commit long-line physical comparison to set commit time/distance; if dwell artifacts exceed tolerance, cap first-product stroke length or change the proven commit strategy.
- Recorded replay and restart from all three frontiers plus ambiguity.

### Required observable UI/debug outputs

- Current finite plan revision/instruction/block; model/state/config basis; commanded/controller-completed/ink-verified frontiers and ambiguous regions.
- Exact Pause After Current Atom, Hold Now, Abort Run, and Controller Reset actions with permitted/blocked status.
- Successor-plan lineage and list of included/excluded logical stroke ranges with reasons.
- Developer command lifecycle, precondition digest, bytes, ack, terminal state, controller buffer/hold timing, and checkpoint transaction.

### Retain/delete/migration decisions

- Retain only the working phase-5 training vocabulary and refactor it into the canonical plan; delete any separate training runner.
- Delete protocols/managers created only to make the interpreter look modular.
- Do not port Python planner/session workflow or current route actions.

### Risks or assumptions to resolve before phase 8

- Commit boundaries may create line artifacts; use evidence, not convenience, to choose them.
- Controller-completed terminology must not be mislabeled as physical/ink truth.
- Keep interpreter source reviewable; extract pure policy when complexity grows, not new service objects.

## Phase 8 — First conservative end-to-end vector drawing

### Objective

Execute a real multi-stroke logical vector drawing with actual ink feedback, initially inspect every stroke, accept only conservative state/model changes, replan only uncommanded work, and perform the proof-based legacy cutover.

### Scope and explicit non-goals

- Use a hand-authored 5-10 stroke `DrawingProgram` with lines/polylines distributed across a safe interior region, directions, and lengths.
- Preview through the exact same planner/model used for execution.
- Execute one stroke/checkpoint at a time; observe ink after each stroke.
- Permit immediate identified state correction and at most evidence-gated model changes between strokes.
- Replan only strokes beyond the commanded frontier; freeze completed/ambiguous history.
- Exercise pause, camera reacquisition, rejected evidence, candidate retention, and safe resume.
- After repeatable acceptance, remove old live product paths.
- Non-goal: no portrait, SVG, arbitrary stroke grouping, sophisticated order optimization, advanced pen model, or optional UI inventory.

### Domain objects and module changes

- No new architecture layer. Extend `DrawingProgram`, `PlanCompiler`, `RunInterpreter`, observation matching, and workspace only as the vertical slice requires.
- Add `RunOutcome` and a concise current `RuntimeSnapshot` equivalent to the useful parts of old `/codex/snapshot`.

### Acceptance criteria

- Three controlled repeated physical runs complete without unknown unhandled state.
- Every stroke has stable intended/commanded/predicted/observed provenance and explicit disposition.
- Each accepted stroke meets the declared phase-6 drawing tolerance, coverage, topology, and uncertainty gates; aggregate success cannot hide a failed stroke.
- At least one run proves state/model update -> successor plan -> remaining strokes while executed geometry/history stays unchanged.
- At least one fault/recovery run proves no automatic redraw of ambiguous or controller-completed-unverified work.
- Operator can explain why drawing is allowed/paused/blocked from essential UI.
- New product launches and operates without Python, HTTP, DTO mirrors, or bridge supervisor.

### Tests and recorded evidence required before advancing

- Full simulated and recorded replay for success, weak ink, large residual, camera loss, transport loss, hold, ambiguous block, model rejection, and storage blocker.
- Three accepted physical run bundles plus at least one recovery bundle.
- Forbidden-symbol/dependency/process scans for Python live imports, URLSession/localhost bridge calls, old DTO names, and duplicate readiness models.
- Swift build/tests, documentation validation, diff check, and repo `make check` during transition.

### Required observable UI/debug outputs

- Complete live canvas, authority bar, frontiers, stroke/checkpoint timeline, evidence and model comparison, blockers/recovery.
- Program/plan/model progress and exact unexecuted/ambiguous sets.
- Export run bundle and Recorded Replay from the operator workspace.
- Developer controller, frame, residual, fit, planning, and ledger traces.

### Retain/delete/migration decisions

After all acceptance evidence passes, delete in the same cutover:

- Python live bridge/server/controller/calibration/planning/execution startup path.
- Swift bridge HTTP client, DTO mirror, model, process supervisor, launcher compatibility, and old app workflow.
- Calibration wizard, legacy readiness/preflight flags, duplicate motion model, setup-frame compatibility, capability/shape routes, old portrait/face paths.
- HTTP-route, wizard-string, compatibility, and obsolete UI tests.

Retain:

- selected historical transcripts/fixtures and evidence manifest;
- rewritten Swift hardware/parser/geometry/failure tests;
- optional Python offline tools moved under an explicitly named research-only boundary and able to read exported copies only.

Do not leave compatibility aliases or a dormant live bridge “just in case.”

### Risks or assumptions to resolve before phase 9

- Physical success threshold must remain tied to observed ink repeatability/width and declared drawing tolerance.
- If cutover proof fails, fix the vertical slice; do not defer deletion by wiring a compatibility bridge into the new product.

## Phase 9 — Operator observability, replay, and recovery

### Objective

Complete observability as a product capability: one coherent workspace, model/evidence truth, recorded replay, algorithm re-evaluation, retention, crash recovery, and accessible operation.

### Scope and explicit non-goals

- Finalize three-pane workspace, direct pan/zoom, semantic timeline, synchronized selection, overlay presets, model/trial inspector, blocker/recovery details.
- Implement Recorded Replay and clearly separate non-authoritative Algorithm Re-evaluation.
- Implement restart from last durable checkpoint with passive controller reconciliation, fresh camera/field/tool evidence, and ambiguous-region inspection.
- Implement content-addressed quota/retention, visible degradation, tombstones, exports, and free-space preflight.
- Add supplemental OSLog/signposts and Developer Diagnostics.
- Complete keyboard, VoiceOver, contrast, reduced motion, Differentiate Without Color, and textual chart summaries.
- Non-goal: no new drawing source, model family, or optional image-processing feature.

### Domain objects and module changes

- Bounded workspace projections: authority, execution, evidence, model, canvas, recovery, storage.
- `ArtifactManifest`, `ArtifactTombstone`, retention policy/version, export manifest.
- Replay reducer, analysis-fork metadata, recovery intents and consequences.

### Acceptance criteria

- UI never calculates readiness, evidence acceptance, model promotion, or remaining work.
- Every disabled action has a visible domain blocker and permitted recovery intents.
- Recorded Replay reconstructs identical semantic state/frontiers/blockers/decisions; Algorithm Re-evaluation cannot mutate history/live state.
- Crash at every checkpoint and command boundary never blindly resends or skips unresolved work.
- Storage pressure never silently removes required evidence or allows an unrecordable draw.
- Operator study participants can state why execution stopped and the next safe action without developer logs.

### Tests and recorded evidence required before advancing

- Projection/golden overlay/pan-zoom hit-test/UI automation/accessibility tests.
- Replay equivalence and algorithm-drift comparison tests.
- Retention/quota/tombstone/export/WAL/garbage-collection tests.
- Crash/restart and recovery fixtures for every frontier/failure class.
- Performance signposts for capture-to-measurement, command-to-Idle, stable frame, fit, plan, and transaction latency.

### Required observable UI/debug outputs

- Authority and motion-control actions always visible.
- Expected/predicted/observed/residual layers; current/candidate model values and applicability; accepted/rejected trial history.
- Recorded Replay/Algorithm Re-evaluation mode banners and degraded-artifact visibility.
- Storage quota/free-space/run-bundle completeness.
- Developer raw serial, image stages, matrices, fit/inverse diagnostics, actor/task timelines, and ledger events.

### Retain/delete/migration decisions

- Retain no in-memory clearable operator log as the only evidence.
- OSLog remains supplemental; semantic ledger remains product truth.
- Delete any hidden developer-only blocker or recovery path.

### Risks or assumptions to resolve before phase 10

- Verify operator terminology: “controller completed” must not be interpreted as ink success.
- Ensure replay UI does not imply that re-evaluated results changed historical physical reality.

## Phase 10 — Deliberate capability expansion

### Objective

Add portraits, richer vector geometry, pen learning, advanced vision, scheduling, and optional operator tools one capability at a time through the canonical architecture, only when recorded evidence supports each addition.

### Scope and explicit non-goals

Execute these as separate gated subphases; do not batch them:

1. **Portrait source adapter:** captured/imported raster -> one deterministic `DrawingProgram` -> normal preview/execution/ink loop.
2. **Richer vector geometry:** cubic paths or additional primitives only after deterministic flattening/compilation evidence.
3. **Pen/servo learning:** contact/onset/release/width/feed model from controlled factorial trials; never hide it inside XY correction.
4. **Advanced vision modes:** new observation request/result plus corpus/replay evidence; no new authority owner.
5. **Risk-bounded inspection grouping or remaining-stroke scheduling:** pure strategy compared with fixed every-stroke baseline; do not call it MPC unless it truly solves a constrained finite horizon.
6. **Optional UI tools:** add only when they expose a delivered domain capability; never create system truth.

Non-goals:

- No plugin registry until a demonstrated second independent implementation requires a stable protocol.
- No neural correction model without a recorded dataset, uncertainty/extrapolation story, and decisive holdout advantage.
- No live Python research result, external process, or alternate execution lane.

### Domain objects and module changes

- New drawing sources are pure converters returning `DrawingProgram`.
- New observation types are versioned `MeasurementRequest/Result` values handled by the existing capture/vision/evidence boundaries.
- New overlays are pure projections of recorded/domain facts.
- New pen capabilities extend typed `PenProfile`/`PenMarkModel` and controller compilation.
- New strategies produce finite `ExecutionPlan` revisions using the same interpreter/frontier/checkpoint invariants.

### Acceptance criteria

For each subphase:

- A named user capability and exact non-goals are documented.
- Recorded corpus and controlled physical holdouts show improvement over the current baseline.
- The addition creates no new authority, runtime process, bus, compatibility path, or duplicate state model.
- Existing one-stroke and multi-stroke adaptive/recovery/replay suites remain green.
- Model/algorithm complexity can be rejected and the simpler implementation retained.

Portrait-specific acceptance:

- The previewed `DrawingProgram` hash is the program executed.
- Every portrait stroke uses the same typed plan, safety, ink observation, residual, checkpoint, ledger, and remaining-work path as hand-authored vectors.
- Cap movement is still not portrait/drawing success; actual ink evidence remains required.

### Tests and recorded evidence required before advancing each subphase

- Fixed source/vision corpus with algorithm/configuration hashes.
- Pure deterministic conversion/geometry tests.
- Recorded Replay and Algorithm Re-evaluation comparisons.
- Simulated/fault/recovery suite.
- Controlled physical runs with grouped holdouts and explicit product metrics.
- Forbidden live Python/HTTP/duplicate-authority scans.

### Required observable UI/debug outputs

- New capability's source settings/provenance, resulting `DrawingProgram`, preview, and applicability.
- Same core authority/frontier/evidence/model/recovery truth; no separate workflow screen.
- Before/after algorithm/model comparison and rejected evidence.
- Developer diagnostics only for the new computation, linked to the same run IDs.

### Retain/delete/migration decisions

- Delete obsolete algorithms/UI when a replacement is selected; do not keep aliases or hidden fallback execution paths.
- Keep offline research outputs outside live authority and import them only as explicitly reviewed, versioned experimental data.
- At the end, scan the tracked tree for all retired Python live imports, bridge/routes/DTOs, old wizard/readiness names, demo/capability surfaces, and compatibility code; remove every unproven survivor.

### Risks or assumptions to resolve before the next capability

- Do not assume a feature is valuable because it existed before.
- Stop expansion when adaptive drawing/recovery metrics regress or evidence coverage is insufficient.
- Prefer a direct new value/function over an extension framework until repeated implementations prove a boundary.

## Completion definition

The rebuild is complete only when:

- the signed native app is the only live product process;
- a logical drawing is executed, observed as actual ink, compared, conservatively adapted, and replanned only for uncommanded work;
- every meaningful command, frame, observation, residual, decision, model, blocker, and recovery is visible and replayable;
- no “calibrated” flag or cap-only fact can grant drawing authority;
- ambiguous physical work is never automatically redrawn;
- legacy live Python/HTTP/Swift bridge/workflow/compatibility surfaces and their obsolete tests are deleted;
- Python, if retained, is visibly offline-only and cannot write or participate in live authority;
- deterministic tests, simulator/replay, controlled physical trials, Swift build, repo validation, and clean landed `main` all pass.
