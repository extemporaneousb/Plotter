import SwiftUI

struct OperatorToolbarMenuLabel: View {
    let systemName: String
    let label: String
    let isActive: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.9))
                .frame(width: 32, height: 32)
                .background(isActive ? Color.cyan : Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(isActive ? 0.0 : 0.18), lineWidth: 1)
                )
            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(isActive ? Color.cyan.opacity(0.9) : Color.white.opacity(0.62))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(width: 58)
        }
        .frame(width: 60)
    }
}
