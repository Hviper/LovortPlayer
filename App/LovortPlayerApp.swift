#if canImport(LovortPlayerCore)
import LovortPlayerCore
#endif
import SwiftUI
import AVFoundation
#if os(iOS)
import BackgroundTasks
#endif

@main
struct LovortPlayerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    init() {
        PhotoImportStaging.removeAbandoned()
        PlayerViewModel.removeAbandonedPrivateClips()
        #if os(iOS)
        registerSubtitleBackgroundTask()
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay])
            try audioSession.setActive(true)
        } catch {
            print("Failed to configure AVAudioSession at app launch: \(error)")
        }
        #endif
    }

    #if os(iOS)
    private func registerSubtitleBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: SubtitleTaskManager.backgroundTaskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            task.expirationHandler = {
                Task { @MainActor in
                    SubtitleTaskManager.shared.cancelForBackgroundExpiration()
                }
            }
            Task { @MainActor in
                let manager = SubtitleTaskManager.shared
                await manager.runForBackgroundProcessing()
                task.setTaskCompleted(success: manager.activeTaskCount == 0)
            }
        }
    }

    private func scheduleSubtitleBackgroundTask() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: SubtitleTaskManager.backgroundTaskIdentifier)
        let request = BGProcessingTaskRequest(identifier: SubtitleTaskManager.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15)
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif

    var body: some Scene {
        WindowGroup {
            MediaLibraryHomeView()
                .preferredColorScheme(.dark)
                .task { SubtitleVideoExporter.shared.cleanupExpired() }
                .onChange(of: scenePhase) { _, phase in
                    #if os(iOS)
                    PrivacyShield.shared.setVisible(phase != .active)
                    if phase == .background {
                        scheduleSubtitleBackgroundTask()
                    } else if phase == .active {
                        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: SubtitleTaskManager.backgroundTaskIdentifier)
                        SubtitleTaskManager.shared.resumeAfterForeground()
                    }
                    #endif
                }
        }
    }
}
