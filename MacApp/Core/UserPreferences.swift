import Foundation
import Combine

@MainActor
public final class UserPreferences: ObservableObject {
    public static let shared = UserPreferences()

    private enum Keys {
        static let autoStartService = "autoStartService"
        static let serverHost = "serverHost"
        static let serverPort = "serverPort"
    }

    private let defaults = UserDefaults.standard

    @Published public var autoStartService: Bool {
        didSet {
            defaults.set(autoStartService, forKey: Keys.autoStartService)
        }
    }

    @Published public var serverHost: String {
        didSet {
            defaults.set(serverHost, forKey: Keys.serverHost)
        }
    }

    @Published public var serverPort: Int {
        didSet {
            defaults.set(serverPort, forKey: Keys.serverPort)
        }
    }

    public init() {
        self.autoStartService = defaults.bool(forKey: Keys.autoStartService)
        self.serverHost = defaults.string(forKey: Keys.serverHost) ?? "0.0.0.0"
        let savedPort = defaults.integer(forKey: Keys.serverPort)
        self.serverPort = savedPort > 0 ? savedPort : 8765
    }
}
