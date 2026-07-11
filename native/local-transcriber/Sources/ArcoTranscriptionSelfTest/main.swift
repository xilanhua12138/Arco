import ArcoTranscriptionCore
import Foundation

@main
struct ArcoTranscriptionSelfTest {
    static func main() throws {
        try testStereoSplit()
        try testEndpointing()
        try testAttribution()
        try testTranscriptWriter()
        try testModelCatalog()
        print("5 local transcription contract tests passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw RuntimeError("Self-test failed: \(message)") }
    }

    private static func testStereoSplit() throws {
        let bytes: [UInt8] = [0x00, 0x40, 0x00, 0xC0, 0xFF, 0x7F, 0x00, 0x00]
        let split = PCMDecoder.splitStereoInt16LE(Data(bytes))
        try require(split.system.count == 2, "stereo frame count")
        try require(abs(split.system[0] - 0.5) < 0.0001, "system sample decoding")
        try require(abs(split.microphone[0] + 0.5) < 0.0001, "microphone sample decoding")
        try require(split.system[1] > 0.99 && split.microphone[1] == 0, "channel isolation")
    }

    private static func testEndpointing() throws {
        var detector = StreamingEndpointDetector(
            threshold: 0.01,
            minimumSpeechSamples: 4,
            trailingSilenceSamples: 3,
            preRollSamples: 2
        )
        try require(detector.push([0.001, -0.001, 0]).isEmpty, "noise rejection")
        let emitted = detector.push([0, 0.4, 0.3, 0.2, 0.1, 0, 0, 0])
        try require(emitted.count == 1, "speech finalization")
        try require(emitted[0].samples.contains(0.4), "speech preservation")
        try require(emitted[0].endSample > emitted[0].startSample, "utterance timing")
    }

    private static func testAttribution() throws {
        let intervals = [
            SpeakerInterval(speaker: 0, start: 0, end: 1.1),
            SpeakerInterval(speaker: 1, start: 1.0, end: 3.0),
        ]
        try require(
            SpeakerAttribution.dominantSpeaker(from: intervals, start: 0.5, end: 2.5) == 1,
            "maximum-overlap speaker attribution"
        )
        try require(
            SpeakerAttribution.dominantSpeaker(from: [], start: 0, end: 1) == nil,
            "empty speaker timeline"
        )
    }

    private static func testTranscriptWriter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcript = directory.appendingPathComponent("transcript.md")
        try Data("# Meeting\n\n".utf8).write(to: transcript)
        let writer = TranscriptWriter(path: transcript, sessionStartedAt: Date(timeIntervalSince1970: 43_200))
        try writer.append(TranscriptSegment(channel: 1, speaker: 2, text: "  hello  ", start: 2, end: 3.5))
        let output = try String(contentsOf: transcript, encoding: .utf8)
        try require(output.contains("In room 3:** hello"), "location speaker label")
        try require(
            output.contains("channel=1 speaker=2 stream=local start=2.000 end=3.500"),
            "timing metadata"
        )
    }

    private static func testModelCatalog() throws {
        try require(LocalModelID.whisperTiny.expectedBytes == 77_691_713, "Whisper Tiny byte contract")
        try require(LocalModelID.whisperBase.expectedBytes == 147_951_465, "Whisper Base byte contract")
        try require(LocalModelID.whisperSmall.expectedBytes == 487_601_967, "Whisper Small byte contract")
        try require(LocalModelID.whisperMedium.expectedBytes == 1_533_763_059, "Whisper Medium byte contract")
        try require(LocalModelID.whisperLarge.expectedBytes == 3_095_033_483, "Whisper Large byte contract")
        try require(LocalModelID.nemotron.expectedBytes == nil, "Core ML models use manifest validation")
    }
}
