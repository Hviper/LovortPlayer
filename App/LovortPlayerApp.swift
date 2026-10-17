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
        SubtitleTaskManager.shared.onBackgroundRescheduleNeeded = {
            Self.scheduleSubtitleBackgroundTask()
        }
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
                let remainingWork = manager.hasPendingWork
                if remainingWork {
                    Self.scheduleSubtitleBackgroundTask()
                }
                task.setTaskCompleted(success: !remainingWork)
            }
        }
    }

    @MainActor
    static func scheduleSubtitleBackgroundTask() {
        let manager = SubtitleTaskManager.shared
        guard manager.hasPendingWork else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: SubtitleTaskManager.backgroundTaskIdentifier)
            return
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: SubtitleTaskManager.backgroundTaskIdentifier)
        let request = BGProcessingTaskRequest(identifier: SubtitleTaskManager.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = manager.requiresNetworkConnectivityForPendingWork
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15)
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[SubtitleBackgroundTask] Scheduled successfully (requiresNetwork: \(request.requiresNetworkConnectivity), earliestBeginDate: \(request.earliestBeginDate?.description ?? "nil"))")
        } catch {
            print("[SubtitleBackgroundTask] Scheduling failed: \(error.localizedDescription) (requiresNetwork: \(request.requiresNetworkConnectivity))")
        }
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
                        Self.scheduleSubtitleBackgroundTask()
                    } else if phase == .active {
                        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: SubtitleTaskManager.backgroundTaskIdentifier)
                        SubtitleTaskManager.shared.resumeAfterForeground()
                    }
                    #endif
                }
        }
    }
}
