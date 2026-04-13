import Foundation
import MacFanControlCore

struct ProfileData: Codable {
    var profiles: [FanProfile]
    var activeProfileID: UUID?
}

@MainActor
final class ProfileStore: ObservableObject {

    @Published var profiles: [FanProfile] = []
    @Published var activeProfileID: UUID? = nil

    var activeProfile: FanProfile? {
        guard let id = activeProfileID else { return nil }
        return profiles.first { $0.id == id }
    }

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MacFanControl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("profiles.json")
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode(ProfileData.self, from: data) else { return }
        self.profiles = decoded.profiles
        self.activeProfileID = decoded.activeProfileID
    }

    private func save() {
        let payload = ProfileData(profiles: profiles, activeProfileID: activeProfileID)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        // Atomic write to avoid partial reads.
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Mutations

    func addProfile(_ profile: FanProfile) {
        profiles.append(profile)
        save()
    }

    func updateProfile(_ profile: FanProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
            save()
        }
    }

    func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id {
            activeProfileID = nil
        }
        save()
    }

    func setActiveProfile(_ id: UUID?) {
        activeProfileID = id
        save()
    }
}
