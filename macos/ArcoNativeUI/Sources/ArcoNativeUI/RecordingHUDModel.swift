import Foundation
import Observation

@MainActor
@Observable
public final class RecordingHUDModel {
    public private(set) var capture = CaptureState(
        phase: .starting,
        activeMeetingId: nil,
        startedAt: nil,
        message: nil,
        mode: nil,
        transcriptPath: nil,
        error: nil,
        transcription: nil
    )
    public private(set) var now = Date()
    public private(set) var saving = false
    public private(set) var saved = false

    private let readCapture: () async throws -> CaptureState
    private let stopCapture: () async throws -> CaptureState
    private let onStopped: @MainActor () -> Void
    private let capturePollInterval: Duration
    private let clockInterval: Duration

    @ObservationIgnored private var capturePollTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var monitoringGeneration = 0

    public init(
        readCapture: @escaping () async throws -> CaptureState,
        stopCapture: @escaping () async throws -> CaptureState,
        onStopped: @escaping @MainActor () -> Void,
        capturePollInterval: Duration = .milliseconds(700),
        clockInterval: Duration = .seconds(1)
    ) {
        self.readCapture = readCapture
        self.stopCapture = stopCapture
        self.onStopped = onStopped
        self.capturePollInterval = capturePollInterval
        self.clockInterval = clockInterval
    }

    deinit {
        capturePollTask?.cancel()
        clockTask?.cancel()
    }

    public var isMonitoring: Bool {
        capturePollTask != nil && clockTask != nil
    }

    public func startMonitoring() {
        guard capturePollTask == nil, clockTask == nil else { return }

        monitoringGeneration &+= 1
        let generation = monitoringGeneration
        capturePollTask = Task { @MainActor [weak self] in
            await self?.pollCapture(generation: generation)
        }
        clockTask = Task { @MainActor [weak self] in
            await self?.runClock(generation: generation)
        }
    }

    public func stopMonitoring() {
        monitoringGeneration &+= 1
        capturePollTask?.cancel()
        clockTask?.cancel()
        capturePollTask = nil
        clockTask = nil
    }

    public func stop() async {
        guard !saving, !saved else { return }
        saving = true
        capture.phase = .stopping
        defer {
            saving = false
            // The old stop_capture command hid both owned windows whether the
            // capture stop succeeded or failed.
            onStopped()
        }
        do {
            capture = try await stopCapture()
            saved = true
        } catch {
            capture.phase = .error
        }
    }

    public var elapsed: String {
        guard let raw = capture.startedAt,
              let started = Self.parseDate(raw) else { return "00:00" }
        let total = max(0, Int(now.timeIntervalSince(started)))
        let hours = total / 3_600
        let minutes = total % 3_600 / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public var controlsLocked: Bool {
        saving || saved || capture.phase == .starting || capture.phase == .stopping
    }

    private func pollCapture(generation: Int) async {
        while !Task.isCancelled {
            guard monitoringGeneration == generation else { return }
            do {
                let next = try await readCapture()
                guard !Task.isCancelled,
                      monitoringGeneration == generation else { return }
                let reusedForNewRecording = saved && next.phase == .recording
                if !saving && (!saved || reusedForNewRecording) {
                    capture = next
                    if reusedForNewRecording { saved = false }
                }
            } catch {
                guard !Task.isCancelled,
                      monitoringGeneration == generation else { return }
                capture.phase = .error
            }

            do {
                try await Task.sleep(for: capturePollInterval)
            } catch {
                return
            }
        }
    }

    private func runClock(generation: Int) async {
        while !Task.isCancelled {
            guard monitoringGeneration == generation else { return }
            now = Date()
            do {
                try await Task.sleep(for: clockInterval)
            } catch {
                return
            }
        }
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: raw) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
