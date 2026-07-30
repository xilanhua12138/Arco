import Foundation

public struct ArcoReleaseInfo: Equatable, Sendable {
    public var version: String
    public var dmgURL: URL
    public var checksumURL: URL
    public var notes: String?

    public init(version: String, dmgURL: URL, checksumURL: URL, notes: String? = nil) {
        self.version = version
        self.dmgURL = dmgURL
        self.checksumURL = checksumURL
        self.notes = notes
    }
}

public enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(ArcoReleaseInfo)
    case downloading(version: String, progress: Double)
    case installing(version: String)
    case failed(String)

    public var availableRelease: ArcoReleaseInfo? {
        guard case let .available(info) = self else { return nil }
        return info
    }

    public var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing: true
        case .idle, .upToDate, .available, .failed: false
        }
    }
}

/// Semantic version comparison for Arco's `major.minor.patch` tags.
public enum ArcoVersionComparison {
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParts = parts(candidate)
        let currentParts = parts(current)
        guard !candidateParts.isEmpty, !currentParts.isEmpty else { return false }
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let left = index < candidateParts.count ? candidateParts[index] : 0
            let right = index < currentParts.count ? currentParts[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int] {
        var value = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return [] }
        var result: [Int] = []
        for component in components {
            guard let number = Int(component) else { return [] }
            result.append(number)
        }
        return result
    }
}

@MainActor
public final class UpdateManager: ObservableObject {
    @Published public private(set) var state: UpdateState = .idle
    public let currentVersion: String

    public struct Dependencies {
        public var fetchLatestRelease: () async throws -> ArcoReleaseInfo
        public var downloadUpdate: (ArcoReleaseInfo, @Sendable (Double) -> Void) async throws -> URL
        public var installUpdate: (URL) async throws -> Void

        public init(
            fetchLatestRelease: @escaping () async throws -> ArcoReleaseInfo,
            downloadUpdate: @escaping (ArcoReleaseInfo, @Sendable (Double) -> Void) async throws -> URL,
            installUpdate: @escaping (URL) async throws -> Void
        ) {
            self.fetchLatestRelease = fetchLatestRelease
            self.downloadUpdate = downloadUpdate
            self.installUpdate = installUpdate
        }
    }

    private let dependencies: Dependencies

    public init(currentVersion: String, dependencies: Dependencies) {
        self.currentVersion = currentVersion
        self.dependencies = dependencies
    }

    public func checkForUpdates() async {
        guard !state.isBusy else { return }
        state = .checking
        do {
            let release = try await dependencies.fetchLatestRelease()
            if ArcoVersionComparison.isNewer(release.version, than: currentVersion) {
                state = .available(release)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func installUpdate() async {
        guard case let .available(release) = state else { return }
        state = .downloading(version: release.version, progress: 0)
        do {
            let dmg = try await dependencies.downloadUpdate(release) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self,
                          case .downloading = self.state else { return }
                    self.state = .downloading(
                        version: release.version,
                        progress: min(1, max(0, progress))
                    )
                }
            }
            state = .installing(version: release.version)
            try await dependencies.installUpdate(dmg)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
