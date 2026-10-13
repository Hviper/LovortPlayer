import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
import PhotosUI
#endif

public struct MediaLibraryHomeView: View {
    @StateObject private var libraryManager = MediaLibraryManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedVideo: VideoItem?
    @State private var showLANUpload: Bool = false
    @State private var showVaultUnlocked: Bool = false
    @State private var isAuthenticatingVault: Bool = false
    @State private var filterTab: Int = 0 // 0: 全部, 1: 精彩剪辑, 2: 隐私保险箱
    @State private var isFileImporterPresented: Bool = false
    @State private var showPinDialog: Bool = false
    @State private var pinInput: String = ""
    @State private var isDecoySpace: Bool = false
    @State private var showSettings: Bool = false

    #if os(iOS)
    @State private var isPhotosPickerPresented: Bool = false
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
            // 精彩剪辑（严格排除私密文件夹内容）
            return libraryManager.videos.filter { $0.fileURL.path.contains("/Clips/") && !$0.isHidden }
        case 2:
            // 私密文件夹（仅在私密文件夹 Tab 中展示隐藏视频）
            return libraryManager.videos.filter { $0.isHidden }
        default:
            // 全部（永远只展示公开视频，严格过滤私密文件夹的内容）
            return libraryManager.videos.filter { !$0.isHidden }
        }
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea()

                VStack(spacing: 0) {
                    // 自定义 Lovort 导航条
                    customHeaderBar

                    // 导入完成提示条
                    if let successMsg = libraryManager.importSuccessMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(successMsg)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.green.opacity(0.18))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.green.opacity(0.4), lineWidth: 1)
                                )
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

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

                // 导入实时进度 HUD 浮层（大文件/多文件导入实时动效与进度反馈）
                if libraryManager.isImporting {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .transition(.opacity)

                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: settings.themeColor.color))
                            .scaleEffect(1.4)

                        Text("正在导入视频")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)

                        Text(libraryManager.importStatusText.isEmpty ? "正在后台处理文件，请稍候..." : libraryManager.importStatusText)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 12)
                    }
                    .padding(.vertical, 28)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 290)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(red: 0.1, green: 0.11, blue: 0.14).opacity(0.96))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(settings.themeColor.color.opacity(0.35), lineWidth: 1)
                            )
                    )
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            #if os(iOS)
            .navigationBarHidden(true)
            .photosPicker(
                isPresented: $isPhotosPickerPresented,
                selection: $selectedPhotoItems,
                matching: .videos
            )
            .onChange(of: selectedPhotoItems) { newItems in
                guard !newItems.isEmpty else { return }
                let itemsToImport = newItems
                selectedPhotoItems.removeAll()
                Task {
                    var urlsToImport: [URL] = []
                    libraryManager.isImporting = true
                    libraryManager.importStatusText = "正在从系统相册提取视频，请稍候..."
                    for item in itemsToImport {
                        if let movie = try? await item.loadTransferable(type: VideoTransferable.self) {
                            urlsToImport.append(movie.url)
                        }
                    }
                    await libraryManager.importFiles(from: urlsToImport, isHidden: filterTab == 2)
                }
            }
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
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: supportedVideoContentTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    guard !urls.isEmpty else { return }
                    Task {
                        await libraryManager.importFiles(from: urls, isHidden: filterTab == 2)
                    }
                case .failure(let error):
                    print("文件选择器未选择或出错: \(error.localizedDescription)")
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

    private var supportedVideoContentTypes: [UTType] {
        var types: [UTType] = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        let extensions = ["mkv", "mp4", "mov", "avi", "webm", "flv", "m4v", "ts", "wmv", "3gp"]
        for ext in extensions {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }

    // MARK: - 顶栏
    private var customHeaderBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(filterTab == 2 ? (isDecoySpace ? "访客空间" : "私密文件夹") : "媒体库")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(filterTab == 2 ? settings.themeColor.color : .white)

                    if filterTab == 2 && showVaultUnlocked {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 14))
                            .foregroundColor(settings.themeColor.color)
                    }
                }
                Text(filterTab == 2 ? (showVaultUnlocked ? "私密空间已解锁 (\(filteredVideos.count))" : "安全加密存储 (\(filteredVideos.count))") : "本地视频 (\(filteredVideos.count))")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer()

            // 导入视频按钮
            Menu {
                #if os(iOS)
                Button(action: { isPhotosPickerPresented = true }) {
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

            // 设置按钮
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.1)))
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
            // 私密文件夹 Tab：受设置控制是否显示
            if settings.showVaultInTabBar {
                tabButton(title: "私密文件夹 🔒", index: 2)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func tabButton(title: String, index: Int) -> some View {
        Button(action: {
            if index == 2 && !showVaultUnlocked {
                // 点击私密保险箱时根据设置决定是否触发 Face ID
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

            Text(filterTab == 2 ? "私密文件夹为空" : "暂无视频文件")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            Text(filterTab == 2 ? "长按列表视频可将视频移入私密文件夹" : "可以通过右上角 [+] 导入视频，或点击 [无线传片] 电脑免线快传")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private func triggerVaultBiometrics() {
        Task {
            // 根据设置决定是否需要 Face ID / Touch ID 验证
            if settings.vaultRequiresBiometrics {
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
            } else {
                // Face ID 已在设置中关闭，直接弹密码输入框
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
