import Foundation
import SwiftUI

struct CalibrationWizardView: View {
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

    var body: some View {
        VStack {
            HStack {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 10) {
                    header
                    Text(instructionText)
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
                        title: step.label,
                        detail: step.detail,
                        status: CalibrationWizardStepStatus(workflowState: step.state)
                    )
                }
            } else {
                CalibrationWizardStepRow(index: 1, title: "Confirm Green Cap", detail: greenCapDetail, status: greenCapStatus)
                CalibrationWizardStepRow(index: 2, title: "Machine-Video Agreement", detail: visualCalibrationDetail, status: visualCalibrationStatus)
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
            fieldDimensionControl(label: "X", value: fieldWidthBinding)
                .help(hasPaperLock ? "Adjust X millimeters and re-lock the current video field" : "Drawing field X millimeters")
            fieldDimensionControl(label: "Y", value: fieldHeightBinding)
                .help(hasPaperLock ? "Adjust Y millimeters and re-lock the current video field" : "Drawing field Y millimeters")
        }
        .controlSize(.mini)
    }

    private func fieldDimensionControl(label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.58))
            TextField(label, value: value, formatter: Self.fieldDimensionFormatter)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 58)
                .multilineTextAlignment(.trailing)
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

    private var fieldWidthBinding: Binding<Double> {
        Binding(
            get: { fieldWidthMm },
            set: { newValue in
                fieldWidthMm = clampedFieldDimension(newValue)
            }
        )
    }

    private var fieldHeightBinding: Binding<Double> {
        Binding(
            get: { fieldHeightMm },
            set: { newValue in
                fieldHeightMm = clampedFieldDimension(newValue)
            }
        )
    }

    private func clampedFieldDimension(_ value: Double) -> Double {
        min(fieldDimensionRange.upperBound, max(fieldDimensionRange.lowerBound, value))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: primaryAction) {
                Label(
                    workflow?.nextPrimaryAction.label ?? primaryActionTitle,
                    systemImage: primaryActionEnabled ? "arrow.right.circle.fill" : "lock.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(primaryActionEnabled ? .cyan : .gray)
            .disabled(!primaryActionEnabled)
            .help(primaryActionDisabledReason ?? primaryActionTitle)

            if showsDrawingTrainingReset {
                Button("Reset Training", action: resetDrawingTraining)
                    .buttonStyle(.bordered)
                    .disabled(!hasDrawingTrainingArtifacts)
            }

            if showsVisionMachineReset {
                Button(role: .destructive, action: resetVisionMachine) {
                    Label("Full Reset", systemImage: "exclamationmark.triangle")
                }
                .buttonStyle(.bordered)
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
            "ready_to_draw",
            "blocked"
        ].contains(phase)
    }

    @ViewBuilder
    private var blockedReason: some View {
        if let primaryActionDisabledReason {
            Text("Blocked: \(primaryActionDisabledReason)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.orange.opacity(0.86))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: some View {
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
