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
            // 顶栏：取消与导出
            HStack {
                Button(action: {
                    withAnimation { viewModel.isClipMode = false }
                }) {
                    Text("取消")
                        .foregroundColor(.white.opacity(0.7))
                        .font(.system(size: 14))
                }

                Spacer()

                Text("无损片段裁切 (可拖拽区间)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))

                Spacer()

                if viewModel.isExportingClip {
                    ProgressView()
                        .tint(.cyan)
                        .scaleEffect(0.8)
                } else {
                    Button(action: {
                        viewModel.exportClip()
                    }) {
                        Text("完成导出")
                            .font(.system(size: 13, weight: .bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.cyan)
                            .foregroundColor(.black)
                            .clipShape(Capsule())
                    }
                }
            }

            // 双游标可视化交互滑块 (用户可直接拖拽起点与终点)
            VStack(spacing: 6) {
                GeometryReader { geo in
                    let totalWidth = max(geo.size.width, 1)
                    let startRatio = max(0, min(1, viewModel.clipStartTime / max(viewModel.duration, 1)))
                    let endRatio = max(0, min(1, viewModel.clipEndTime / max(viewModel.duration, 1)))
                    let currentRatio = max(0, min(1, viewModel.currentTime / max(viewModel.duration, 1)))

                    let startX = startRatio * totalWidth
                    let endX = max(startX + 10, endRatio * totalWidth)

                    ZStack(alignment: .leading) {
                        // 轨道底色
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.12))
                            .frame(height: 12)

                        // 选中的剪辑高亮区域
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.cyan.opacity(0.35))
                            .frame(width: max(0, endX - startX), height: 12)
                            .offset(x: startX)

                        // 视频当前播放进度竖线指示
                        Rectangle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 2, height: 20)
                            .offset(x: currentRatio * totalWidth)

                        // 起点拖拽手柄 [In]
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Image(systemName: "arrowtriangle.right.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.black)
                            )
                            .offset(x: max(0, startX - 13))
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        let newRatio = max(0, min(1, (value.location.x) / totalWidth))
                                        let newTime = newRatio * viewModel.duration
                                        viewModel.clipStartTime = min(newTime, viewModel.clipEndTime - 1.0)
                                        viewModel.seek(to: viewModel.clipStartTime)
                                    }
                            )

                        // 终点拖拽手柄 [Out]
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Image(systemName: "arrowtriangle.left.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.black)
                            )
                            .offset(x: max(0, endX - 13))
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        let newRatio = max(0, min(1, (value.location.x) / totalWidth))
                                        let newTime = newRatio * viewModel.duration
                                        viewModel.clipEndTime = max(newTime, viewModel.clipStartTime + 1.0)
                                        viewModel.seek(to: viewModel.clipEndTime)
                                    }
                            )
                    }
                    .frame(height: 28)
                }
                .frame(height: 28)
                .padding(.horizontal, 6)

                // 快捷打点按钮
                HStack(spacing: 12) {
                    Button(action: {
                        viewModel.clipStartTime = viewModel.currentTime
                        if viewModel.clipEndTime <= viewModel.clipStartTime {
                            viewModel.clipEndTime = min(viewModel.duration, viewModel.clipStartTime + 5)
                        }
                    }) {
                        Text("当前位置设为 In 点")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }

                    Spacer()

                    Button(action: {
                        viewModel.clipEndTime = viewModel.currentTime
                        if viewModel.clipStartTime >= viewModel.clipEndTime {
                            viewModel.clipStartTime = max(0, viewModel.clipEndTime - 5)
                        }
                    }) {
                        Text("当前位置设为 Out 点")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                }
            }

            // 裁剪区间与时长信息
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("起点 (In)")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                    Text(formatTime(viewModel.clipStartTime))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }

                Spacer()

                VStack(spacing: 2) {
                    Text("裁切时长")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                    Text(formatTime(max(0, viewModel.clipEndTime - viewModel.clipStartTime)))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.cyan)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("终点 (Out)")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                    Text(formatTime(viewModel.clipEndTime))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 8)

            if let msg = viewModel.exportMessage {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundColor(.cyan)
                    .transition(.opacity)
            }
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
