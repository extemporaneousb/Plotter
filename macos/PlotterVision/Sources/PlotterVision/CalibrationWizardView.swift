import SwiftUI

struct CalibrationWizardView: View {
    let instructionText: String
    let fiducialDetail: String
    let fiducialStatus: CalibrationWizardStepStatus
    let paperDetail: String
    let paperStatus: CalibrationWizardStepStatus
    let greenCapDetail: String
    let greenCapStatus: CalibrationWizardStepStatus
    let capPositionDetail: String
    let capPositionStatus: CalibrationWizardStepStatus
    let visualCalibrationDetail: String
    let visualCalibrationStatus: CalibrationWizardStepStatus
    let bindingDetail: String
    let bindingStatus: CalibrationWizardStepStatus
    let primaryActionTitle: String
    let primaryActionEnabled: Bool
    let primaryActionDisabledReason: String?
    let manualFiducialCount: Int
    let hasPaperLock: Bool
    let capStateLabel: String
    let isLiveMotionMode: Bool
    let capDetected: Bool
    let canMoveXIntoCameraField: Bool
    let canConfirmSetup: Bool
    let primaryAction: () -> Void
    let confirmSetup: () -> Void
    let reset: () -> Void
    let clickCap: () -> Void
    let clickPenTip: () -> Void
    let stepAction: (Int) -> Void
    let moveXIntoCameraField: () -> Void
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
            CalibrationWizardStepRow(index: 1, title: "Fiducials", detail: fiducialDetail, status: fiducialStatus, onSelect: { stepAction(1) })
            CalibrationWizardStepRow(index: 2, title: "Visual Field", detail: paperDetail, status: paperStatus, onSelect: { stepAction(2) })
            CalibrationWizardStepRow(index: 3, title: "Tool", detail: capPositionDetail, status: capPositionStatus, onSelect: { stepAction(3) })
            CalibrationWizardStepRow(index: 4, title: "Visual-Machine", detail: visualCalibrationDetail, status: visualCalibrationStatus, onSelect: { stepAction(4) })
            CalibrationWizardStepRow(index: 5, title: "Draw/Verify", detail: bindingDetail, status: bindingStatus, onSelect: { stepAction(5) })
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
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

                Button("Confirm Setup", action: confirmSetup)
                    .buttonStyle(.bordered)
                    .disabled(!canConfirmSetup)
                    .help("Reuse the locked visual field when the visible grid still matches the setup")

                Button("Reset", action: reset)
                    .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                Button("Click Cap", action: clickCap)
                    .buttonStyle(.bordered)
                    .disabled(!hasPaperLock)

                Button("Click Pen Tip", action: clickPenTip)
                    .buttonStyle(.bordered)
                    .disabled(!hasPaperLock)

                Button("Move Field", action: moveXIntoCameraField)
                    .buttonStyle(.bordered)
                    .disabled(!canMoveXIntoCameraField)
                    .help("Live bounded X recovery jog when the cap is parked outside the camera field")
            }
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
            Text(String(format: "FID %d/4  FIELD %@  CAP %@  LIVE %@",
                        manualFiducialCount,
                        hasPaperLock ? "LOCK" : "--",
                        capStateLabel,
                        isLiveMotionMode ? "YES" : "NO"))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.54))
        }
    }
}
