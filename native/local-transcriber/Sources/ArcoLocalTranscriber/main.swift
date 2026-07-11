import ArcoTranscriptionCore
import Foundation

@main
struct ArcoLocalTranscriberMain {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else {
                throw RuntimeError("Expected models, prepare, remove, or stream.")
            }
            switch command {
            case "models":
                try await printStatuses()
            case "prepare":
                try await prepare(arguments: Array(arguments.dropFirst()))
            case "remove":
                try await remove(arguments: Array(arguments.dropFirst()))
            case "stream":
                try await stream(arguments: Array(arguments.dropFirst()))
            default:
                throw RuntimeError("Unknown local transcriber command: \(command)")
            }
        } catch {
            FileHandle.standardError.write(Data("arco-local-transcriber: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func printStatuses() async throws {
        let statuses = await LocalModelManager().statuses()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(statuses))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func prepare(arguments: [String]) async throws {
        guard let rawModel = option("--model", in: arguments), let model = LocalModelID(rawValue: rawModel) else {
            throw RuntimeError("prepare requires a supported --model.")
        }
        let manager = LocalModelManager()
        let modelProgress = ProgressEmitter()
        try await manager.prepare(model) { status in modelProgress.emit(status) }
        if option("--diarization", in: arguments) == "local-streaming" && model != .sortformer {
            let diarizationProgress = ProgressEmitter()
            try await manager.prepare(.sortformer) { status in diarizationProgress.emit(status) }
        }
        try await printStatuses()
    }

    private static func remove(arguments: [String]) async throws {
        guard let rawModel = option("--model", in: arguments), let model = LocalModelID(rawValue: rawModel) else {
            throw RuntimeError("remove requires a supported --model.")
        }
        try await LocalModelManager().remove(model)
        try await printStatuses()
    }

    private static func stream(arguments: [String]) async throws {
        guard
            let rawModel = option("--model", in: arguments),
            let model = LocalModelID(rawValue: rawModel),
            model != .sortformer,
            let transcriptPath = arguments.last,
            !transcriptPath.hasPrefix("--")
        else {
            throw RuntimeError("stream requires --model, --language, --diarization, and a transcript path.")
        }
        let language = option("--language", in: arguments) ?? "auto"
        let diarization = option("--diarization", in: arguments) ?? "none"
        let manager = LocalModelManager()
        let directories = await manager.directories
        let provider: any LocalTranscriptionProvider
        if model == .nemotron {
            provider = try await NemotronTranscriptionProvider(modelDirectory: manager.nemotronPath())
        } else if let filename = model.whisperFilename {
            let modelURL = directories.whisper.appendingPathComponent(filename)
            provider = try WhisperTranscriptionProvider(modelURL: modelURL)
        } else {
            throw RuntimeError("Unsupported transcription model: \(model.rawValue)")
        }

        let localDiarizer: StreamingSpeakerDiarizer?
        if diarization == "local-streaming" {
            guard await manager.status(.sortformer).installed else {
                throw RuntimeError("Streaming Sortformer is not installed.")
            }
            localDiarizer = try await StreamingSpeakerDiarizer(cacheDirectory: directories.sortformer)
        } else {
            localDiarizer = nil
        }

        let startedAt = ProcessInfo.processInfo.environment["ARCO_SESSION_STARTED_AT_UNIX"]
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:)) ?? Date()
        let writer = TranscriptWriter(
            path: URL(fileURLWithPath: transcriptPath),
            sessionStartedAt: startedAt
        )
        let runner = LocalStreamRunner(
            provider: provider,
            diarizer: localDiarizer,
            writer: writer,
            language: language
        )
        try signalReady()

        while let data = try FileHandle.standardInput.read(upToCount: 6_400), !data.isEmpty {
            try await runner.consume(data)
        }
        try await runner.finish()
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func signalReady() throws {
        guard let path = ProcessInfo.processInfo.environment["ARCO_READY_FILE"], !path.isEmpty else { return }
        try Data("ready\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

}

private final class ProgressEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPhase: String?
    private var lastProgress: Double?

    func emit(_ status: LocalModelStatus) {
        lock.lock()
        let phaseChanged = status.phase != lastPhase
        let progressChanged = status.progress.map { progress in
            lastProgress.map { progress - $0 >= 0.01 } ?? true
        } ?? phaseChanged
        let shouldEmit = phaseChanged || progressChanged || status.installed || status.error != nil
        if shouldEmit {
            lastPhase = status.phase
            lastProgress = status.progress
        }
        lock.unlock()

        guard shouldEmit, let data = try? JSONEncoder().encode(status) else { return }
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data("\n".utf8))
    }
}
