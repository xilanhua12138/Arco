import ArcoNativeUI
import Darwin
import Foundation

private enum GPTLiveProcessError: LocalizedError, Sendable {
    case workerUnavailable
    case recorderUnavailable
    case alreadyRunning
    case credentialOperationRunning
    case startupTimedOut
    case launchFailed(String)
    case workerFailed(String)
    case exited(Int32)

    var errorDescription: String? {
        switch self {
        case .workerUnavailable:
            "GPT Live is not included in this Arco build."
        case .recorderUnavailable:
            "Arco's audio recorder is unavailable for GPT Live."
        case .alreadyRunning:
            "A GPT Live session is already running."
        case .credentialOperationRunning:
            "Another ChatGPT sign-in operation is already running."
        case .startupTimedOut:
            "GPT Live took too long to connect. Try again."
        case let .launchFailed(message):
            "GPT Live could not start: \(message)"
        case let .workerFailed(message):
            message
        case let .exited(status):
            "GPT Live exited unexpectedly (status \(status))."
        }
    }
}

@MainActor
final class GPTLiveProcessLauncher {
    private var current: GPTLiveProcessHandle?
    private var credentialProcess: Process?

    func credentialStatus() async throws -> GPTLiveCredentialStatus {
        try await runCredentialCommand("auth-status")
    }

    func login() async throws -> GPTLiveCredentialStatus {
        try await runCredentialCommand("login")
    }

    func logout() async throws -> GPTLiveCredentialStatus {
        try await runCredentialCommand("logout")
    }

    func start(request: GPTLiveSessionRequest) async throws -> any GPTLiveSessionHandle {
        guard current == nil else { throw GPTLiveProcessError.alreadyRunning }
        guard let workerURL = Self.resolveExecutable(
            override: "ARCO_GPT_LIVE_BIN",
            bundledName: "arco-gpt-live",
            developmentRelativePath: "rust/arco-gpt-live/target/debug/arco-gpt-live"
        ) else { throw GPTLiveProcessError.workerUnavailable }
        guard let recorderURL = Self.resolveExecutable(
            override: "ARCO_RECORDER_BIN",
            bundledName: "recorder",
            developmentRelativePath: "native/recorder"
        ) else { throw GPTLiveProcessError.recorderUnavailable }

        let process = Process()
        let input = Pipe()
        let errors = Pipe()
        process.executableURL = workerURL
        process.arguments = [
            "session",
            "--ack", "gpt-live-beta-private-api",
            "--recorder", recorderURL.path,
            "--mode", request.mode.rawValue,
            "--transcript", request.transcriptPath,
            "--provider", request.provider.rawValue,
        ]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors

        let handle = GPTLiveProcessHandle(
            process: process,
            input: input,
            errors: errors
        )
        handle.onTermination = { [weak self, weak handle] in
            guard let self, let handle, self.current === handle else { return }
            self.current = nil
        }
        current = handle
        handle.installMonitoring()
        do {
            try process.run()
        } catch {
            handle.abandonBeforeLaunch()
            current = nil
            throw GPTLiveProcessError.launchFailed(error.localizedDescription)
        }

        let timeout = Task { @MainActor [weak handle] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            handle?.failStartup(GPTLiveProcessError.startupTimedOut)
        }
        defer { timeout.cancel() }
        do {
            try await handle.waitUntilConnected()
            return handle
        } catch {
            await handle.stop()
            if current === handle { current = nil }
            throw error
        }
    }

    func stop() async {
        guard let current else { return }
        await current.stop()
        if self.current === current { self.current = nil }
    }

    func stopImmediately() {
        current?.stopImmediately()
        current = nil
        if credentialProcess?.isRunning == true { credentialProcess?.terminate() }
        credentialProcess = nil
    }

    private func runCredentialCommand(_ command: String) async throws -> GPTLiveCredentialStatus {
        guard credentialProcess == nil else { throw GPTLiveProcessError.credentialOperationRunning }
        guard let workerURL = Self.resolveExecutable(
            override: "ARCO_GPT_LIVE_BIN",
            bundledName: "arco-gpt-live",
            developmentRelativePath: "rust/arco-gpt-live/target/debug/arco-gpt-live"
        ) else { throw GPTLiveProcessError.workerUnavailable }

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = workerURL
        process.arguments = [command, "--ack", "gpt-live-beta-private-api"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        credentialProcess = process
        do {
            try process.run()
        } catch {
            credentialProcess = nil
            throw GPTLiveProcessError.launchFailed(error.localizedDescription)
        }

        let result = await Task.detached(priority: .userInitiated) {
            process.waitUntilExit()
            return (
                process.terminationStatus,
                output.fileHandleForReading.readDataToEndOfFile(),
                errors.fileHandleForReading.readDataToEndOfFile()
            )
        }.value
        if credentialProcess === process { credentialProcess = nil }

        let (terminationStatus, stdout, stderr) = result
        guard terminationStatus == 0 else {
            let message = String(data: stderr, encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .compactMap { GPTLiveWorkerStatus.parse(line: String($0))?.message }
                .last
            throw GPTLiveProcessError.workerFailed(
                message ?? "ChatGPT sign-in did not complete. Try again."
            )
        }
        guard stdout.count <= 4_096,
              let line = String(data: stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let status = GPTLiveCredentialStatus.parse(line: line)
        else {
            throw GPTLiveProcessError.workerFailed("Arco could not read the ChatGPT sign-in status.")
        }
        return status
    }

    private static func resolveExecutable(
        override environmentKey: String,
        bundledName: String,
        developmentRelativePath: String
    ) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates: [URL?] = [
            environment[environmentKey].map { URL(fileURLWithPath: $0) },
            Bundle.main.resourceURL?
                .appendingPathComponent("native", isDirectory: true)
                .appendingPathComponent(bundledName),
            repositoryRoot.appendingPathComponent(developmentRelativePath),
        ]
        return candidates.compactMap { $0 }.first(where: { url in
            FileManager.default.isExecutableFile(atPath: url.path)
        })
    }

    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 6 { url.deleteLastPathComponent() }
        return url
    }()
}

@MainActor
private final class GPTLiveProcessHandle: GPTLiveSessionHandle {
    private let process: Process
    private let input: Pipe
    private let errors: Pipe
    private var stderrBuffer = Data()
    private var connected = false
    private var stopping = false
    private var exited = false
    private var terminalError: (any Error)?
    private var startupContinuation: CheckedContinuation<Void, any Error>?
    private var exitContinuation: CheckedContinuation<Void, any Error>?

