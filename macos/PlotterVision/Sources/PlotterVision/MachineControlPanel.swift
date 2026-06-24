import SwiftUI

struct MachineControlPanel: View {
    @ObservedObject var bridge: PlotterBridgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statusGrid
            hardwareControls
            Text(bridge.manualMotionGateMessage)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(manualMotionGateColor)
                .lineLimit(2)

            Divider()
                .overlay(Color.white.opacity(0.16))

            jogPad
            manualJogOverrideControl
            stepAndFeed

            Divider()
                .overlay(Color.white.opacity(0.16))

            commandRows

            Text(bridge.machineStatus)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.56))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.32), radius: 18, x: 0, y: 10)
    }

    private var header: some View {
        HStack(spacing: 9) {
            PanelConnectionDot(bridge: bridge)
            VStack(alignment: .leading, spacing: 2) {
                Text("Machine")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(bridge.activeAction.isEmpty ? bridge.shortStatus : bridge.activeAction.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
            Spacer()
            iconButton(systemName: "arrow.clockwise", help: "Reconnect machine status") {
                Task {
                    await bridge.refreshHealth()
                    await bridge.reconnectMachine()
                }
            }
        }
    }

    private var statusGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            GridRow {
                statusLabel("State")
                statusValue(bridge.machineState)
            }
            GridRow {
                statusLabel("Pins")
                statusValue(bridge.machinePins)
            }
            GridRow {
                statusLabel("FS")
                statusValue(bridge.machineFeedSpindle.replacingOccurrences(of: "FS ", with: ""))
            }
            GridRow {
                statusLabel("MPos")
                statusValue(bridge.machineMPos.replacingOccurrences(of: "M ", with: ""))
            }
            GridRow {
                statusLabel("WPos")
                statusValue(bridge.machineWPos.replacingOccurrences(of: "W ", with: ""))
            }
            GridRow {
                statusLabel("Mode")
                statusValue(bridge.motionModeLabel)
            }
            GridRow {
                statusLabel("Arm")
                statusValue(bridge.armStatusLabel)
            }
        }
    }

    private var hardwareControls: some View {
        VStack(spacing: 9) {
            commandButton(
                systemName: bridge.plotterConnectionSystemName,
                title: bridge.plotterConnectionTitle,
                disabled: !bridge.canUsePlotterConnectionControl,
                isActive: bridge.isLiveMotionMode
            ) {
                Task { await bridge.connectPlotter() }
            }
            HStack(spacing: 9) {
                commandButton(
                    systemName: "link",
                    title: "Probe",
                    disabled: !bridge.canConnectHardware
                ) {
                    Task { await bridge.reconnectMachine() }
                }
                commandButton(
                    systemName: "shield",
                    title: "Dry Run",
                    disabled: !bridge.canDisarmHardware
                ) {
                    Task { await bridge.disarmHardware() }
                }
            }
        }
    }

    private var jogPad: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.34))
                .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
                .frame(width: 150, height: 150)

            VStack(spacing: 9) {
                jogButton(systemName: "arrow.up", axis: "Y", distance: bridge.manualStepMm)
                    .keyboardShortcut(.upArrow, modifiers: [])
                HStack(spacing: 32) {
                    jogButton(systemName: "arrow.left", axis: "X", distance: -bridge.manualStepMm)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    iconButton(systemName: "scope", help: "Center plotter") {
                        Task { await bridge.centerMachine() }
                    }
                    .disabled(commandDisabled)
                    jogButton(systemName: "arrow.right", axis: "X", distance: bridge.manualStepMm)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                }
                jogButton(systemName: "arrow.down", axis: "Y", distance: -bridge.manualStepMm)
                    .keyboardShortcut(.downArrow, modifiers: [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var stepAndFeed: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Step", selection: $bridge.manualStepMm) {
                Text("0.5").tag(0.5)
                Text("1").tag(1.0)
                Text("2").tag(2.0)
                Text("5").tag(5.0)
                Text("10").tag(10.0)
                Text("25").tag(25.0)
                Text("50").tag(50.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(commandDisabled)

            HStack(spacing: 10) {
                Image(systemName: "speedometer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .frame(width: 18)
                Slider(value: $bridge.manualFeedMmMin, in: 60.0...bridge.machineMaxFeedMmMin, step: 10.0)
                    .tint(.cyan)
                Text(String(format: "%.0f", bridge.manualFeedMmMin))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    private var manualJogOverrideControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: Binding(
                get: { bridge.manualJogWorkspaceOverride },
                set: { bridge.setManualJogWorkspaceOverride($0) }
            )) {
                Label("Unsafe Boundary Override", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(bridge.manualJogWorkspaceOverride ? .orange.opacity(0.95) : .white.opacity(0.76))
            }
            .toggleStyle(.checkbox)
            .disabled(bridge.isRunning || bridge.isMachineBusy)
            .help("Bypass projected workspace bounds for Machine-panel jog arrows only.")

            if bridge.manualJogWorkspaceOverride {
                Text("UNSAFE JOG WORKSPACE GUARD OFF")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.95))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
    }

    private var commandRows: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                commandButton(
                    systemName: "stop.fill",
                    title: "Stop",
                    disabled: stopDisabled,
                    isDestructive: true
                ) {
                    Task { await bridge.stopMachine() }
                }
                commandButton(
                    systemName: "lock.open",
                    title: "Clear Alarm",
                    disabled: unlockDisabled
                ) {
                    Task { await bridge.clearAlarmMachine() }
                }
                commandButton(
                    systemName: "play.fill",
                    title: "Resume",
                    disabled: resumeDisabled
                ) {
                    Task { await bridge.resumeMachine() }
                }
            }
            HStack(spacing: 9) {
                commandButton(systemName: "arrow.up.to.line", title: "Pen Up") {
                    Task { await bridge.penUpMachine() }
                }
                commandButton(systemName: "arrow.down.to.line", title: "Pen Down") {
                    Task { await bridge.penDownMachine() }
                }
            }
            HStack(spacing: 9) {
                commandButton(systemName: "house", title: "Home") {
                    Task { await bridge.homeMachine() }
                }
                commandButton(systemName: "scope", title: "Center") {
                    Task { await bridge.centerMachine() }
                }
            }
        }
    }

    private var commandDisabled: Bool {
        bridge.isRunning || bridge.isMachineBusy || bridge.isMachineAlarm || !bridge.isLiveMotionMode
    }

    private var stopDisabled: Bool {
        !bridge.isLiveMotionMode || bridge.machineState.hasPrefix("Hold") || (!bridge.isRunning && !bridge.isMachineBusy)
    }

    private var unlockDisabled: Bool {
        bridge.isRunning || bridge.isMachineBusy || !bridge.isLiveMotionMode || !bridge.isMachineAlarm
    }

    private var resumeDisabled: Bool {
        bridge.isRunning || !bridge.isLiveMotionMode || bridge.isMachineAlarm || !bridge.machineState.hasPrefix("Hold")
    }

    private var manualMotionGateColor: Color {
        if bridge.manualJogWorkspaceOverride { return .orange.opacity(0.95) }
        return bridge.isLiveMotionMode ? .green.opacity(0.86) : .orange.opacity(0.92)
    }

    private func jogButton(systemName: String, axis: String, distance: Double) -> some View {
        iconButton(systemName: systemName, help: "Jog \(axis)") {
            Task { await bridge.jog(axis: axis, distanceMm: distance) }
        }
        .disabled(commandDisabled)
    }

    private func commandButton(
        systemName: String,
        title: String,
        disabled: Bool? = nil,
        isActive: Bool = false,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let isDisabled = disabled ?? commandDisabled
        let fillColor = isActive
            ? Color.green.opacity(0.28)
            : isDestructive
            ? Color.red.opacity(isDisabled ? 0.08 : 0.24)
            : Color.white.opacity(isDisabled ? 0.06 : 0.12)
        let strokeColor = isActive
            ? Color.green.opacity(0.54)
            : isDestructive
            ? Color.red.opacity(isDisabled ? 0.14 : 0.38)
            : Color.white.opacity(0.14)
        return Button(action: action) {
            Label(title, systemImage: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    isDisabled
                        ? .white.opacity(0.35)
                        : isActive ? .green.opacity(0.96) : .white.opacity(0.9)
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(fillColor)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(strokeColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private func iconButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func statusLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.48))
            .frame(width: 42, alignment: .leading)
    }

    private func statusValue(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.88))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

}

private struct PanelConnectionDot: View {
    @ObservedObject var bridge: PlotterBridgeModel

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 13, height: 13)
            .overlay(Circle().stroke(Color.white.opacity(0.34), lineWidth: 1))
            .help(bridge.machineStatus)
    }

    private var color: Color {
        if bridge.isMachineAlarm { return .red }
        if bridge.isMachineBusy || bridge.isRunning { return .yellow }
        if bridge.isOnline { return bridge.isDryRun ? .orange : .green }
        return .gray
    }
}
