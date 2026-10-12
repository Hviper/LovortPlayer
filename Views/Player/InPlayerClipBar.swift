import SwiftUI

public struct InPlayerClipBar: View {
    @ObservedObject var viewModel: PlayerViewModel
    public var onExport: (TimeInterval, TimeInterval) -> Void

    public init(viewModel: PlayerViewModel, onExport: @escaping (TimeInterval, TimeInterval) -> Void) {
        self.viewModel = viewModel
        self.onExport = onExport
    }

    public var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: {
                    withAnimation { viewModel.isClipMode = false }
                }) {
                    Text("取消")
                        .foregroundColor(.white.opacity(0.7))
                        .font(.system(size: 14))
                }

                Spacer()

                Text("无损片段裁切 (GOP 极速复制)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))

                Spacer()

                Button(action: {
                    onExport(viewModel.clipStartTime, viewModel.clipEndTime)
                }) {
                    Text("完成导出")
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.cyan)
                        .foregroundColor(.black)
                        .clipShape(Capsule())
                }
            }

            // 裁剪区间指示器
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("起点 (In)")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                    Text(formatTime(viewModel.clipStartTime))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }

                Spacer()

                Text("时长: \(formatTime(max(0, viewModel.clipEndTime - viewModel.clipStartTime)))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.cyan)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("终点 (Out)")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                    Text(formatTime(viewModel.clipEndTime))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let millis = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%02d:%02d.%02d", mins, secs, millis)
    }
}
