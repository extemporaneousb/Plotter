import Foundation
import SwiftUI

struct CalibrationWizardView: View {
    private enum FieldDimension: Hashable {
        case width
        case height
    }

    let workflow: BridgeCalibrationWorkflow?
    let instructionText: String
    let fiducialDetail: String
    let fiducialStatus: CalibrationWizardStepStatus
    let greenCapDetail: String
    let greenCapStatus: CalibrationWizardStepStatus
    let visualCalibrationDetail: String
    let visualCalibrationStatus: CalibrationWizardStepStatus
    let bindingDetail: String
    let bindingStatus: CalibrationWizardStepStatus
    let drawingCalibrationDetail: String
    let drawingCalibrationStatus: CalibrationWizardStepStatus
    let primaryActionTitle: String
    let primaryActionEnabled: Bool
    let primaryActionDisabledReason: String?
    let hasPaperLock: Bool
    let capStateLabel: String
    let isLiveMotionMode: Bool
    let capDetected: Bool
    @Binding var fieldWidthMm: Double
    @Binding var fieldHeightMm: Double
    let primaryAction: () -> Void
    let resetVisionMachine: () -> Void
    let resetDrawingTraining: () -> Void
    let hide: () -> Void
    @FocusState private var focusedFieldDimension: FieldDimension?
    @State private var fieldWidthText = ""
    @State private var fieldHeightText = ""

    var body: some View {
        VStack {
            HStack {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 10) {
                    header
                    workflowStateStrip
                    Text(operatorInstructionText)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    fieldSizeControls
                    steps
                    actions
                    blockedReason
                    summary
                }
                .frame(width: 390, alignment: .leading)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
            }
            .padding(.top, 84)
            .padding(.horizontal, 18)
            Spacer(minLength: 0)
        }
        .onAppear {
            syncDimensionTextFromBindings(force: true)
        }
        .onChange(of: fieldWidthMm) { _, _ in
            syncDimensionTextFromBindings(force: false)
        }
        .onChange(of: fieldHeightMm) { _, _ in
            syncDimensionTextFromBindings(force: false)
        }
        .onChange(of: focusedFieldDimension) { previousField, _ in
            if let previousField {
                commitFieldDimension(previousField)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist.checked")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.cyan)
            Text("Calibrate Vision-Machine Interface")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
            Spacer(minLength: 0)
            Button(action: hide) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Hide visual field setup")
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let workflow {
                ForEach(Array(workflow.steps.enumerated()), id: \.element.id) { offset, step in
                    CalibrationWizardStepRow(
                        index: offset + 1,
                        title: operatorWorkflowStepTitle(step),
                        detail: step.detail,
                        status: CalibrationWizardStepStatus(workflowState: step.state)
                    )
                }
            } else {
                CalibrationWizardStepRow(index: 1, title: "Confirm Green Cap", detail: greenCapDetail, status: greenCapStatus)
                CalibrationWizardStepRow(index: 2, title: "Field Registration Probe", detail: visualCalibrationDetail, status: visualCalibrationStatus)
                CalibrationWizardStepRow(index: 3, title: "Set Drawing Border", detail: fiducialDetail, status: fiducialStatus)
                CalibrationWizardStepRow(index: 4, title: "Validate Motion", detail: bindingDetail, status: bindingStatus)
                CalibrationWizardStepRow(index: 5, title: "Drawing Training", detail: drawingCalibrationDetail, status: drawingCalibrationStatus)
            }
        }
    }

