#if canImport(LovortPlayerCore)
import LovortPlayerCore
#endif
import SwiftUI
import UniformTypeIdentifiers
import Translation
#if os(iOS)
import UIKit
import PhotosUI
#endif

public struct MediaLibraryHomeView: View {
    @StateObject private var libraryManager = MediaLibraryManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var playlists = PlaylistStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var vault = VaultManager.shared
    @State private var showVaultSetup = false
    @State private var pendingVaultMove: VideoItem?
    @State private var pendingDelete: VideoItem?
    @State private var isExtractingPhotos = false
    @State private var importIntoVault = false
    @State private var searchText = ""
    @AppStorage("library.sort") private var sortOrder = "newest"
    @State private var selectedVideo: VideoItem?
    @State private var selectedPlaylistID: UUID?
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""
    @State private var showLANUpload: Bool = false
    @State private var showVaultUnlocked: Bool = false
    @State private var isAuthenticatingVault: Bool = false
    @State private var filterTab: Int = 0 // 0: 全部, 1: 精彩剪辑, 2: 隐私保险箱
    @State private var isFileImporterPresented: Bool = false
    @State private var showPinDialog: Bool = false
    @State private var pinInput: String = ""
    @State private var isDecoySpace: Bool = false
    @State private var showSettings: Bool = false
    @State private var showSubtitleTasks: Bool = false
    @ObservedObject private var appleTranslation = AppleTranslationBridge.shared
    @ObservedObject private var subtitleTasks = SubtitleTaskManager.shared

    #if os(iOS)
    @State private var isPhotosPickerPresented: Bool = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    #endif

    public init() {}

    private var filteredVideos: [VideoItem] {
        if isDecoySpace { return [] }
        var items = libraryManager.videos.filter { video in
            switch filterTab {
            case 1: return video.fileURL.path.contains("/Clips/") && !video.isHidden
            case 2: return vault.isUnlocked && video.isHidden
            default: return !video.isHidden
            }
        }
        if filterTab == 3 {
            guard let selectedPlaylistID else { return [] }
            items = playlists.orderedVideos(items, in: selectedPlaylistID)
        }
        if !searchText.isEmpty { items = items.filter { $0.title.localizedCaseInsensitiveContains(searchText) } }
        if filterTab != 3 { items.sort { lhs, rhs in
            switch sortOrder {
            case "name": return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            case "recent": return PlaybackHistoryManager.shared.lastPlayedDate(for: lhs.fileURL) > PlaybackHistoryManager.shared.lastPlayedDate(for: rhs.fileURL)
            default: return lhs.createdAt > rhs.createdAt
            }
        } }
        return items
    }

    private var continueWatching: [VideoItem] {
        guard filterTab == 0, searchText.isEmpty else { return [] }
        return Array(filteredVideos.filter { $0.lastPlayedPosition > 2 }.sorted { PlaybackHistoryManager.shared.lastPlayedDate(for: $0.fileURL) > PlaybackHistoryManager.shared.lastPlayedDate(for: $1.fileURL) }.prefix(3))
    }

