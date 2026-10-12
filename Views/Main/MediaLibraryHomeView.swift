import SwiftUI
import LovortPlayerCore

public struct MediaLibraryHomeView: View {
    @State private var videos: [VideoItem] = []
    @State private var selectedVideo: VideoItem?
    @State private var showLANUpload: Bool = false
    @State private var showVaultUnlocked: Bool = false
    @State private var isAuthenticatingVault: Bool = false
    @State private var filterTab: Int = 0

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea()

                VStack(spacing: 0) {
                    // 自定义 Lovort 导航条
                    customHeaderBar

                    // 分类 Tabs
                    tabsBar

                    // 视频卡片流
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(videos.filter { showVaultUnlocked ? true : !$0.isHidden }) { video in
                                VideoCardView(video: video) {
                                    selectedVideo = video
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 32)
                    }
                }
            }
            #if os(iOS)
            .navigationBarHidden(true)
            #endif
            .sheet(item: $selectedVideo) { video in
                FullscreenVideoPlayerView(
                    videoURL: video.fileURL,
                    videoTitle: video.title,
                    onDismiss: {
                        selectedVideo = nil
                    }
                )
            }
            .sheet(isPresented: $showLANUpload) {
                LANUploadSheet()
            }
        }
        .onAppear {
            loadMockVideos()
        }
    }

    // MARK: - 顶栏 (包含局域网快传入口 & 下拉/长按解锁 Face ID 保险箱)
    private var customHeaderBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(showVaultUnlocked ? "私密保险箱" : "媒体库")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(showVaultUnlocked ? .cyan : .white)
                Text(showVaultUnlocked ? "已解除 AES-GCM 保护" : "全部视频 (\(videos.count))")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
            }
            .onLongPressGesture(minimumDuration: 1.2) {
                triggerVaultBiometrics()
            }

            Spacer()

            // 局域网传输按钮
            Button(action: { showLANUpload = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "wifi")
                        .font(.system(size: 13, weight: .bold))
                    Text("无线传片")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var tabsBar: some View {
        HStack(spacing: 12) {
            tabButton(title: "全部", index: 0)
            tabButton(title: "精彩剪辑", index: 1)
            tabButton(title: "最近播放", index: 2)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func tabButton(title: String, index: Int) -> some View {
        Button(action: { filterTab = index }) {
            Text(title)
                .font(.system(size: 13, weight: filterTab == index ? .bold : .medium))
                .foregroundColor(filterTab == index ? .black : .white.opacity(0.6))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(filterTab == index ? Color.white : Color.white.opacity(0.06))
                )
        }
    }

    private func triggerVaultBiometrics() {
        Task {
            isAuthenticatingVault = true
            let result = await VaultManager.shared.authenticateWithBiometrics()
            isAuthenticatingVault = false
            if result.success {
                withAnimation {
                    showVaultUnlocked.toggle()
                }
            }
        }
    }

    private func loadMockVideos() {
        if videos.isEmpty {
            videos = [
                VideoItem(
                    title: "Suzume.no.Tojimari.2022.mkv",
                    fileURL: URL(fileURLWithPath: "/tmp/sample1.mp4"),
                    duration: 7260,
                    fileSize: 2_450_000_000,
                    isHidden: false
                ),
                VideoItem(
                    title: "Keynote.Clip.2026.mov",
                    fileURL: URL(fileURLWithPath: "/tmp/sample2.mp4"),
                    duration: 420,
                    fileSize: 180_000_000,
                    isHidden: false
                ),
                VideoItem(
                    title: "Private_Vault_Record.mov",
                    fileURL: URL(fileURLWithPath: "/tmp/vault.mov"),
                    duration: 350,
                    fileSize: 120_000_000,
                    isHidden: true
                )
            ]
        }
    }
}
