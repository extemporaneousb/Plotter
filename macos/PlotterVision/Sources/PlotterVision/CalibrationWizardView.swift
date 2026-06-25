import SwiftUI

struct CalibrationWizardView: View {
    let instructionText: String
    let fiducialDetail: String
    let fiducialStatus: CalibrationWizardStepStatus
    let greenCapDetail: String
    let greenCapStatus: CalibrationWizardStepStatus
    let visualCalibrationDetail: String
    let visualCalibrationStatus: CalibrationWizardStepStatus
    let bindingDetail: String
    let bindingStatus: CalibrationWizardStepStatus
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
    let reset: () -> Void
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
            Text("Visual Field Setup")
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
            CalibrationWizardStepRow(index: 1, title: "Confirm Green Cap", detail: greenCapDetail, status: greenCapStatus)
            CalibrationWizardStepRow(index: 2, title: "Machine-Video Agreement", detail: visualCalibrationDetail, status: visualCalibrationStatus)
            CalibrationWizardStepRow(index: 3, title: "Define Drawing Field", detail: fiducialDetail, status: fiducialStatus)
            CalibrationWizardStepRow(index: 4, title: "Validate Motion", detail: bindingDetail, status: bindingStatus)
        }
    }

    private var fieldSizeControls: some View {
        HStack(spacing: 8) {
            Text("Field")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.62))
            Stepper(value: fieldWidthBinding, in: 40...400, step: 5) {
                Text(String(format: "X %.0fmm", fieldWidthMm))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .help(hasPaperLock ? "Reset setup before changing locked field width" : "Drawing field width in millimeters")
            Stepper(value: fieldHeightBinding, in: 30...fieldHeightUpperBound, step: 5) {
                Text(String(format: "Y %.0fmm", fieldHeightMm))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .help(hasPaperLock ? "Reset setup before changing locked field height" : "Drawing field height in millimeters")
        }
        .controlSize(.mini)
        .disabled(hasPaperLock)
    }

    private var fieldHeightUpperBound: Double {
        min(300.0, max(30.0, fieldWidthMm))
    }

    private var fieldWidthBinding: Binding<Double> {
        Binding(
            get: { fieldWidthMm },
            set: { newValue in
                fieldWidthMm = min(400.0, max(40.0, newValue))
                if fieldHeightMm > fieldWidthMm {
                    fieldHeightMm = fieldWidthMm
                }
            }
        )
    }

    private var fieldHeightBinding: Binding<Double> {
        Binding(
            get: { fieldHeightMm },
            set: { newValue in
                fieldHeightMm = min(fieldHeightUpperBound, max(30.0, newValue))
            }
        )
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: primaryAction) {
                Label(
                    primaryActionTitle,
                    systemImage: primaryActionEnabled ? "arrow.right.circle.fill" : "lock.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(primaryActionEnabled ? .cyan : .gray)
            .disabled(!primaryActionEnabled)
            .help(primaryActionDisabledReason ?? primaryActionTitle)

            Button("Reset", action: reset)
                .buttonStyle(.bordered)
        }
        .controlSize(.small)
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
