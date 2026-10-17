import SwiftUI

public struct StatusBadgeView: View {
    public let status: ServiceStatus

    public init(status: ServiceStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.statusColor)
                .frame(width: 8, height: 8)

            Text(status.displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(status.statusColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(status.statusColor.opacity(0.12))
        .clipShape(Capsule())
    }
}
