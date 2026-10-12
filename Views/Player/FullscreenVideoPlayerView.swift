import SwiftUI
import LovortPlayerCore

public struct FullscreenVideoPlayerView: View {
    @StateObject public var viewModel = PlayerViewModel()
    public let videoURL: URL
    public let videoTitle: String
    public var onDismiss: () -> Void

    // 局部手势状态
    @State private var dragOffset: CGSize = .zero
    @State private var gestureIndicatorText: String?
    @State private var gestureIndicatorIcon: String?

    public init(videoURL: URL, videoTitle: String, onDismiss: @escaping () -> Void) {
        self.videoURL = videoURL
        self.videoTitle = videoTitle
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ZStack {
            // 背景黑底
            Color.black.ignoresSafeArea()

            // 原生 AVPlayer 视频渲染层
            NativeVideoPlayerView(player: viewModel.player)
                .ignoresSafeArea()
                .onTapGesture(count: 2) { location in
                    #if os(iOS)
                    let screenWidth = UIScreen.main.bounds.width
                    if location.x < screenWidth / 2 {
                        viewModel.rewind(by: 10)
                        showGestureHUD(icon: "gobackward.10", text: "-10s")
                    } else {
                        viewModel.fastForward(by: 10)
                        showGestureHUD(icon: "goforward.10", text: "+10s")
                    }
                    #else
                    viewModel.fastForward(by: 10)
                    #endif
                }
                .onTapGesture(count: 1) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        viewModel.toggleControls()
                    }
                }
                #if os(iOS)
                .gesture(
                    DragGesture(minimumDistance: 15)
                        .onChanged { value in
                            handlePanGesture(value)
                        }
                        .onEnded { _ in
                            gestureIndicatorText = nil
                            gestureIndicatorIcon = nil
                        }
                )
                #endif

            // AI 实时双语字幕图层
            AISubtitleOverlayView(subtitle: viewModel.currentSubtitle)

            // 手势浮层指示器 HUD
            if let icon = gestureIndicatorIcon, let text = gestureIndicatorText {
                VStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 28))
                        .foregroundColor(.white)
                    Text(text)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(20)
                .background(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .transition(.opacity)
            }

            // 浮动控制覆盖层 (Lovort 极简风)
            if viewModel.showControls {
                VStack {
                    // 顶部导航栏
                    topNavigationBar
                        .transition(.move(edge: .top).combined(with: .opacity))

                    Spacer()

                    // 剪辑模式工具条 或 正常底部控制条
                    if viewModel.isClipMode {
                        InPlayerClipBar(viewModel: viewModel) { start, end in
                            // 触发剪辑导出任务
                            withAnimation { viewModel.isClipMode = false }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        bottomControlsBar
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: viewModel.showControls)
                .animation(.easeInOut(duration: 0.25), value: viewModel.isClipMode)
            }
        }
        .onAppear {
            viewModel.loadVideo(url: videoURL)
            viewModel.togglePlayPause()
        }
        .onDisappear {
            viewModel.cleanup()
        }
        .sheet(isPresented: $viewModel.showAISubtitlePanel) {
            #if os(iOS)
            AISubtitleSettingsSheet(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            #else
            AISubtitleSettingsSheet(viewModel: viewModel)
            #endif
        }
    }

    // MARK: - 顶部导航条
    private var topNavigationBar: some View {
        HStack(spacing: 16) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }

            Text(videoTitle)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)

            Spacer()

            // 剪辑按钮
            Button(action: {
                withAnimation {
                    viewModel.isClipMode.toggle()
                    if viewModel.isClipMode {
                        viewModel.clipStartTime = viewModel.currentTime
                        viewModel.clipEndTime = min(viewModel.duration, viewModel.currentTime + 15)
                    }
                }
            }) {
                Image(systemName: "scissors")
                    .font(.system(size: 15))
                    .foregroundColor(viewModel.isClipMode ? .cyan : .white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }

            // AI 字幕按钮
            Button(action: {
                viewModel.showAISubtitlePanel = true
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "captions.bubble.fill")
                        .font(.system(size: 14))
                    Text("AI")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundColor(viewModel.isAISubtitleEnabled ? .cyan : .white)
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(Capsule().fill(Color.white.opacity(0.12)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    // MARK: - 底部控制条 (Lovort 质感)
    private var bottomControlsBar: some View {
        VStack(spacing: 12) {
            // 时间进度滑动条
            HStack(spacing: 12) {
                Text(formatTime(viewModel.currentTime))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))

                Slider(
                    value: Binding(
                        get: { viewModel.currentTime },
                        set: { newTime in
                            viewModel.seek(to: newTime)
                        }
                    ),
                    in: 0...max(viewModel.duration, 1)
                )
                .tint(.cyan)

                Text(formatTime(viewModel.duration))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }

            // 播放与快进操作按键
            HStack(spacing: 32) {
                Button(action: { viewModel.rewind(by: 10) }) {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.9))
                }

                Button(action: { viewModel.togglePlayPause() }) {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.white)
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }

                Button(action: { viewModel.fastForward(by: 10) }) {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    #if os(iOS)
    private func handlePanGesture(_ value: DragGesture.Value) {
        let screenWidth = UIScreen.main.bounds.width
        let translation = value.translation

        if abs(translation.width) > abs(translation.height) {
            // 水平滑动：微调进度
            let delta = TimeInterval(translation.width / 5.0)
            let targetTime = max(0, min(viewModel.duration, viewModel.currentTime + delta))
            showGestureHUD(
                icon: delta >= 0 ? "forward.fill" : "backward.fill",
                text: formatTime(targetTime)
            )
        } else {
            // 垂直滑动：左半屏亮度，右半屏音量
            if value.startLocation.x < screenWidth / 2 {
                let change = -translation.height / 300.0
                showGestureHUD(icon: "sun.max.fill", text: "\(Int(max(0, min(1, change + 0.5)) * 100))%")
            } else {
                let change = -translation.height / 300.0
                showGestureHUD(icon: "speaker.wave.3.fill", text: "\(Int(max(0, min(1, change + 0.5)) * 100))%")
            }
        }
    }
    #endif

    private func showGestureHUD(icon: String, text: String) {
        self.gestureIndicatorIcon = icon
        self.gestureIndicatorText = text
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && !seconds.isNaN else { return "00:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
