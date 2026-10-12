import SwiftUI

@main
struct LovortPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            MediaLibraryHomeView()
                .preferredColorScheme(.dark)
        }
    }
}
