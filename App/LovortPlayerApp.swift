#if canImport(LovortPlayerCore)
import LovortPlayerCore
#endif
import SwiftUI
import AVFoundation

@main
struct LovortPlayerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    init() {
        PhotoImportStaging.removeAbandoned()
        PlayerViewModel.removeAbandonedPrivateClips()
        #if os(iOS)
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay])
            try audioSession.setActive(true)
        } catch {
            print("Failed to configure AVAudioSession at app launch: \(error)")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            MediaLibraryHomeView()
                .preferredColorScheme(.dark)
                .task { SubtitleVideoExporter.shared.cleanupExpired() }
                .onChange(of: scenePhase) { _, phase in
                    #if os(iOS)
                    PrivacyShield.shared.setVisible(phase != .active)
                    #endif
                }
        }
    }
}