    private var remainingVideos: [VideoItem] {
        let continuedIDs = Set(continueWatching.map(\.id))
        return filteredVideos.filter { !continuedIDs.contains($0.id) }
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea()

                VStack(spacing: 0) {
                    // 自定义 Lovort 导航条
                    customHeaderBar

                    // 操作反馈提示条（导入、相册保存、存储到文件等）
                    if let successMsg = libraryManager.importSuccessMessage {
                        let isError = libraryManager.isSuccessMessageError
                        HStack(spacing: 8) {
                            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundColor(isError ? .orange : .green)
                            Text(successMsg)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(2)
                            Spacer()
                            if let videoURL = libraryManager.notificationVideoURL,
                               let video = libraryManager.videos.first(where: { $0.fileURL.standardizedFileURL == videoURL.standardizedFileURL }) {
                                Button("立即播放") {
                                    selectedVideo = video
                                    libraryManager.importSuccessMessage = nil
                                    libraryManager.notificationVideoURL = nil
                                }
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(settings.themeColor.color)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isError ? Color.orange.opacity(0.18) : Color.green.opacity(0.18))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(isError ? Color.orange.opacity(0.4) : Color.green.opacity(0.4), lineWidth: 1)
                                )
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // 分类 Tabs
                    tabsBar
                    if filterTab == 3 { playlistBar }

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
                                if !continueWatching.isEmpty {
                                    Text("继续观看").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                                    ForEach(continueWatching) { video in
                                        videoCard(for: video)
                                    }
                                    if !remainingVideos.isEmpty {
                                        Text("其他视频").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                ForEach(remainingVideos) { video in
                                    videoCard(for: video)
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

                        Text(libraryManager.importStatusText.contains("私密") || libraryManager.importStatusText.contains("加密") || libraryManager.importStatusText.contains("解密") ? "正在处理私密视频" : "正在导入视频")
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
            .overlay(alignment: .bottom) {
                if let task = subtitleTasks.activeTask {
                    FloatingSubtitleTaskCapsule(task: task) {
                        showSubtitleTasks = true
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
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
                let selectionIsPrivate = importIntoVault
                selectedPhotoItems.removeAll()
                Task {
                    guard !isExtractingPhotos, !libraryManager.isImporting else { return }
                    isExtractingPhotos = true
                    var urlsToImport: [URL] = []
                    defer {
                        isExtractingPhotos = false
                        for url in urlsToImport { PhotoImportStaging.release(url) }
                    }
                    libraryManager.importStatusText = "正在从系统相册提取视频…"
                    for item in itemsToImport {
                        if let movie = try? await item.loadTransferable(type: VideoTransferable.self) { urlsToImport.append(movie.url) }
                    }
                    await libraryManager.importFiles(from: urlsToImport, isHidden: selectionIsPrivate)
                }
            }
            #endif
            .fullScreenCover(item: $selectedVideo) { video in
                FullscreenVideoPlayerView(
                    videoURL: video.fileURL,
                    videoTitle: video.title,
                    isPrivate: video.isHidden,
                    onDismiss: {
                        selectedVideo = nil
                    },
                    onFinished: {
                        guard settings.autoPlayNext,
                              let index = filteredVideos.firstIndex(where: { $0.id == video.id }),
                              filteredVideos.indices.contains(index + 1) else { return }
                        selectedVideo = filteredVideos[index + 1]
                    }
                )
                .id(video.id)
            }
            .sheet(isPresented: $showLANUpload) {
                LANUploadSheet()
            }
            .sheet(isPresented: $showVaultSetup) {
                VaultPasswordSetupSheet {
                    showVaultUnlocked = true
                    filterTab = 2
                    Task { await libraryManager.migrateLegacyVaultFiles() }
                    if let pendingVaultMove {
                        Task {
                            do { try await libraryManager.toggleHideVideo(pendingVaultMove) }
                            catch { libraryManager.showNotification(message: error.localizedDescription, isError: true) }
                        }
                        self.pendingVaultMove = nil
                    }
                }
            }
            .confirmationDialog("删除视频？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("删除视频及其任务记录", role: .destructive) { if let video = pendingDelete { libraryManager.deleteVideo(video) }; pendingDelete = nil }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: { Text("删除后无法恢复，请确认已备份。") }
            .overlay {
                if scenePhase != .active { Color.black.ignoresSafeArea().overlay(Image(systemName: "lock.shield").foregroundStyle(.white)) }
            }
            .searchable(text: $searchText, prompt: "搜索视频名称")
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    if selectedVideo?.isHidden == true { selectedVideo = nil }
                    subtitleTasks.pausePrivateTasks()
                    subtitleTasks.suspendForBackground()
                    vault.lockVault()
                    showVaultUnlocked = false
                    if filterTab == 2 { filterTab = 0 }
                    PlaybackHistoryManager.shared.flush()
                    MediaIdentityStore.shared.flush()
                }
            }
            .onChange(of: filterTab) { old, new in
                if old == 2, new != 2 {
                    subtitleTasks.pausePrivateTasks()
                    vault.lockVault()
                    showVaultUnlocked = false
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showSubtitleTasks) {
                SubtitleTaskCenterView()
            }
            .alert("新建播放列表", isPresented: $showCreatePlaylist) {
                TextField("播放列表名称", text: $newPlaylistName)
                Button("创建") {
                    if let playlist = playlists.create(name: newPlaylistName) {
                        selectedPlaylistID = playlist.id
                        filterTab = 3
                    }
                    newPlaylistName = ""
                }
                Button("取消", role: .cancel) { newPlaylistName = "" }
            } message: { Text("可以从视频卡片右侧菜单添加视频。") }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: supportedVideoContentTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    guard !urls.isEmpty else { return }
                    let selectionIsPrivate = importIntoVault
                    Task {
                        await libraryManager.importFiles(from: urls, isHidden: selectionIsPrivate)
                    }
                case .failure(let error):
                    print("文件选择器未选择或出错: \(error.localizedDescription)")
                }
            }
            .alert("输入保险箱密码", isPresented: $showPinDialog) {
                SecureField("输入保险箱密码", text: $pinInput)
                Button("验证") {
                    let verify = VaultManager.shared.verifyPassword(pinInput)
                    if verify.success {
                        withAnimation {
                            showVaultUnlocked = true
                            isDecoySpace = verify.isDecoy
                            filterTab = 2
                        }
                    }
                    if !verify.success { libraryManager.showNotification(message: vault.retryAfter > 0 ? "请等待 \(vault.retryAfter) 秒后重试" : "密码不正确", isError: true) }
                    pinInput = ""
                }
                Button("取消", role: .cancel) {
                    pinInput = ""
                }
            } message: {
                Text("输入安全密码以解锁保密视频")
            }
        }
        .translationTask(selectedVideo == nil ? appleTranslation.configuration : nil) { session in
            await appleTranslation.perform(using: session)
        }
    }

    private func videoCard(for video: VideoItem) -> some View {
        VideoCardView(
            video: video,
            onSelect: { selectedVideo = video },
            onToggleHide: {
                Task {
                    if !vault.hasPassword { pendingVaultMove = video; showVaultSetup = true; return }
                    do { try await libraryManager.toggleHideVideo(video) }
                    catch { libraryManager.showNotification(message: error.localizedDescription, isError: true) }
                }
            },
            onDelete: { pendingDelete = video }
        )
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
                Button(action: { importIntoVault = filterTab == 2; isPhotosPickerPresented = true }) {
                    Label("从相册导入", systemImage: "photo.on.rectangle")
                }
                #endif
                Button(action: { importIntoVault = filterTab == 2; isFileImporterPresented = true }) {
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

            Menu {
                Picker("排序", selection: $sortOrder) {
                    Text("最新导入").tag("newest")
                    Text("名称").tag("name")
                    Text("最近播放").tag("recent")
                }
                if filterTab == 2 {
                    Button("锁定保险箱") {
                        subtitleTasks.pausePrivateTasks()
                        vault.lockVault()
                        showVaultUnlocked = false
                        filterTab = 0
                    }
                }
            } label: { Image(systemName: "arrow.up.arrow.down").foregroundColor(.white).frame(width: 36, height: 36) }

            // 设置按钮
            Button(action: { showSubtitleTasks = true }) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                    if subtitleTasks.activeTaskCount > 0 {
                        Text("\(subtitleTasks.activeTaskCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.black)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Circle().fill(settings.themeColor.color))
                    }
                }
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
            tabButton(title: "播放列表", index: 3)
            // 私密文件夹 Tab：受设置控制是否显示
            if settings.showVaultInTabBar {
                tabButton(title: "私密文件夹 🔒", index: 2)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var playlistBar: some View {
        HStack {
            Menu {
                ForEach(playlists.playlists) { playlist in
                    Button(playlist.name) { selectedPlaylistID = playlist.id }
                }
            } label: {
                Label(playlists.playlists.first(where: { $0.id == selectedPlaylistID })?.name ?? "选择播放列表", systemImage: "list.bullet")
                    .font(.system(size: 13, weight: .semibold))
            }
            Spacer()
            if let selectedPlaylistID {
                Button(role: .destructive) {
                    playlists.delete(selectedPlaylistID)
                    self.selectedPlaylistID = playlists.playlists.first?.id
                } label: { Image(systemName: "trash") }
                .accessibilityLabel("删除播放列表")
            }
            Button { showCreatePlaylist = true } label: { Image(systemName: "plus.circle.fill") }
                .accessibilityLabel("新建播放列表")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.top, 10)
    }

    private func tabButton(title: String, index: Int) -> some View {
        Button(action: {
            if index == 2 && !showVaultUnlocked {
                // 点击私密保险箱时根据设置决定是否触发 Face ID
                triggerVaultBiometrics()
            } else {
                withAnimation {
                    if index == 3 && selectedPlaylistID == nil { selectedPlaylistID = playlists.playlists.first?.id }
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

            Text(filterTab == 2 ? "私密文件夹为空" : (filterTab == 3 ? "播放列表为空" : "暂无视频文件"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            Text(filterTab == 2 ? "长按列表视频可将视频移入私密文件夹" : (filterTab == 3 ? "先新建播放列表，再从视频菜单添加视频" : "可以通过右上角 [+] 导入视频，或点击 [无线传片] 电脑免线快传"))
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private func triggerVaultBiometrics() {
        guard vault.hasPassword else { showVaultSetup = true; return }
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
            let copy = try await Task.detached(priority: .utility) { try PhotoImportStaging.copy(received.file) }.value
            return VideoTransferable(url: copy)
        }
    }
}
#endif
