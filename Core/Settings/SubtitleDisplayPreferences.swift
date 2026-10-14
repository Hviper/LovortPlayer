import Foundation
import Combine

@MainActor
public final class SubtitleDisplayPreferences: ObservableObject {
    public static let shared = SubtitleDisplayPreferences()
    @Published public var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "subtitle.enabled") } }
    @Published public var textMode: SubtitleExportTextMode { didSet { UserDefaults.standard.set(textMode.rawValue, forKey: "subtitle.textMode") } }
    @Published public var scale: Double { didSet { UserDefaults.standard.set(scale, forKey: "subtitle.scale") } }
    @Published public var verticalOffset: Double { didSet { UserDefaults.standard.set(verticalOffset, forKey: "subtitle.verticalOffset") } }
    private init() {
        enabled = UserDefaults.standard.object(forKey: "subtitle.enabled") as? Bool ?? true
        textMode = SubtitleExportTextMode(rawValue: UserDefaults.standard.string(forKey: "subtitle.textMode") ?? "") ?? .bilingual
        scale = max(0.7, min(1.6, UserDefaults.standard.object(forKey: "subtitle.scale") as? Double ?? 1))
        verticalOffset = max(-0.08, min(0.12, UserDefaults.standard.double(forKey: "subtitle.verticalOffset")))
    }
    public func offset(for url: URL?) -> Double {
        guard let url else { return 0 }
        return UserDefaults.standard.double(forKey: "subtitle.timeOffset.\(MediaIdentityStore.shared.id(for: url))")
    }
    public func setOffset(_ value: Double, for url: URL) {
        objectWillChange.send()
        UserDefaults.standard.set(max(-30, min(30, value)), forKey: "subtitle.timeOffset.\(MediaIdentityStore.shared.id(for: url))")
    }
}
