import CoreML
import FluidAudio
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LocalModelID: String, CaseIterable, Codable, Sendable {
    case nemotron = "nemotron-speech-3.5-streaming"
    case whisperTiny = "whisper-tiny"
    case whisperBase = "whisper-base"
    case whisperSmall = "whisper-small"
    case whisperMedium = "whisper-medium"
    case whisperLarge = "whisper-large"
    case sortformer = "sortformer-streaming"
    case pyannoteWeSpeaker = "pyannote-wespeaker-streaming"
    case lseendAmi = "lseend-ami-streaming"
    case lseendDihard3 = "lseend-dihard3-streaming"

    public var isDiarizer: Bool {
        switch self {
        case .sortformer, .pyannoteWeSpeaker, .lseendAmi, .lseendDihard3: true
        default: false
        }
    }

    public var whisperFilename: String? {
        switch self {
        case .whisperTiny: "ggml-tiny.bin"
        case .whisperBase: "ggml-base.bin"
        case .whisperSmall: "ggml-small.bin"
        case .whisperMedium: "ggml-medium.bin"
        case .whisperLarge: "ggml-large-v3.bin"
        default: nil
        }
    }

    public var expectedBytes: Int64? {
        switch self {
        case .whisperTiny: 77_691_713
        case .whisperBase: 147_951_465
        case .whisperSmall: 487_601_967
        case .whisperMedium: 1_533_763_059
        case .whisperLarge: 3_095_033_483
        default: nil
        }
    }
}

public struct LocalModelStatus: Codable, Sendable {
    public let id: String
    public let installed: Bool
    public let phase: String
    public let progress: Double?
    public let error: String?
    public let path: String?

    public init(
        id: String,
        installed: Bool,
        phase: String,
        progress: Double? = nil,
        error: String? = nil,
        path: String? = nil
    ) {
        self.id = id
        self.installed = installed
        self.phase = phase
        self.progress = progress
        self.error = error
        self.path = path
    }
}

public struct ModelDirectories: Sendable {
    public let root: URL
    public var nemotron: URL { root.appendingPathComponent("nemotron", isDirectory: true) }
    public var whisper: URL { root.appendingPathComponent("whisper", isDirectory: true) }
    public var sortformer: URL { root.appendingPathComponent("sortformer", isDirectory: true) }
    public var pyannoteWeSpeaker: URL {
        root.appendingPathComponent("speaker-diarization", isDirectory: true)
    }
    public var lseend: URL { root.appendingPathComponent("lseend", isDirectory: true) }

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else if let override = ProcessInfo.processInfo.environment["ARCO_MODEL_DIR"] {
            self.root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = support.appendingPathComponent("Arco/models", isDirectory: true)
        }
    }

    public func marker(for model: LocalModelID) -> URL {
        root.appendingPathComponent(".\(model.rawValue).installed")
    }

    public func cacheDirectory(for model: LocalModelID) -> URL {
        switch model {
        case .sortformer: sortformer
        case .pyannoteWeSpeaker: pyannoteWeSpeaker
        case .lseendAmi, .lseendDihard3: lseend
        default: root
        }
    }

    public func installedDirectory(for model: LocalModelID) -> URL? {
        switch model {
        case .sortformer: sortformer
        case .pyannoteWeSpeaker: pyannoteWeSpeaker
        case .lseendAmi: lseend.appendingPathComponent("ls-eend/ami", isDirectory: true)
        case .lseendDihard3: lseend.appendingPathComponent("ls-eend/dih3", isDirectory: true)
        default: nil
        }
    }
}

