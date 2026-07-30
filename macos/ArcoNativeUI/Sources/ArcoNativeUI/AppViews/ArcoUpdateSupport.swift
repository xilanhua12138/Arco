import AppKit
import CryptoKit
import Foundation

public enum UpdateError: LocalizedError {
    case releaseCheckFailed
    case downloadFailed
    case checksumMismatch
    case mountFailed
    case verificationFailed
    case installLocationNotWritable

    public var errorDescription: String? {
        switch self {
        case .releaseCheckFailed:
            "Could not check for updates. Check your network connection."
        case .downloadFailed:
            "Could not download the update."
        case .checksumMismatch:
            "The downloaded update failed its integrity check."
        case .mountFailed:
            "Could not open the downloaded update."
        case .verificationFailed:
            "The downloaded app failed code-signing verification."
        case .installLocationNotWritable:
            "Arco cannot replace /Applications/Arco.app. Check the app's permissions."
        }
    }
}

extension ArcoAppEnvironment {
    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/xilanhua12138/Arco/releases/latest"
    )!

    /// Queries GitHub for the newest published release and its DMG assets.
    public static func nativeFetchLatestRelease() async throws -> ArcoReleaseInfo {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Arco-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let assets = object["assets"] as? [[String: Any]]
        else { throw UpdateError.releaseCheckFailed }

        var dmg: URL?
        var checksum: URL?
        for asset in assets {
            guard let name = asset["name"] as? String,
                  let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString)
            else { continue }
            if name.hasSuffix(".dmg") { dmg = url }
            if name.hasSuffix(".dmg.sha256") { checksum = url }
        }
        guard let dmg, let checksum else { throw UpdateError.releaseCheckFailed }
        var version = tag
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        return ArcoReleaseInfo(
            version: version,
            dmgURL: dmg,
            checksumURL: checksum,
            notes: object["body"] as? String
        )
    }

    /// Downloads the release DMG with progress and verifies it against the
    /// published SHA-256 before returning the local file.
    public static func nativeDownloadUpdate(
        _ release: ArcoReleaseInfo,
        progress: @Sendable (Double) -> Void
    ) async throws -> URL {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("arco-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent("Arco-macos-update.dmg")

        let (bytes, response) = try await URLSession.shared.bytes(from: release.dmgURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }
        let expected = response.expectedContentLength
        fileManager.createFile(atPath: dmg.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dmg)
        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= (1 << 20) {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if expected > 0 { progress(Double(received) / Double(expected)) }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw UpdateError.downloadFailed
        }
        progress(1)

        let (checksumData, checksumResponse) = try await URLSession.shared.data(from: release.checksumURL)
        guard let checksumHTTP = checksumResponse as? HTTPURLResponse, checksumHTTP.statusCode == 200,
              let checksumText = String(data: checksumData, encoding: .utf8),
              let expectedHash = checksumText.split(separator: " ").first?.lowercased(),
              !expectedHash.isEmpty
        else { throw UpdateError.downloadFailed }
        let actualHash = SHA256.hash(data: try Data(contentsOf: dmg))
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualHash == expectedHash else { throw UpdateError.checksumMismatch }
        return dmg
    }

    /// Mounts the verified DMG, checks the app's code signature, then hands the
    /// swap to a detached script that waits for this process to exit before
    /// replacing /Applications/Arco.app and relaunching it.
    public static func nativeInstallUpdate(_ dmg: URL) async throws {
        let fileManager = FileManager.default
        let target = URL(fileURLWithPath: "/Applications/Arco.app")
        if fileManager.fileExists(atPath: target.path) {
            guard fileManager.isWritableFile(atPath: target.path) else {
                throw UpdateError.installLocationNotWritable
            }
        } else {
            guard fileManager.isWritableFile(atPath: "/Applications") else {
                throw UpdateError.installLocationNotWritable
            }
        }

        let work = dmg.deletingLastPathComponent()
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        try fileManager.createDirectory(at: mount, withIntermediateDirectories: true)
        guard runUpdateProcess("/usr/bin/hdiutil", [
            "attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path,
        ]) else { throw UpdateError.mountFailed }
        let mountedApp = mount.appendingPathComponent("Arco.app", isDirectory: true)
        guard runUpdateProcess("/usr/bin/codesign", ["-v", mountedApp.path]) else {
            _ = runUpdateProcess("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
            throw UpdateError.verificationFailed
        }

        let script = work.appendingPathComponent("install.sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptContents = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        if ditto "\(mountedApp.path)" "\(target.path)"; then
          /usr/bin/hdiutil detach "\(mount.path)" -quiet 2>/dev/null
          rm -rf "\(work.path)"
          open "\(target.path)"
        fi
        """
        try scriptContents.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            _ = runUpdateProcess("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
            throw UpdateError.mountFailed
        }
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func runUpdateProcess(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
