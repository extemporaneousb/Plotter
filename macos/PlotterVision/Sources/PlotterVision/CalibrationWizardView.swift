import Foundation
import SwiftUI

struct CalibrationWizardView: View {
    private enum FieldDimension: Hashable {
        case width
        case height
    }

    let workflow: BridgeCalibrationWorkflow?
    let primaryActionEnabled: Bool
    let primaryActionDisabledReason: String?
    let hasPaperLock: Bool
    let capStateLabel: String
    let isLiveMotionMode: Bool
    let capDetected: Bool
    @Binding var fieldWidthMm: Double
    @Binding var fieldHeightMm: Double
    let primaryAction: () -> Void
    let resetAction: (BridgeCalibrationWorkflowResetAction) -> Void
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
                        title: step.label,
                        detail: step.detail,
                        status: CalibrationWizardStepStatus(workflowState: step.state)
                    )
                }
            } else {
                CalibrationWizardStepRow(
                    index: 1,
                    title: "Backend Workflow",
                    detail: "Waiting for /calibration/workflow/status",
                    status: .active
                )
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
                    workflow?.nextPrimaryAction.label ?? "Refresh Workflow",
                    systemImage: workflow == nil ? "arrow.clockwise" : (primaryActionEnabled ? "arrow.right.circle.fill" : "lock.fill")
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(workflow == nil ? .yellow : (primaryActionEnabled ? .cyan : .gray))
            .disabled(workflow != nil && !primaryActionEnabled)
            .help(workflow == nil ? "Refresh backend workflow status" : (primaryActionDisabledReason ?? workflow?.currentBlocker ?? workflow?.nextPrimaryAction.label ?? "Backend workflow action"))

            if let workflow {
                ForEach(workflow.resetActions) { action in
                    Button(role: resetButtonRole(action.role)) {
                        resetAction(action)
                    } label: {
                        Label(action.label, systemImage: resetButtonSystemImage(action.role))
                    }
                    .buttonStyle(.bordered)
                    .disabled(!action.enabled)
                    .help(action.help)
                }
            }
        }
        .controlSize(.small)
    }

    private func resetButtonRole(_ role: String) -> ButtonRole? {
        role == "destructive" ? .destructive : nil
    }

    private func resetButtonSystemImage(_ role: String) -> String {
        role == "destructive" ? "exclamationmark.triangle" : "arrow.counterclockwise"
    }

    @ViewBuilder
    private var blockedReason: some View {
        if let workflow, let blocker = workflow.currentBlocker, !blocker.isEmpty {
            Text("\(workflow.overlayBadge.label): \(blocker)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(workflowColor(workflow.overlayBadge.color))
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
                        value: displayWorkflowToken(workflow.phase),
                        systemImage: "list.bullet.rectangle"
                    )
                    workflowStateItem(
                        title: "ACTIVITY",
                        value: displayWorkflowToken(workflow.activity),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    workflowStateItem(
                        title: "HEALTH",
                        value: displayWorkflowToken(workflow.health),
                        systemImage: "circle.fill",
                        color: workflowColor(workflow.overlayBadge.color)
                    )
                }
                if workflow.overlayBadge.state != workflow.health {
                    Label(workflow.overlayBadge.label, systemImage: "scope")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(workflowColor(workflow.overlayBadge.color))
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
        guard let workflow else { return "Waiting for backend workflow status." }
        if workflow.readyToDraw {
            return "Ready to Draw"
        }
        if let blocker = workflow.currentBlocker, !blocker.isEmpty {
            return blocker
        }
        return "\(displayWorkflowToken(workflow.activity)): \(workflow.nextPrimaryAction.label)"
    }

    private func displayWorkflowToken(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func workflowColor(_ color: String) -> Color {
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
