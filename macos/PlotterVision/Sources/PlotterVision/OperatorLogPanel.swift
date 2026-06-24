import SwiftUI

struct OperatorLogPanel: View {
    @ObservedObject var workspace: OperatorWorkspaceState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.cyan)
                Text("Operator Log")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Button {
                    workspace.operatorLog = []
                    workspace.appendOperatorLog("Log cleared", source: "Log")
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Clear the visible operator log")
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(workspace.operatorLog) { entry in
                            OperatorLogRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .onChange(of: workspace.operatorLog.last?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 560, minHeight: 420)
        .background(Color.black.opacity(0.94))
    }
}

private struct OperatorLogRow: View {
    let entry: OperatorLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.timestampLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.52))
                .frame(width: 56, alignment: .leading)
            Text(entry.level.rawValue)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(levelColor)
                .frame(width: 36, alignment: .leading)
            Text(entry.source)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.74))
                .frame(width: 72, alignment: .leading)
            Text(entry.message)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.86))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var levelColor: Color {
        switch entry.level {
        case .info:
            return .white.opacity(0.64)
        case .warning:
            return .yellow.opacity(0.9)
        case .error:
            return .red.opacity(0.92)
        }
    }
}
