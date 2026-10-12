import SwiftUI
import LovortPlayerUI

@main
struct LovortPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            MediaLibraryHomeView()
                .preferredColorScheme(.dark)
        }
    }
}
