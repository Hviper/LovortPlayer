#if canImport(LovortPlayerCore)
import LovortPlayerCore
#endif
import SwiftUI
import Translation
import KSPlayer
#if os(iOS)
import UIKit
#endif

public struct FullscreenVideoPlayerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject public var viewModel = PlayerViewModel()
    @ObservedObject private var appleTranslation = AppleTranslationBridge.shared
    @ObservedObject private var vault = VaultManager.shared
    @ObservedObject private var settings = AppSettings.shared
    public let videoURL: URL
    public let videoTitle: String
    public let isPrivate: Bool
    public var onDismiss: () -> Void

    // 局部手势与状态
    @State private var gestureIndicatorText: String?
    @State private var gestureIndicatorIcon: String?
    @State private var panStartTime: TimeInterval = 0
    @State private var panTargetTime: TimeInterval = 0
    @State private var isLandscape: Bool = false
    @State private var hideHUDTask: Task<Void, Never>? = nil
    @State private var initialVolume: Float = 0.5
    @State private var initialBrightness: CGFloat = 0.5
    @State private var panAxis: Int?
    @State private var showSubtitleTimeline = false
    @State private var showSubtitleExport = false
    @State private var bottomControlsHeight: CGFloat = 0

    public init(videoURL: URL, videoTitle: String, isPrivate: Bool = false, onDismiss: @escaping () -> Void) {
        self.videoURL = videoURL
        self.videoTitle = videoTitle
        self.isPrivate = isPrivate
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ZStack {
            // 背景黑底，忽略全屏安全区
            Color.black.ignoresSafeArea()

            // 原生 AVPlayer 视频渲染层 或 libdav1d AV1 软解渲染层
            ZStack {
                if viewModel.isCompatibilityMode,
                   let coordinator = viewModel.compatibilityCoordinator,
                   let options = viewModel.compatibilityOptions {
                    KSVideoPlayer(coordinator: coordinator, url: viewModel.playbackMediaURL ?? videoURL, options: options)
                        .ignoresSafeArea()
                } else {
                    NativeVideoPlayerView(player: viewModel.player)
                        .ignoresSafeArea()
                }

                if viewModel.isAV1SoftwareMode {
                    if let cgFrame = viewModel.currentSoftwareFrame {
                        Image(decorative: cgFrame, scale: 1.0, orientation: .up)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .ignoresSafeArea()
                    } else {
                        ProgressView("正在初始化 AV1 (libdav1d) 软解引擎...")
                            .tint(.cyan)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { location in
                #if os(iOS)
                let screenWidth = UIScreen.main.bounds.width
                if location.x < screenWidth / 2 {
                    viewModel.rewind(by: 10)
                    showGestureHUD(icon: "gobackward.10", text: "-10s", autoDismiss: true)
                } else {
                    viewModel.fastForward(by: 10)
                    showGestureHUD(icon: "goforward.10", text: "+10s", autoDismiss: true)
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
                    .onEnded { value in
                        handlePanEnded(value)
                    }
            )
            #endif

            // AI 实时双语字幕图层 (确保置于控制层下方，不受控制栏显隐影响)
            AISubtitleOverlayView(subtitle: viewModel.currentSubtitle, videoSize: subtitleVideoSize,
                                  controlsHeight: viewModel.showControls ? (bottomControlsHeight > 0 ? bottomControlsHeight : (viewModel.isClipMode ? 180 : 128)) : 0)

            if viewModel.isGeneratingSubtitles {
                VStack {
                    HStack(spacing: 8) {
                        ProgressView().tint(.cyan).scaleEffect(0.8)
                        Text(viewModel.generatingSubtitleStatusText.isEmpty ? "字幕任务处理中" : viewModel.generatingSubtitleStatusText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.82))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .clipShape(Capsule())
                    .padding(.top, 58)
                    Spacer()
                }
            }

            if let message = viewModel.playbackErrorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)
                }
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(24)
            }

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
                        InPlayerClipBar(viewModel: viewModel) { _, _ in
                            viewModel.exportClip()
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: SubtitleControlsHeightKey.self, value: geometry.size.height)
                        })
                    } else {
                        bottomControlsBar
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: SubtitleControlsHeightKey.self, value: geometry.size.height)
                        })
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: viewModel.showControls)
                .animation(.easeInOut(duration: 0.25), value: viewModel.isClipMode)
            }
        }
        .onPreferenceChange(SubtitleControlsHeightKey.self) { bottomControlsHeight = $0 }
        .overlay { if isPrivate && !vault.isUnlocked { Color.black.ignoresSafeArea() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && isPrivate { viewModel.cleanup(); onDismiss() }
        }
        .translationTask(appleTranslation.configuration) { session in
            await appleTranslation.perform(using: session)
        }
        .onAppear {
            viewModel.loadVideo(url: videoURL, isPrivate: isPrivate)
            viewModel.togglePlayPause()
            #if os(iOS)
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            applyPreferredOrientation()
            updateOrientationState()
            #endif
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateOrientationState()
        }
        #endif
        .onDisappear {
            #if os(iOS)
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            rotateToOrientation(.portrait)
            #endif
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
        .sheet(isPresented: $showSubtitleExport) {
            SubtitleVideoExportSheet(videoURL: videoURL, videoTitle: videoTitle)
        }
        .sheet(isPresented: $showSubtitleTimeline) {
            SubtitleTimelineSheet(viewModel: viewModel)
        }
    }

    private var subtitleVideoSize: CGSize {
        if viewModel.isAV1SoftwareMode, let frame = viewModel.currentSoftwareFrame {
            return CGSize(width: frame.width, height: frame.height)
        }
        if viewModel.isCompatibilityMode {
            return viewModel.compatibilityCoordinator?.playerLayer?.player.naturalSize ?? .zero
        }
        return viewModel.player?.currentItem?.presentationSize ?? .zero
    }

    // MARK: - 顶部导航条
    private var topNavigationBar: some View {
        HStack(spacing: 12) {
            Button(action: {
                viewModel.cleanup()
                onDismiss()
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }

            Text(videoTitle)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)

            if viewModel.isAV1SoftwareMode {
                Text("AV1 软解")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.cyan))
            }

            if viewModel.isCompatibilityMode {
                Text("兼容解码")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange))
            }

            Spacer()

            if !viewModel.subtitles.isEmpty {
                Button(action: { showSubtitleTimeline = true }) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .accessibilityLabel("查看字幕时间轴")
            }

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
                    .background(Circle().fill(Color.white.opacity(0.15)))
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
                .background(Capsule().fill(Color.white.opacity(0.15)))
            }

            // 分享与导出菜单
            Menu {
                Button { showSubtitleExport = true } label: {
                    Label("导出带字幕视频", systemImage: "captions.bubble")
                }
                Divider()
                Button {
                    VideoExportManager.shared.shareVideo(url: videoURL)
                } label: {
                    Label("分享原视频", systemImage: "square.and.arrow.up")
                }

                Button {
                    Task {
                        await handleSaveToPhotos()
                    }
                } label: {
                    Label("原视频保存到相册", systemImage: "photo.badge.arrow.down")
                }

                Button {
                    VideoExportManager.shared.saveToFiles(url: videoURL)
                } label: {
                    Label("原视频存储到“文件”", systemImage: "folder.badge.plus")
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    // MARK: - 底部控制条 (Lovort 质感，集成倍速与横竖屏切换)
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

            // 播放与操作按键区（倍速、快退、播放/暂停、快进、横竖屏旋转）
            HStack {
                // 自定义倍速选择菜单
                Menu {
                    Button("0.5x") { viewModel.setPlaybackRate(0.5) }
                    Button("0.75x") { viewModel.setPlaybackRate(0.75) }
                    Button("1.0x (正常)") { viewModel.setPlaybackRate(1.0) }
                    Button("1.25x") { viewModel.setPlaybackRate(1.25) }
                    Button("1.5x") { viewModel.setPlaybackRate(1.5) }
                    Button("2.0x") { viewModel.setPlaybackRate(2.0) }
                    Button("3.0x") { viewModel.setPlaybackRate(3.0) }
                } label: {
                    Text(viewModel.playbackRate == 1.0 ? "倍速" : "\(String(format: "%.2gx", viewModel.playbackRate))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(viewModel.playbackRate == 1.0 ? .white.opacity(0.85) : .cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }

                Spacer()

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
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                    }

                    Button(action: { viewModel.fastForward(by: 10) }) {
                        Image(systemName: "goforward.10")
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.9))
                    }
                }

                Spacer()

                // 横竖屏一键旋转切换按钮
                Button(action: toggleOrientation) {
                    Image(systemName: isLandscape ? "iphone.portrait" : "iphone.landscape")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(8)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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
    private func applyPreferredOrientation() {
        let mask: UIInterfaceOrientationMask
        switch settings.playbackOrientation {
        case .auto: mask = .allButUpsideDown
        case .portrait: mask = .portrait
        case .landscape: mask = .landscape
        case .landscapeLeft: mask = .landscapeLeft
        case .landscapeRight: mask = .landscapeRight
        }
        rotateToOrientation(mask)
    }

    private func updateOrientationState() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        isLandscape = scene.interfaceOrientation.isLandscape
    }

    private func toggleOrientation() {
        let target: UIInterfaceOrientationMask = isLandscape ? .portrait : .landscapeRight
        rotateToOrientation(target)
    }

    private func rotateToOrientation(_ orientation: UIInterfaceOrientationMask) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientation)
        windowScene.requestGeometryUpdate(geometryPreferences) { error in
            print("Failed to rotate orientation: \(error)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            updateOrientationState()
        }
    }

    private func handlePanGesture(_ value: DragGesture.Value) {
        let screenWidth = UIScreen.main.bounds.width
        let translation = value.translation

        if panAxis == nil {
            panAxis = abs(translation.width) > abs(translation.height) ? 0 : (value.startLocation.x < screenWidth / 2 ? 1 : 2)
            panStartTime = viewModel.currentTime
            initialBrightness = UIScreen.main.brightness
            initialVolume = SystemVolumeController.shared.getCurrentVolume()
        }
        if panAxis == 0 {
            // 水平滑动：快进快退 seek
            let delta = TimeInterval(translation.width / 4.0)
            let target = max(0, min(viewModel.duration, panStartTime + delta))
            panTargetTime = target
            showGestureHUD(
                icon: delta >= 0 ? "forward.fill" : "backward.fill",
                text: "\(formatTime(target)) (\(delta >= 0 ? "+" : "")\(Int(delta))s)",
                autoDismiss: false
            )
        } else {
            // 垂直滑动：左半屏调系统亮度，右半屏调系统真实音量
            if panAxis == 1 {
                let newBrightness = max(0.0, min(1.0, initialBrightness - translation.height / 350.0))
                UIScreen.main.brightness = newBrightness
                showGestureHUD(icon: "sun.max.fill", text: "\(Int(newBrightness * 100))%", autoDismiss: false)
            } else {
                // 右半屏调系统硬件音量与播放器音量
                let delta = Float(-translation.height / 350.0)
                let newVol = max(0.0, min(1.0, initialVolume + delta))
                SystemVolumeController.shared.setVolume(newVol)
                viewModel.volume = newVol
                viewModel.player?.volume = newVol
                viewModel.player?.isMuted = false
                let icon = newVol <= 0.01 ? "speaker.slash.fill" : (newVol < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
                showGestureHUD(icon: icon, text: "\(Int(newVol * 100))%", autoDismiss: false)
            }
        }
    }

    private func handlePanEnded(_ value: DragGesture.Value) {
        if panAxis == 0 {
            viewModel.seek(to: panTargetTime)
            panStartTime = 0
            panTargetTime = 0
        }
        panAxis = nil
        autoDismissHUD(after: 0.8)
    }
    #endif

    private func showGestureHUD(icon: String, text: String, autoDismiss: Bool) {
        hideHUDTask?.cancel()
        self.gestureIndicatorIcon = icon
        self.gestureIndicatorText = text
        if autoDismiss {
            autoDismissHUD(after: 1.0)
        }
    }

    private func autoDismissHUD(after seconds: Double) {
        hideHUDTask?.cancel()
        hideHUDTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.25)) {
                    self.gestureIndicatorText = nil
                    self.gestureIndicatorIcon = nil
                }
            }
        }
    }

    private func handleSaveToPhotos() async {
        showGestureHUD(icon: "arrow.down.circle", text: "正在保存...", autoDismiss: false)
        do {
            try await VideoExportManager.shared.saveToPhotoLibrary(videoURL: videoURL)
            showGestureHUD(icon: "checkmark.circle.fill", text: "已保存到系统相册", autoDismiss: true)
        } catch {
            showGestureHUD(icon: "exclamationmark.triangle.fill", text: error.localizedDescription, autoDismiss: true)
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && !seconds.isNaN else { return "00:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

private struct SubtitleControlsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
