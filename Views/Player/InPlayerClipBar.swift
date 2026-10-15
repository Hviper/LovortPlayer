#if canImport(LovortPlayerCore)
import LovortPlayerCore
#endif
import SwiftUI
import AVFoundation

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

                Text("片段剪辑 (可拖拽区间)")
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
                        Text(viewModel.clipSegments.isEmpty ? "导出当前段" : "导出 \(viewModel.clipSegments.count) 段")
                            .font(.system(size: 13, weight: .bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.cyan)
                            .foregroundColor(.black)
                            .clipShape(Capsule())
                    }
                }
            }

            Picker("导出方式", selection: $viewModel.clipExportStrategy) {
                ForEach(ClipExportStrategy.allCases, id: \.self) { strategy in
                    Text(strategy.title).tag(strategy)
                }
            }
            .pickerStyle(.segmented)
            Text(viewModel.clipExportStrategy == .fastCopy ? "尽量保留原始码流，切点可能对齐到关键帧；不支持时会重新编码。" : "按选择的时间精确裁切，需要重新编码，耗时更久。")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)

            // 双游标可视化交互滑块 (用户可直接拖拽起点与终点)
            VStack(spacing: 6) {
                if let url = viewModel.playbackMediaURL, viewModel.duration > 0 {
                    ClipFilmstripView(url: url, duration: viewModel.duration)
                        .frame(height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
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

            HStack {
                Button { viewModel.addClipSegment() } label: {
                    Label("将当前区间加入批量", systemImage: "plus.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
                .disabled(viewModel.isExportingClip)
                Spacer()
                if !viewModel.clipSegments.isEmpty {
                    Text("待导出 \(viewModel.clipSegments.count) 段")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .foregroundStyle(.cyan)

            if !viewModel.clipSegments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(viewModel.clipSegments.enumerated()), id: \.element.id) { index, segment in
                            HStack(spacing: 5) {
                                Text("\(index + 1). \(formatTime(segment.start))–\(formatTime(segment.end))")
                                Button { viewModel.removeClipSegment(segment.id) } label: { Image(systemName: "xmark.circle.fill") }
                                    .disabled(viewModel.isExportingClip)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Color.white.opacity(0.12), in: Capsule())
                        }
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

private struct ClipFilmstripView: View {
    let url: URL
    let duration: TimeInterval
    @State private var frames: [CGImage?] = Array(repeating: nil, count: 8)

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<8, id: \.self) { index in
                Group {
                    if let frame = frames[index] {
                        Image(decorative: frame, scale: 1, orientation: .up)
                            .resizable()
                            .scaledToFill()
                    } else { Color.white.opacity(0.08) }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .clipped()
            }
        }
        .task(id: url) {
            frames = Array(repeating: nil, count: 8)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 180, height: 100)
            for index in 0..<8 {
                guard !Task.isCancelled else { break }
                let second = duration * (Double(index) + 0.5) / 8
                if let frame = try? await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)).image {
                    frames[index] = frame
                }
            }
        }
    }
}
