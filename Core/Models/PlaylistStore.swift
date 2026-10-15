import Foundation
import Combine

public struct VideoPlaylist: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var videoIDs: [UUID]

    public init(id: UUID = UUID(), name: String, videoIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.videoIDs = videoIDs
    }
}

@MainActor
public final class PlaylistStore: ObservableObject {
    public static let shared = PlaylistStore()
    @Published public private(set) var playlists: [VideoPlaylist]
    private let storeURL: URL

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Playlists.json")
        if let data = try? Data(contentsOf: self.storeURL),
           let saved = try? JSONDecoder().decode([VideoPlaylist].self, from: data) {
            playlists = saved
        } else {
            playlists = []
        }
    }

    @discardableResult
    public func create(name: String) -> VideoPlaylist? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !playlists.contains(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else { return nil }
        let playlist = VideoPlaylist(name: trimmed)
        playlists.append(playlist)
        save()
        return playlist
    }

    public func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }),
              !playlists.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        playlists[index].name = trimmed
        save()
    }

    public func delete(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    public func contains(videoID: UUID, in playlistID: UUID) -> Bool {
        playlists.first(where: { $0.id == playlistID })?.videoIDs.contains(videoID) == true
    }

    public func setVideo(_ videoID: UUID, in playlistID: UUID, included: Bool) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].videoIDs.removeAll { $0 == videoID }
        if included { playlists[index].videoIDs.append(videoID) }
        save()
    }

    public func removeVideo(_ videoID: UUID) {
        for index in playlists.indices { playlists[index].videoIDs.removeAll { $0 == videoID } }
        save()
    }

    public func orderedVideos(_ videos: [VideoItem], in playlistID: UUID) -> [VideoItem] {
        guard let playlist = playlists.first(where: { $0.id == playlistID }) else { return [] }
        let lookup = Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0) })
        return playlist.videoIDs.compactMap { lookup[$0] }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(playlists).write(to: storeURL, options: .atomic)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: storeURL.path)
            #endif
        } catch {
            NSLog("Failed to save playlists: %@", error.localizedDescription)
        }
    }
}
