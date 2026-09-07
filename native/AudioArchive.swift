import AVFoundation
import Darwin
import Foundation

// AAC archives are independent of the live PCM pipe. Only this writer's UUID
// directories and numbered M4A chunks are eligible for automatic eviction.
final class MeetingAudioArchive {
    let folder: URL
    private let directory: URL
    private let maxBytes: Int64
    private let segmentFrames: Int
    private var file: AVAudioFile?
    private var frames = 0
    private var index = 0
    private var lockDescriptor: Int32 = -1
    private var finished = false
    private let fm = FileManager.default
    private let reservation: Int64

    init(directory: URL, maxBytes: Int64, meetingID: String, transcript: String,
         segmentFrames: Int = 16_000 * 300) throws {
        guard directory.path.hasPrefix("/"), maxBytes > 0, segmentFrames > 0 else {
            throw Self.error("Invalid recording storage settings")
        }
        self.directory = directory
        self.maxBytes = maxBytes
        self.segmentFrames = segmentFrames
        // Reserve at least the uncompressed size plus container overhead. AAC
        // output is smaller; reserving before opening keeps the cap bounded.
        reservation = Int64(segmentFrames) * 4 + 65_536
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        folder = directory.appendingPathComponent("\(formatter.string(from: Date()))-\(UUID().uuidString.lowercased())")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent(".arco-archive.lock")
        lockDescriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            if lockDescriptor >= 0 { close(lockDescriptor); lockDescriptor = -1 }
            throw Self.error("Another recording is using this audio folder")
        }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            let metadata: [String: Any] = ["schemaVersion": 1, "owner": "app.arco.audio-archive",
                "meetingID": meetingID, "transcript": transcript, "startedAt": ISO8601DateFormatter().string(from: Date()),
                "format": "AAC 64 kbps, 16000 Hz, stereo", "systemChannel": 0, "microphoneChannel": 1]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("recording.json"), options: .atomic)
        } catch {
            close(lockDescriptor); lockDescriptor = -1
            throw error
        }
    }

    deinit { file = nil; if lockDescriptor >= 0 { close(lockDescriptor) } }

    func append(_ data: Data) throws {
        guard !finished else { throw Self.error("Recording archive is already closed") }
        guard data.count % 4 == 0 else { throw Self.error("Incomplete stereo PCM frame") }
        var offset = 0
        while offset < data.count {
            if file == nil { try openSegment() }
            guard let file else { throw Self.error("Recording file is unavailable") }
            let count = min(segmentFrames - frames, (data.count - offset) / 4)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
                  let channels = buffer.floatChannelData else { throw Self.error("Could not allocate recording audio buffer") }
            buffer.frameLength = AVAudioFrameCount(count)
            data.withUnsafeBytes { bytes in
                for i in 0..<count {
                    channels[0][i] = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + i * 4, as: Int16.self))) / 32768
                    channels[1][i] = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + i * 4 + 2, as: Int16.self))) / 32768
                }
            }
            try file.write(from: buffer)
            frames += count; offset += count * 4
            if frames == segmentFrames { self.file = nil; frames = 0 }
        }
    }

    func finish() throws {
        file = nil
        finished = true
        if lockDescriptor >= 0 { close(lockDescriptor); lockDescriptor = -1 }
    }

    private func openSegment() throws {
        try makeRoom()
        index += 1
        let url = folder.appendingPathComponent(String(format: "audio-%06d.m4a", index))
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 64_000,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant
        ])
    }

    private func makeRoom() throws {
        guard reservation <= maxBytes else { throw Self.error("Recording storage limit is too small for an audio segment") }
        let entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey])
        var dated: [(url: URL, date: Date)] = []
        for entry in entries {
            let created = try entry.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date.distantPast
            dated.append((entry, created))
        }
        dated.sort { left, right in
            if left.date == right.date { return left.url.lastPathComponent < right.url.lastPathComponent }
            return left.date < right.date
        }
        let folders = dated.map { $0.url }
        var chunks: [(URL, Int64)] = []
        var total: Int64 = 0
        for candidate in folders {
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  candidate.lastPathComponent.range(of: #"^\d{8}-\d{6}-[0-9a-f-]{36}$"#, options: .regularExpression) != nil else { continue }
            let marker = candidate.appendingPathComponent("recording.json")
            guard let metadata = try? Data(contentsOf: marker),
                  let json = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any],
                  json["owner"] as? String == "app.arco.audio-archive" else { continue }
            let contents = try fm.contentsOfDirectory(at: candidate, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            for chunk in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let properties = try chunk.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true else { continue }
                total += Int64(properties.fileSize ?? 0)
                if chunk.lastPathComponent.range(of: #"^audio-\d{6}\.m4a$"#, options: .regularExpression) != nil {
                    chunks.append((chunk, Int64(properties.fileSize ?? 0)))
                }
            }
        }
        for (chunk, bytes) in chunks {
            if total + reservation <= maxBytes { break }
            try fm.removeItem(at: chunk)
            total -= bytes
            let parent = chunk.deletingLastPathComponent()
            if parent != folder {
                let contents = try fm.contentsOfDirectory(atPath: parent.path)
                if contents == ["recording.json"] {
                    let marker = parent.appendingPathComponent("recording.json")
                    let size = (try marker.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                    try fm.removeItem(at: marker)
                    // rmdir never removes an unexpected file that appeared meanwhile.
                    _ = rmdir(parent.path)
                    total -= Int64(size)
                }
            }
        }
        guard total + reservation <= maxBytes else { throw Self.error("Could not free enough recording storage without removing unrelated files") }
        let attributes = try fm.attributesOfFileSystem(forPath: directory.path)
        guard (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0 > reservation + 50_000_000 else {
            throw Self.error("Not enough free disk space to save recording audio")
        }
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "ArcoAudioArchive", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// A slow/full/unplugged drive must never block the transcription pipe or allow
// an unbounded RAM queue. Stop only archiving and retain already finalized chunks.
final class AsyncMeetingAudioArchive {
    private let queue = DispatchQueue(label: "app.arco.audio-archive", qos: .utility)
    private let slots = DispatchSemaphore(value: 50)
    private let stateLock = NSLock()
    private var failed = false
    private var writer: MeetingAudioArchive?
    private let statusURL: URL

    init?(environment: [String: String]) {
        guard let path = environment["ARCO_AUDIO_ARCHIVE_CONFIG"] else { return nil }
        let configURL = URL(fileURLWithPath: path)
        statusURL = configURL.deletingLastPathComponent().appendingPathComponent("audio-archive-status.json")
        do {
            var config: [String: Any] = ["enabled": true, "maxBytes": 10_000_000_000 as Int64,
                "directory": environment["ARCO_AUDIO_ARCHIVE_DEFAULT"] ?? ""]
            if FileManager.default.fileExists(atPath: path) {
                config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any] ?? [:]
            }
            guard config["enabled"] as? Bool == true else { return nil }
            guard let directory = config["directory"] as? String, directory.hasPrefix("/"),
                  let maxBytes = config["maxBytes"] as? NSNumber else { throw MeetingAudioArchive.error("Invalid recording storage configuration") }
            queue.async { [self] in
                do {
                    writer = try MeetingAudioArchive(directory: URL(fileURLWithPath: directory), maxBytes: maxBytes.int64Value,
                        meetingID: environment["ARCO_MEETING_ID"] ?? "", transcript: environment["ARCO_TRANSCRIPT_PATH"] ?? "")
                    report(phase: "recording", error: nil)
                } catch { fail(error.localizedDescription) }
            }
        } catch { fail(error.localizedDescription) }
    }

    func append(_ data: Data) {
        stateLock.lock(); let stopped = failed; stateLock.unlock()
        guard !stopped else { return }
        guard slots.wait(timeout: .now()) == .success else {
            fail("Audio storage is too slow; recording audio was only partially saved")
            return
        }
        queue.async { [self] in
            defer { slots.signal() }
            do { try writer?.append(data) }
            catch { fail(error.localizedDescription); try? writer?.finish(); writer = nil }
        }
    }

    func finish() {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            try? writer?.finish()
            stateLock.lock(); let hasFailed = failed; stateLock.unlock()
            if !hasFailed { report(phase: "saved", error: nil) }
            done.signal()
        }
        if done.wait(timeout: .now() + 1.2) == .timedOut {
            fail("Audio storage did not finish before shutdown; the last audio segment may be incomplete")
        }
    }

    private func fail(_ message: String) {
        stateLock.lock(); failed = true; stateLock.unlock()
        report(phase: "partial", error: message)
        FileHandle.standardError.write(Data("ARCO_AUDIO_ARCHIVE_ERROR: \(message)\n".utf8))
    }

    private func report(phase: String, error: String?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard phase == "partial" || !failed else { return }
        var status: [String: Any] = ["phase": phase, "updatedAt": ISO8601DateFormatter().string(from: Date())]
        if let error { status["error"] = error }

        if let data = try? JSONSerialization.data(withJSONObject: status) {
            try? data.write(to: statusURL, options: .atomic)
        }
    }
}