    private var fieldSizeControls: some View {
        HStack(spacing: 8) {
            Text("Field")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.62))
            fieldDimensionControl(label: "X", field: .width, text: $fieldWidthText)
                .help(hasPaperLock ? "Adjust X millimeters and re-lock the current video field" : "Drawing field X millimeters")
            fieldDimensionControl(label: "Y", field: .height, text: $fieldHeightText)
                .help(hasPaperLock ? "Adjust Y millimeters and re-lock the current video field" : "Drawing field Y millimeters")
        }
        .controlSize(.mini)
    }

    private func fieldDimensionControl(label: String, field: FieldDimension, text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.58))
            TextField(label, text: text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 58)
                .multilineTextAlignment(.trailing)
                .focused($focusedFieldDimension, equals: field)
                .onSubmit {
                    commitFieldDimension(field)
                }
            Text("mm")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.50))
        }
    }

    private static let fieldDimensionFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        formatter.usesGroupingSeparator = false
        return formatter
    }()

    private var fieldDimensionRange: ClosedRange<Double> {
        1.0...1000.0
    }

    private func clampedFieldDimension(_ value: Double) -> Double {
        min(fieldDimensionRange.upperBound, max(fieldDimensionRange.lowerBound, value))
    }

    private func formattedFieldDimension(_ value: Double) -> String {
        let clamped = clampedFieldDimension(value)
        return Self.fieldDimensionFormatter.string(from: NSNumber(value: clamped)) ?? String(format: "%.1f", clamped)
    }

    private func syncDimensionTextFromBindings(force: Bool) {
        if force || focusedFieldDimension != .width {
            fieldWidthText = formattedFieldDimension(fieldWidthMm)
        }
        if force || focusedFieldDimension != .height {
            fieldHeightText = formattedFieldDimension(fieldHeightMm)
        }
    }

    private func commitFieldDimension(_ field: FieldDimension) {
        let currentValue = field == .width ? fieldWidthMm : fieldHeightMm
        let rawText = field == .width ? fieldWidthText : fieldHeightText
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(trimmed), parsed.isFinite else {
            setFieldDimensionText(field, formattedFieldDimension(currentValue))
            return
        }

        let clampedValue = clampedFieldDimension(parsed)
        switch field {
        case .width:
            fieldWidthMm = clampedValue
        case .height:
            fieldHeightMm = clampedValue
        }
        setFieldDimensionText(field, formattedFieldDimension(clampedValue))
    }

    private func setFieldDimensionText(_ field: FieldDimension, _ text: String) {
        switch field {
        case .width:
            fieldWidthText = text
        case .height:
            fieldHeightText = text
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: primaryAction) {
                Label(
                    operatorPrimaryActionTitle,
                    systemImage: primaryActionEnabled ? "arrow.right.circle.fill" : "lock.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(primaryActionEnabled ? .cyan : .gray)
            .disabled(!primaryActionEnabled)
            .help(operatorPrimaryActionHelp)

            if showsDrawingTrainingReset {
                Button("Reset Training", action: resetDrawingTraining)
                    .buttonStyle(.bordered)
                    .disabled(!hasDrawingTrainingArtifacts)
                    .help("Clears only drawing-session and drawing-model pointers; vision-machine setup stays current.")
            }

            if showsVisionMachineReset {
                Button(role: .destructive, action: resetVisionMachine) {
                    Label("Full Reset", systemImage: "exclamationmark.triangle")
                }
                .buttonStyle(.bordered)
                .help("Clears cap confirmation, Drawing Border, motion evidence, training session, and drawing model pointers.")
            }
        }
        .controlSize(.small)
    }

    private var hasDrawingTrainingArtifacts: Bool {
        workflow?.freshness.drawingSessionId != nil || workflow?.freshness.drawingModelId != nil
    }

    private var showsDrawingTrainingReset: Bool {
        hasDrawingTrainingArtifacts || isDrawingTrainingPhase
    }

    private var showsVisionMachineReset: Bool {
        guard let phase = workflow?.phase else { return true }
        return !isDownstreamDrawingPhase(phase)
    }

    private var isDrawingTrainingPhase: Bool {
        guard let phase = workflow?.phase else { return false }
        return isDownstreamDrawingPhase(phase)
    }

    private func isDownstreamDrawingPhase(_ phase: String) -> Bool {
        [
            "motion_validated",
            "pen_ready",
            "drawing_training",
            "drawing_retry",
            "drawing_validated",
            "ready_to_draw"
        ].contains(phase)
    }

    @ViewBuilder
    private var blockedReason: some View {
        if let workflowIssueText {
            Text("\(workflowIssueTitle): \(workflowIssueText)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(workflowIssueColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else if let primaryActionDisabledReason {
            Text("Blocked: \(primaryActionDisabledReason)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.orange.opacity(0.86))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Label(capDetected ? "cap detected" : "cap not detected", systemImage: "circle.fill")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(capDetected ? .green.opacity(0.92) : .yellow.opacity(0.86))
                Text(String(format: "FIELD %@  CAP %@  LIVE %@",
                            hasPaperLock ? "LOCK" : "--",
                            capStateLabel,
                            isLiveMotionMode ? "YES" : "NO"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.54))
            }
        }
    }

    @ViewBuilder
    private var workflowStateStrip: some View {
        if let workflow {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    workflowStateItem(
                        title: "PHASE",
                        value: workflowPhaseLabel(workflow.phase),
                        systemImage: "list.bullet.rectangle"
                    )
                    workflowStateItem(
                        title: "ACTIVITY",
                        value: workflowActivityLabel(workflow.activity),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    workflowStateItem(
                        title: "HEALTH",
                        value: workflowHealthLabel(workflow.health),
                        systemImage: workflowHealthSystemImage(workflow.health),
                        color: workflowHealthColor(workflow.health)
                    )
                }
                if workflow.overlayBadge.state != workflow.health {
                    Label(workflow.overlayBadge.label, systemImage: "scope")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(workflowBadgeColor(workflow.overlayBadge.color))
                        .lineLimit(1)
                }
            }
        }
    }

    private func workflowStateItem(
        title: String,
        value: String,
        systemImage: String,
        color: Color = .white.opacity(0.66)
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.40))
                Text(value)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var operatorInstructionText: String {
        guard let workflow else { return instructionText }
        if workflow.readyToDraw {
            return "Ready to Draw"
        }
        if let issue = workflowIssueText {
            return issue
        }
        return "\(workflowActivityLabel(workflow.activity)): \(operatorWorkflowActionLabel(workflow.nextPrimaryAction))"
    }

    private var operatorPrimaryActionTitle: String {
        if let action = workflow?.nextPrimaryAction {
            return operatorWorkflowActionLabel(action)
        }
        return primaryActionTitle
    }

    private var operatorPrimaryActionHelp: String {
        primaryActionDisabledReason
            ?? workflow?.currentBlocker
            ?? operatorPrimaryActionTitle
    }

    private var workflowIssueText: String? {
        guard let workflow else { return nil }
        if let blocker = workflow.currentBlocker, !blocker.isEmpty {
            return blocker
        }
        if workflow.health == "stale" || workflow.health == "stale_and_blocked" {
            return workflow.freshness.staleReasons.first
        }
        return nil
    }

    private var workflowIssueTitle: String {
        guard let workflow else { return "Blocked" }
        switch workflow.health {
        case "stale_and_blocked":
            return "Stale + Blocked"
        case "stale":
            return "Stale"
        default:
            return "Blocked"
        }
    }

    private var workflowIssueColor: Color {
        guard let workflow else { return .orange.opacity(0.86) }
        return workflowHealthColor(workflow.health)
    }

    private func operatorWorkflowActionLabel(_ action: BridgeCalibrationWorkflowAction) -> String {
        switch action.id {
        case "validate_cap_target":
            return "Validate Motion"
        default:
            return operatorWorkflowLabel(action.label)
        }
    }

    private func operatorWorkflowStepTitle(_ step: BridgeCalibrationWorkflowStep) -> String {
        switch step.id {
        case "motion_validation":
            return "Validate Motion"
        default:
            return operatorWorkflowLabel(step.label)
        }
    }

    private func operatorWorkflowLabel(_ label: String) -> String {
        switch label {
        case "Validate Cap Target":
            return "Validate Motion"
        default:
            return label
        }
    }

    private func workflowPhaseLabel(_ phase: String) -> String {
        switch phase {
        case "needs_cap":
            return "Needs Cap"
        case "needs_drawing_border":
            return "Drawing Border"
        case "motion_calibration":
            return "Motion Calibration"
        case "motion_validated":
            return "Motion Validated"
        case "pen_ready":
            return "Pen Ready"
        case "drawing_training":
            return "Drawing Training"
        case "drawing_retry":
            return "Drawing Retry"
        case "drawing_validated":
            return "Drawing Validated"
        case "ready_to_draw":
            return "Ready to Draw"
        default:
            return phase.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func workflowActivityLabel(_ activity: String) -> String {
        switch activity {
        case "idle":
            return "Idle"
        case "confirming_cap":
            return "Confirming Cap"
        case "awaiting_field_registration_probe":
            return "Awaiting Field Probe"
        case "registering_border":
            return "Registering Border"
        case "running_field_registration_probe":
            return "Running Field Probe"
        case "awaiting_motion_probe":
            return "Awaiting Motion Probe"
        case "running_motion_probe":
            return "Running Motion Probe"
        case "awaiting_motion_observation":
            return "Awaiting Motion Observation"
        case "awaiting_pen_ready":
            return "Awaiting Pen Ready"
        case "awaiting_drawing_preview":
            return "Awaiting Preview"
        case "awaiting_drawing_run":
            return "Awaiting Drawing Run"
        case "running_drawing_batch":
            return "Running Drawing Batch"
        case "awaiting_drawing_observation":
            return "Awaiting Ink Observation"
        case "fitting_model":
            return "Fitting Model"
        case "validating_model":
            return "Validating Model"
        case "awaiting_model_promotion":
            return "Awaiting Promotion"
        case "awaiting_drawing_authority":
            return "Awaiting Drawing Authority"
        case "running_machine_action":
            return "Running Machine Action"
        default:
            return activity.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func workflowHealthLabel(_ health: String) -> String {
        switch health {
        case "nominal":
            return "Nominal"
        case "stale":
            return "Stale"
        case "blocked":
            return "Blocked"
        case "stale_and_blocked":
            return "Stale + Blocked"
        default:
            return health.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func workflowHealthSystemImage(_ health: String) -> String {
        switch health {
        case "nominal":
            return "checkmark.circle.fill"
        case "stale":
            return "clock.fill"
        case "blocked", "stale_and_blocked":
            return "exclamationmark.triangle.fill"
        default:
            return "circle.fill"
        }
    }

    private func workflowHealthColor(_ health: String) -> Color {
        switch health {
        case "blocked", "stale_and_blocked":
            return .red.opacity(0.90)
        case "stale":
            return .orange.opacity(0.9)
        default:
            return .white.opacity(0.54)
        }
    }

    private func workflowBadgeColor(_ color: String) -> Color {
        switch color {
        case "green":
            return .green.opacity(0.88)
        case "yellow":
            return .yellow.opacity(0.88)
        case "red":
            return .red.opacity(0.90)
        case "cyan":
            return .cyan.opacity(0.90)
        default:
            return .white.opacity(0.54)
        }
    }
}