    var onTermination: (() -> Void)?

    init(process: Process, input: Pipe, errors: Pipe) {
        self.process = process
        self.input = input
        self.errors = errors
    }

    func installMonitoring() {
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor [weak self] in
                self?.processTerminated(status: status)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] file in
            let data = file.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.consumeStderr(data)
            }
        }
    }

    func abandonBeforeLaunch() {
        errors.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        try? input.fileHandleForWriting.close()
        try? errors.fileHandleForReading.close()
    }

    func waitUntilConnected() async throws {
        if connected { return }
        if let terminalError { throw terminalError }
        if exited { throw GPTLiveProcessError.exited(process.terminationStatus) }
        try await withCheckedThrowingContinuation { continuation in
            startupContinuation = continuation
        }
    }

    func waitUntilExit() async throws {
        if exited {
            if let terminalError { throw terminalError }
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            exitContinuation = continuation
        }
    }

    func stop() async {
        guard !exited else { return }
        stopping = true
        if process.isRunning {
            try? input.fileHandleForWriting.write(contentsOf: Data("stop\n".utf8))
        }
        try? input.fileHandleForWriting.close()

        for _ in 0 ..< 40 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { process.terminate() }
        for _ in 0 ..< 20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning, process.processIdentifier > 1 {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    func stopImmediately() {
        stopping = true
        try? input.fileHandleForWriting.write(contentsOf: Data("stop\n".utf8))
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    func failStartup(_ error: any Error) {
        guard !connected, !exited else { return }
        terminalError = error
        resumeStartup(with: .failure(error))
        stopImmediately()
    }

    private func consumeStderr(_ data: Data) {
        guard !exited else { return }
        stderrBuffer.append(data)
        guard stderrBuffer.count <= 64 * 1_024 else {
            failStartup(GPTLiveProcessError.workerFailed("GPT Live returned too much startup output."))
            return
        }
        while let newline = stderrBuffer.firstRange(of: Data([0x0A])) {
            var line = stderrBuffer[..<newline.lowerBound]
            if line.last == 0x0D { line = line.dropLast() }
            stderrBuffer.removeSubrange(...newline.lowerBound)
            guard let text = String(data: line, encoding: .utf8),
                  let status = GPTLiveWorkerStatus.parse(line: text)
            else { continue }
            consume(status)
        }
    }

    private func consume(_ status: GPTLiveWorkerStatus) {
        switch status.state {
        case .connected:
            guard !stopping, !connected else { return }
            connected = true
            resumeStartup(with: .success(()))
        case .error:
            let error = GPTLiveProcessError.workerFailed(
                status.message ?? "GPT Live reported an unknown error."
            )
            terminalError = error
            if connected {
                stopImmediately()
            } else {
                resumeStartup(with: .failure(error))
                stopImmediately()
            }
        case .connecting, .speaking, .disconnecting:
            break
        }
    }

    private func processTerminated(status: Int32) {
        guard !exited else { return }
        exited = true
        errors.fileHandleForReading.readabilityHandler = nil
        try? errors.fileHandleForReading.close()
        try? input.fileHandleForWriting.close()

        if terminalError == nil, !stopping, status != 0 {
            terminalError = GPTLiveProcessError.exited(status)
        }
        if !connected {
            resumeStartup(
                with: .failure(
                    terminalError ?? GPTLiveProcessError.exited(status)
                )
            )
        }
        if let continuation = exitContinuation {
            exitContinuation = nil
            if let terminalError {
                continuation.resume(throwing: terminalError)
            } else {
                continuation.resume()
            }
        }
        onTermination?()
        onTermination = nil
    }

    private func resumeStartup(with result: Result<Void, any Error>) {
        guard let continuation = startupContinuation else { return }
        startupContinuation = nil
        continuation.resume(with: result)
    }
}
