import SwiftUI
#if os(iOS)
import UIKit
import PhotosUI
#endif

public struct MediaLibraryHomeView: View {
    @StateObject private var libraryManager = MediaLibraryManager.shared
    @State private var selectedVideo: VideoItem?
    @State private var showLANUpload: Bool = false
    @State private var showVaultUnlocked: Bool = false
    @State private var isAuthenticatingVault: Bool = false
    @State private var filterTab: Int = 0 // 0: 全部, 1: 精彩剪辑, 2: 隐私保险箱
    @State private var isFileImporterPresented: Bool = false
    @State private var showPinDialog: Bool = false
    @State private var pinInput: String = ""
    @State private var isDecoySpace: Bool = false

    #if os(iOS)
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    #endif

    public init() {}

    private var filteredVideos: [VideoItem] {
        if isDecoySpace {
            // 诱导假密码模式：反侦察，显示空的假空间
            return []
        }

        switch filterTab {
        case 1:
            // 精彩剪辑
            return libraryManager.videos.filter { $0.fileURL.path.contains("/Clips/") }
        case 2:
            // 隐私保险箱
            return libraryManager.videos.filter { $0.isHidden }
        default:
            // 全部（未解锁时不展示隐私视频）
            return libraryManager.videos.filter { showVaultUnlocked ? true : !$0.isHidden }
        }
    }

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
                    if libraryManager.isLoading && libraryManager.videos.isEmpty {
                        Spacer()
                        ProgressView()
                            .tint(.white)
                        Spacer()
                    } else if filteredVideos.isEmpty {
                        emptyStateView
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 16) {
                                ForEach(filteredVideos) { video in
                                    VideoCardView(
                                        video: video,
                                        onSelect: {
                                            selectedVideo = video
                                        },
                                        onToggleHide: {
                                            Task {
                                                try? await libraryManager.toggleHideVideo(video)
                                            }
                                        },
                                        onDelete: {
                                            libraryManager.deleteVideo(video)
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                            .padding(.bottom, 40)
                        }
                        .refreshable {
                            libraryManager.reloadLibrary()
                        }
                    }
                }
            }
            #if os(iOS)
            .navigationBarHidden(true)
            #endif
            .fullScreenCover(item: $selectedVideo) { video in
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
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.movie, .video],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    Task {
                        for url in urls {
                            try? await libraryManager.importFile(from: url, isHidden: filterTab == 2)
                        }
                    }
                }
            }
            .alert("输入保险箱密码", isPresented: $showPinDialog) {
                SecureField("输入4位密码", text: $pinInput)
                Button("验证") {
                    let verify = VaultManager.shared.verifyPassword(pinInput)
                    if verify.success {
                        withAnimation {
                            showVaultUnlocked = true
                            isDecoySpace = verify.isDecoy
                            filterTab = 2
                        }
                    }
                    pinInput = ""
                }
                Button("取消", role: .cancel) {
                    pinInput = ""
                }
            } message: {
                Text("输入安全密码以解锁保密视频")
            }
        }
    }

    // MARK: - 顶栏
    private var customHeaderBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(filterTab == 2 ? (isDecoySpace ? "访客空间" : "私密保险箱") : "媒体库")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(filterTab == 2 || showVaultUnlocked ? .cyan : .white)

                    if showVaultUnlocked {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.cyan)
                    }
                }
                Text(showVaultUnlocked ? "AES-256 空间已解锁 (\(filteredVideos.count))" : "本地视频 (\(filteredVideos.count))")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer()

            // 导入视频按钮
            Menu {
                #if os(iOS)
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    matching: .videos
                ) {
                    Label("从相册导入", systemImage: "photo.on.rectangle")
                }
                #endif
                Button(action: { isFileImporterPresented = true }) {
                    Label("从文件导入", systemImage: "folder")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            #if os(iOS)
            .onChange(of: selectedPhotoItems) { newItems in
                Task {
                    for item in newItems {
                        if let movie = try? await item.loadTransferable(type: VideoTransferable.self) {
                            try? await libraryManager.importFile(from: movie.url, isHidden: filterTab == 2)
                        }
                    }
                    selectedPhotoItems.removeAll()
                }
            }
            #endif

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
                        .fill(Color.white.opacity(0.1))
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - 分类 Tabs
    private var tabsBar: some View {
        HStack(spacing: 10) {
            tabButton(title: "全部", index: 0)
            tabButton(title: "精彩剪辑", index: 1)
            tabButton(title: "私密保险箱 🔒", index: 2)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func tabButton(title: String, index: Int) -> some View {
        Button(action: {
            if index == 2 && !showVaultUnlocked {
                // 点击私密保险箱时触发 Face ID 验证或弹窗
                triggerVaultBiometrics()
            } else {
                withAnimation {
                    filterTab = index
                }
            }
        }) {
            Text(title)
                .font(.system(size: 13, weight: filterTab == index ? .bold : .medium))
                .foregroundColor(filterTab == index ? .black : .white.opacity(0.65))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(filterTab == index ? Color.white : Color.white.opacity(0.06))
                )
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: filterTab == 2 ? "lock.shield" : "film")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.2))

            Text(filterTab == 2 ? "保险箱为空" : "暂无视频文件")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            Text(filterTab == 2 ? "长按列表视频可将视频移入保险箱" : "可以通过右上角 [+] 导入视频，或点击 [无线传片] 电脑免线快传")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private func triggerVaultBiometrics() {
        Task {
            isAuthenticatingVault = true
            let result = await VaultManager.shared.authenticateWithBiometrics()
            isAuthenticatingVault = false
            if result.success {
                withAnimation {
                    showVaultUnlocked = true
                    isDecoySpace = false
                    filterTab = 2
                }
            } else {
                // 生物识别失败或不可用时，弹密码输入框（支持真/假诱导密码）
                showPinDialog = true
            }
        }
    }
}

#if os(iOS)
struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return VideoTransferable(url: copy)
        }
    }
}
#endif
