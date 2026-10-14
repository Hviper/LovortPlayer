import SwiftUI
import AVFoundation

@main
struct LovortPlayerApp: App {
    init() {
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
        }
    }
}
