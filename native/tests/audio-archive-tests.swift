import AVFoundation
import Foundation

@main struct ArchiveTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arco-archive-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try MeetingAudioArchive(directory: root, maxBytes: 50_000_000, meetingID: "test-meeting", transcript: "/test.md", segmentFrames: 16_000)
        let samples: [Int16] = (0..<32_000).map { i in Int16(sin(Double(i / 2) * (i % 2 == 0 ? 0.17 : 0.31)) * 8000) }
        let pcm = samples.withUnsafeBytes { Data($0) }
        try archive.append(pcm)
        try archive.append(pcm)
        try archive.finish()
        let files = try FileManager.default.contentsOfDirectory(at: archive.folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "m4a" }.sorted { $0.path < $1.path }
        precondition(files.count == 2, "One second segment boundary must preserve both chunks")
        for url in files {
            let decoded = try AVAudioFile(forReading: url)
            precondition(decoded.processingFormat.channelCount == 2)
            precondition(decoded.processingFormat.sampleRate == 16_000)
            precondition(decoded.length == 16_000, "AAC playback must retain exact input duration")
            let buffer = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 16_000)!
            try decoded.read(into: buffer)
            precondition(buffer.floatChannelData![0][2000] != buffer.floatChannelData![1][2000], "Keep system and microphone separate")
        }

        do { try archive.append(pcm); fatalError("Append after close must fail") } catch { }
        let boundaryRoot = root.appendingPathComponent("retention")
        var older: MeetingAudioArchive? = try MeetingAudioArchive(directory: boundaryRoot, maxBytes: 50_000_000, meetingID: "older", transcript: "/older.md", segmentFrames: 16_000)
        try older!.append(pcm)
        let oldFolder = older!.folder
        try older!.finish(); older = nil
        let sortedOld = boundaryRoot.appendingPathComponent("20000101-000000-00000000-0000-0000-0000-000000000000")
        try FileManager.default.moveItem(at: oldFolder, to: sortedOld)
        let unrelated = boundaryRoot.appendingPathComponent("keep.wav")
        try Data(repeating: 9, count: 300_000).write(to: unrelated)
        let external = root.appendingPathComponent("outside.m4a")
        try Data("do not delete".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: sortedOld.appendingPathComponent("audio-999999.m4a"), withDestinationURL: external)
        let newer = try MeetingAudioArchive(directory: boundaryRoot, maxBytes: 150_000, meetingID: "newer", transcript: "/newer.md", segmentFrames: 16_000)
        do {
            _ = try MeetingAudioArchive(directory: boundaryRoot, maxBytes: 150_000, meetingID: "concurrent", transcript: "", segmentFrames: 16_000)
            fatalError("Concurrent writers must be excluded")
        } catch { }
        try newer.append(pcm)
        try newer.finish()
        precondition(!FileManager.default.fileExists(atPath: sortedOld.appendingPathComponent("audio-000001.m4a").path), "Evict oldest owned audio first")
        precondition(FileManager.default.fileExists(atPath: newer.folder.appendingPathComponent("audio-000001.m4a").path))
        precondition((try! Data(contentsOf: unrelated)) == Data(repeating: 9, count: 300_000))
        precondition((try! Data(contentsOf: external)) == Data("do not delete".utf8))
        let invalid = try MeetingAudioArchive(directory: root.appendingPathComponent("invalid"), maxBytes: 50_000_000, meetingID: "invalid", transcript: "")
        do { try invalid.append(Data([1, 2, 3])); fatalError("Partial stereo frames must fail") } catch { }
        try invalid.append(Data())
        try invalid.finish()
        precondition((try! FileManager.default.contentsOfDirectory(atPath: invalid.folder.path)) == ["recording.json"])
        let tooSmall = try MeetingAudioArchive(directory: root.appendingPathComponent("small"), maxBytes: 1, meetingID: "small", transcript: "")
        do { try tooSmall.append(pcm); fatalError("A segment must not exceed the budget") } catch { }
        try tooSmall.finish()
        let blocked = root.appendingPathComponent("blocked")
        try Data("occupied".utf8).write(to: blocked)
        do { _ = try MeetingAudioArchive(directory: blocked, maxBytes: 50_000_000, meetingID: "blocked", transcript: ""); fatalError("Invalid destination must fail") } catch { }
        let minute = try MeetingAudioArchive(directory: root.appendingPathComponent("estimate"), maxBytes: 50_000_000, meetingID: "estimate", transcript: "")
        for _ in 0..<60 { try minute.append(pcm) }
        try minute.finish()
        let minuteFile = minute.folder.appendingPathComponent("audio-000001.m4a")
        let minuteBytes = try minuteFile.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        precondition((try! AVAudioFile(forReading: minuteFile)).length == 60 * 16_000)
        print("60-second AAC bytes=\(minuteBytes), projected MB/hour=\(Double(minuteBytes) * 60 / 1_000_000)")

        let configPath = root.appendingPathComponent("audio-archive.json")
        let disabledDirectory = root.appendingPathComponent("disabled")
        let disabledData = try JSONSerialization.data(withJSONObject: ["enabled": false, "directory": disabledDirectory.path, "maxBytes": 10_000_000_000])
        try disabledData.write(to: configPath)
        let disabled = AsyncMeetingAudioArchive(environment: ["ARCO_AUDIO_ARCHIVE_CONFIG": configPath.path])
        precondition(disabled == nil && !FileManager.default.fileExists(atPath: disabledDirectory.path))
        let asyncRoot = root.appendingPathComponent("async")
        try JSONSerialization.data(withJSONObject: ["enabled": true, "directory": asyncRoot.path, "maxBytes": 10_000_000_000]).write(to: configPath)
        let asyncArchive = AsyncMeetingAudioArchive(environment: ["ARCO_AUDIO_ARCHIVE_CONFIG": configPath.path])!
        asyncArchive.append(pcm); asyncArchive.finish()
        let savedStatus = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("audio-archive-status.json"))) as! [String: Any]
        precondition(savedStatus["phase"] as? String == "saved")
        let denied = root.appendingPathComponent("read-only")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o500])
        do { _ = try MeetingAudioArchive(directory: denied, maxBytes: 50_000_000, meetingID: "denied", transcript: ""); fatalError("Read-only destination must fail") } catch { }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
        try JSONSerialization.data(withJSONObject: ["enabled": true, "directory": blocked.path, "maxBytes": 10_000_000_000]).write(to: configPath)
        let unavailable = AsyncMeetingAudioArchive(environment: ["ARCO_AUDIO_ARCHIVE_CONFIG": configPath.path])!
        unavailable.append(pcm); unavailable.finish()
        let errorStatus = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("audio-archive-status.json"))) as! [String: Any]
        precondition(errorStatus["phase"] as? String == "partial")
        precondition((errorStatus["error"] as? String)?.contains("file") == true || (errorStatus["error"] as? String)?.contains("文件") == true)
        print("PASS: oldest-first eviction, unrelated files, symlinks, exclusive access, empty/invalid PCM, tiny limit, unavailable directory")
        print("PASS: compressed AAC round trip and exact segment durations")
        print("encodedBytes=\(try files.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }) pcmBytes=\(pcm.count * 2)")
    }
}
