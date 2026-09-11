import AppKit
import Combine
import CryptoKit
import Foundation

/// Optional setup, shared by onboarding and Settings. Never invoked by Invite Arco.
@MainActor
public final class MeetingAudioSetupModel: ObservableObject {
    public enum State: Equatable { case missing, downloading, installing, ready, restartRequired, failed }
    public struct Dependencies {
        public var detect: () -> State
        public var download: () async throws -> URL
        public var install: (URL) async throws -> Void
        public init(detect: @escaping () -> State, download: @escaping () async throws -> URL,
                    install: @escaping (URL) async throws -> Void) {
            self.detect = detect; self.download = download; self.install = install
        }
        public static var live: Self {
            Self(detect: MeetingAudioInstaller.detect, download: MeetingAudioInstaller.download,
                 install: MeetingAudioInstaller.install)
        }
    }

    @Published public private(set) var state: State = .missing
    @Published public private(set) var skipped: Bool
    @Published public private(set) var errorKey: String?
    private let dependencies: Dependencies
    private let canInstall: () -> Bool
    private let defaults: UserDefaults?
    public var busy: Bool { state == .downloading || state == .installing }

    public init(dependencies: Dependencies = .live, defaults: UserDefaults? = .standard,
                canInstall: @escaping () -> Bool = { true }) {
        self.dependencies = dependencies; self.defaults = defaults; self.canInstall = canInstall
        skipped = defaults?.bool(forKey: "arco.meetingAudioSetupSkipped") ?? false
        refresh()
    }

    public func refresh() {
        guard !busy else { return }
        state = dependencies.detect()
        if state == .ready || state == .restartRequired { errorKey = nil }
    }

    public func skip() {
        guard !busy else { return }
        skipped = true
        errorKey = nil
        state = dependencies.detect()
        defaults?.set(true, forKey: "arco.meetingAudioSetupSkipped")
    }

    public func configure() async {
        guard !busy else { return }
        errorKey = nil
        guard canInstall() else { errorKey = "meetingAudio.inMeeting"; return }
        refresh()
        guard state != .ready && state != .restartRequired else { return }
        state = .downloading
        do {
            let package = try await dependencies.download()
            // Capture may have started during download. Never restart audio in that case.
            guard canInstall() else { state = .missing; errorKey = "meetingAudio.inMeeting"; return }
            state = .installing
            try await dependencies.install(package)
            state = dependencies.detect()
            if state == .missing { state = .failed; errorKey = "meetingAudio.installFailed" }
            if state == .ready || state == .restartRequired {
                skipped = false
                defaults?.set(false, forKey: "arco.meetingAudioSetupSkipped")
            }
        } catch {
            let wasDownloading = state == .downloading
            state = .failed
            errorKey = wasDownloading ? "meetingAudio.downloadFailed" : "meetingAudio.installFailed"
        }
    }
}

private enum MeetingAudioInstaller {
    static let checksum = "57b540f27a3e29c37e310e01bee0fdfab76733087e47f997ef9dccf851400dcf"
    static let packageURL = URL(string: "https://existential.audio/downloads/BlackHole2ch-0.7.1.pkg")!

    static func detect() -> MeetingAudioSetupModel.State {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("native/arco-gpt-live")
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("rust/arco-gpt-live/target/debug/arco-gpt-live")
        let override = ProcessInfo.processInfo.environment["ARCO_GPT_LIVE_BIN"].map { URL(fileURLWithPath: $0) }
        if let worker = [override, bundled, development].compactMap({ $0 }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            let process = Process(); let output = Pipe()
            process.executableURL = worker; process.arguments = ["meeting-audio-status"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            do {
                try process.run(); process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0,
                   let status = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   status["ready"] as? Bool == true { return .ready }
            } catch { }
        }
        return FileManager.default.fileExists(atPath: "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver")
            ? .restartRequired : .missing
    }

    static func download() async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: packageURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try await Task.detached {
            let data = try Data(contentsOf: temporary)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == checksum else {
                throw URLError(.cannotDecodeContentData)
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArcoMeetingAudio-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let package = directory.appendingPathComponent("BlackHole2ch.pkg")
            try data.write(to: package, options: .atomic)
            return package
        }.value
    }

    static func install(_ package: URL) async throws {
        // Only a pinned, verified official package is accepted. Arco does not ship a renamed driver.
        try await Task.detached {
            defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
            let data = try Data(contentsOf: package)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == checksum else {
                throw URLError(.cannotDecodeContentData)
            }
            let signature = Process()
            signature.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
            signature.arguments = ["--check-signature", package.path]
            signature.standardOutput = FileHandle.nullDevice
            signature.standardError = FileHandle.nullDevice
            try signature.run(); signature.waitUntilExit()
            guard signature.terminationStatus == 0 else { throw URLError(.secureConnectionFailed) }

            // The system owns the authentication prompt; Arco never handles passwords.
            let quotedPath = "'" + package.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            // Reverify a root-owned copy after authorization, so a replaced download
            // cannot cross the privilege boundary while the system prompt is open.
            let command = """
            set -eu
            arco_stage=$(/usr/bin/mktemp -d /private/tmp/arco-meeting-audio.XXXXXX)
            trap '/bin/rm -rf "$arco_stage"' EXIT
            /bin/cp \(quotedPath) "$arco_stage/component.pkg"
            arco_hash=$(/usr/bin/shasum -a 256 "$arco_stage/component.pkg")
            test "${arco_hash%% *}" = '\(checksum)'
            /usr/sbin/pkgutil --check-signature "$arco_stage/component.pkg" >/dev/null
            /usr/sbin/installer -pkg "$arco_stage/component.pkg" -target /
            """
            let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"\(literal)\" with administrator privileges"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.userCancelled) }
        }.value
    }
}