public actor LocalModelManager {
    public let directories: ModelDirectories

    public init(directories: ModelDirectories = ModelDirectories()) {
        self.directories = directories
    }

    public func statuses() -> [LocalModelStatus] {
        LocalModelID.allCases.map(status)
    }

    public func status(_ model: LocalModelID) -> LocalModelStatus {
        let path: URL?
        switch model {
        case .nemotron:
            path = readMarker(model).map(URL.init(fileURLWithPath:))
        case .sortformer, .pyannoteWeSpeaker, .lseendAmi, .lseendDihard3:
            let installedDirectory = directories.installedDirectory(for: model)
            let hasModels = installedDirectory.map { directory in
                model == .pyannoteWeSpeaker
                    ? DiarizerModels.requiredModelNames.allSatisfy {
                        FileManager.default.fileExists(
                            atPath: directory.appendingPathComponent($0, isDirectory: true).path
                        )
                    }
                    : directoryHasContents(directory)
            } == true
            path = FileManager.default.fileExists(atPath: directories.marker(for: model).path)
                && hasModels
                ? installedDirectory : nil
        default:
            path = model.whisperFilename.map { directories.whisper.appendingPathComponent($0) }
        }
        let installed: Bool
        if model == .nemotron {
            installed = path.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("metadata.json").path) } ?? false
        } else if model.isDiarizer {
            installed = path != nil
        } else {
            let fileBytes = path.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
                .map(Int64.init)
            installed = fileBytes == model.expectedBytes
        }
        return LocalModelStatus(
            id: model.rawValue,
            installed: installed,
            phase: installed ? "ready" : "not-installed",
            progress: installed ? 1 : nil,
            path: installed ? path?.path : nil
        )
    }

    public func prepare(_ model: LocalModelID, progress: @escaping @Sendable (LocalModelStatus) -> Void) async throws {
        try FileManager.default.createDirectory(at: directories.root, withIntermediateDirectories: true)
        switch model {
        case .nemotron:
            try FileManager.default.createDirectory(at: directories.nemotron, withIntermediateDirectories: true)
            let path = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                languageCode: "auto",
                chunkMs: 560,
                to: directories.nemotron
            ) { snapshot in
                progress(LocalModelStatus(
                    id: model.rawValue,
                    installed: false,
                    phase: Self.phase(snapshot.phase),
                    progress: snapshot.fractionCompleted
                ))
            }
            try writeMarker(model, value: path.path)
        case .sortformer:
            try FileManager.default.createDirectory(at: directories.sortformer, withIntermediateDirectories: true)
            var config = SortformerConfig.fastV2_1
            config.precision = .palettized
            _ = try await SortformerModels.loadFromHuggingFace(
                config: config,
                cacheDirectory: directories.sortformer
            ) { snapshot in
                progress(LocalModelStatus(
                    id: model.rawValue,
                    installed: false,
                    phase: Self.phase(snapshot.phase),
                    progress: snapshot.fractionCompleted
                ))
            }
            try writeMarker(model, value: directories.sortformer.path)
        case .pyannoteWeSpeaker:
            try FileManager.default.createDirectory(at: directories.root, withIntermediateDirectories: true)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            _ = try await DiarizerModels.downloadIfNeeded(
                to: directories.pyannoteWeSpeaker,
                configuration: configuration
            ) { snapshot in
                progress(LocalModelStatus(
                    id: model.rawValue,
                    installed: false,
                    phase: Self.phase(snapshot.phase),
                    progress: snapshot.fractionCompleted
                ))
            }
            try writeMarker(model, value: directories.pyannoteWeSpeaker.path)
        case .lseendAmi, .lseendDihard3:
            try FileManager.default.createDirectory(at: directories.lseend, withIntermediateDirectories: true)
            progress(LocalModelStatus(
                id: model.rawValue,
                installed: false,
                phase: "downloading"
            ))
            let variant: LSEENDVariant = model == .lseendAmi ? .ami : .dihard3
            _ = try await LSEENDModel.loadFromHuggingFace(
                variant: variant,
                stepSize: .step100ms,
                cacheDirectory: directories.lseend,
                computeUnits: .cpuOnly
            )
            guard let installedDirectory = directories.installedDirectory(for: model) else {
                throw RuntimeError("Missing LS-EEND cache directory for \(model.rawValue).")
            }
            try writeMarker(model, value: installedDirectory.path)
        default:
            guard let filename = model.whisperFilename else { return }
            guard let expectedBytes = model.expectedBytes else {
                throw RuntimeError("Missing expected size for \(model.rawValue).")
            }
            try FileManager.default.createDirectory(at: directories.whisper, withIntermediateDirectories: true)
            let destination = directories.whisper.appendingPathComponent(filename)
            try await downloadWhisper(filename: filename, destination: destination, expectedBytes: expectedBytes) { fraction in
                progress(LocalModelStatus(
                    id: model.rawValue,
                    installed: false,
                    phase: "downloading",
                    progress: fraction
                ))
            }
        }
        progress(status(model))
    }

    public func remove(_ model: LocalModelID) throws {
        switch model {
        case .nemotron:
            try? FileManager.default.removeItem(at: directories.nemotron)
        case .sortformer, .pyannoteWeSpeaker, .lseendAmi, .lseendDihard3:
            if let directory = directories.installedDirectory(for: model) {
                try? FileManager.default.removeItem(at: directory)
            }
        default:
            if let filename = model.whisperFilename {
                try? FileManager.default.removeItem(at: directories.whisper.appendingPathComponent(filename))
            }
        }
        try? FileManager.default.removeItem(at: directories.marker(for: model))
    }

    public func nemotronPath() throws -> URL {
        guard let value = readMarker(.nemotron) else {
            throw RuntimeError("Nemotron Speech 3.5 is not installed.")
        }
        return URL(fileURLWithPath: value)
    }

    private func readMarker(_ model: LocalModelID) -> String? {
        try? String(contentsOf: directories.marker(for: model), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeMarker(_ model: LocalModelID, value: String) throws {
        try Data(value.utf8).write(to: directories.marker(for: model), options: .atomic)
    }

    private func directoryHasContents(_ directory: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        return !contents.isEmpty
    }

    private static func phase(_ phase: DownloadPhase) -> String {
        switch phase {
        case .listing, .downloading: "downloading"
        case .compiling: "optimizing"
        }
    }

    private func downloadWhisper(
        filename: String,
        destination: URL,
        expectedBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)") else {
            throw RuntimeError("Invalid Whisper model URL.")
        }
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RuntimeError("Whisper model download failed.")
        }
        let staged = destination.appendingPathExtension("download")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.moveItem(at: temporary, to: staged)
        let downloadedBytes = try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
        guard downloadedBytes == expectedBytes else {
            try? FileManager.default.removeItem(at: staged)
            throw RuntimeError(
                "Whisper model is incomplete: expected \(expectedBytes) bytes, received \(downloadedBytes)."
            )
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staged, to: destination)
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

public struct RuntimeError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
