import Combine
import Foundation
import SwiftUI

public enum GPTLiveSessionPhase: String, Equatable, Sendable {
    case idle
    case connecting
    case connected
    case disconnecting
    case failed
}

public struct GPTLiveSessionStatus: Equatable, Sendable {
    public var phase: GPTLiveSessionPhase
    public var message: String?
    public var activity: GPTLiveActivity
    public var audioLevel: Double
    public var meetingOutput: Bool

    public init(phase: GPTLiveSessionPhase, message: String? = nil,
                activity: GPTLiveActivity = .listening, audioLevel: Double = 0,
                meetingOutput: Bool = false) {
        self.phase = phase
        self.message = message
        self.activity = activity
        self.audioLevel = audioLevel.isFinite ? min(1, max(0, audioLevel)) : 0
        self.meetingOutput = meetingOutput
    }

    public static let idle = GPTLiveSessionStatus(phase: .idle)
}

public enum GPTLiveActivity: String, Equatable, Sendable {
    case listening, thinking, speaking
}

public struct GPTLiveSessionRequest: Equatable, Sendable {
    public let mode: AudioMode
    public let transcriptPath: String
    public let provider: ProviderID

    public init(mode: AudioMode, transcriptPath: String, provider: ProviderID) {
        self.mode = mode
        self.transcriptPath = transcriptPath
        self.provider = provider
    }
}

public enum GPTLiveCredentialPhase: String, Equatable, Sendable {
    case checking
    case missing
    case connected
    case connecting
    case failed
}

public struct GPTLiveCredentialStatus: Equatable, Sendable {
    public var phase: GPTLiveCredentialPhase
    public var identity: String?
    public var message: String?

    public init(
        phase: GPTLiveCredentialPhase,
        identity: String? = nil,
        message: String? = nil
    ) {
        self.phase = phase
        self.identity = identity
        self.message = message
    }

    public static let checking = GPTLiveCredentialStatus(phase: .checking)
    public static let missing = GPTLiveCredentialStatus(phase: .missing)

    public static func parse(line: String) -> GPTLiveCredentialStatus? {
        guard !line.isEmpty, line.utf8.count <= 4_096,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let allowed = Set(["configured", "valid", "accountId", "expiresAtMs", "email", "planType"])
        guard Set(object.keys).isSubset(of: allowed),
              let configured = object["configured"] as? Bool,
              let valid = object["valid"] as? Bool
        else { return nil }
        guard configured else { return .missing }
        guard valid else { return GPTLiveCredentialStatus(phase: .failed) }
        let identity = (object["email"] as? String) ?? (object["accountId"] as? String)
        guard let identity,
              !identity.isEmpty,
              identity.count <= 320,
              !identity.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return GPTLiveCredentialStatus(phase: .connected, identity: identity)
    }
}

public struct GPTLiveWorkerStatus: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case connecting
        case connected
        case speaking
        case listening
        case thinking
        case disconnecting
        case error
    }

    public let state: State
    public let message: String?
    public let audioLevel: Double
    public let meetingOutput: Bool

    public init(state: State, message: String? = nil, audioLevel: Double = 0,
                meetingOutput: Bool = false) {
        self.state = state
        self.message = message
        self.audioLevel = audioLevel
        self.meetingOutput = meetingOutput
    }

    public static func parse(line: String) -> GPTLiveWorkerStatus? {
        guard !line.isEmpty, line.utf8.count <= 4_096,
              let data = line.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.type == "status",
              let state = State(rawValue: envelope.state),
              envelope.message?.utf8.count ?? 0 <= 1_024
        else { return nil }
        let level = envelope.audioLevel ?? 0
        guard level.isFinite, (0...1).contains(level) else { return nil }
        return GPTLiveWorkerStatus(state: state, message: envelope.message,
                                  audioLevel: level, meetingOutput: envelope.meetingOutput ?? false)
    }

    private struct Envelope: Decodable {
        let type: String
        let state: String
        let message: String?
        let audioLevel: Double?
        let meetingOutput: Bool?
    }
}

/// A connected GPT Live worker owned by Arco. The UI only holds this bounded
/// lifecycle handle; OAuth credentials remain in the Rust credential store and never cross the
/// Swift process boundary.
@MainActor
public protocol GPTLiveSessionHandle: AnyObject {
    func waitUntilExit() async throws
    func stop() async
    func observeStatus(_ handler: @escaping @MainActor (GPTLiveWorkerStatus) -> Void)
}

public extension GPTLiveSessionHandle {
    func observeStatus(_ handler: @escaping @MainActor (GPTLiveWorkerStatus) -> Void) {}
}

public enum GPTLiveSessionLaunchError: LocalizedError {
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "GPT Live is not available in this build."
        }
    }
}

@_spi(Testing)
public enum GPTLiveButtonPresentation {
    public static func labelKey(for phase: GPTLiveSessionPhase) -> String {
        switch phase {
        case .idle: "agent.gptLiveConnect"
        case .connecting: "agent.voiceJoining"
        case .connected: "agent.voicePresent"
        case .disconnecting: "agent.gptLiveDisconnecting"
        case .failed: "agent.gptLiveRetry"
        }
    }

    public static func helpKey(for phase: GPTLiveSessionPhase) -> String {
        switch phase {
        case .idle, .failed: "agent.gptLiveConnectHelp"
        case .connecting: "agent.voiceShowHelp"
        case .connected: "agent.voiceShowHelp"
        case .disconnecting: "agent.gptLiveDisconnectingHelp"
        }
    }

    public static func isEnabled(for phase: GPTLiveSessionPhase) -> Bool {
        phase != .disconnecting
    }
}

/// Compact, explicit opt-in control shared by the docked and floating Ask Arco
/// surfaces. Merely opening either surface never starts a voice session.
public struct GPTLiveBetaButton: View {
    public let status: GPTLiveSessionStatus
    public let translate: ArcoTranslate
    public let action: @MainActor () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        status: GPTLiveSessionStatus,
        translate: @escaping ArcoTranslate = ArcoTranslations.english,
        action: @escaping @MainActor () -> Void
    ) {
        self.status = status
        self.translate = translate
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if status.phase == .connecting || status.phase == .disconnecting {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(foreground)
                        .frame(width: 13, height: 13)
                } else {
                    ArcoLucideIcon(.audioLines, size: 13, strokeWidth: 2.2)
                        .frame(width: 13, height: 13)
                }
                Text(translate(GPTLiveButtonPresentation.labelKey(for: status.phase), [:]))
                    .font(ArcoTypography.sans(11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(border, lineWidth: 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.96))
        .disabled(!GPTLiveButtonPresentation.isEnabled(for: status.phase))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : ArcoMotion.hover, value: hovering)
        .animation(reduceMotion ? nil : ArcoMotion.state, value: status.phase)
        .accessibilityLabel(
            translate(GPTLiveButtonPresentation.labelKey(for: status.phase), [:])
        )
        .accessibilityHint(
            status.message
                ?? translate(GPTLiveButtonPresentation.helpKey(for: status.phase), [:])
        )
        .help(
            status.message
                ?? translate(GPTLiveButtonPresentation.helpKey(for: status.phase), [:])
        )
    }

    private var foreground: Color {
        switch status.phase {
        case .connected:
            ArcoNativeColors.actionInk
        case .failed:
            ArcoNativeColors.warning
        case .idle, .connecting, .disconnecting:
            ArcoNativeColors.inkStrong
        }
    }

    private var background: Color {
        switch status.phase {
        case .connected:
            hovering ? ArcoNativeColors.actionHover : ArcoNativeColors.action
        case .failed:
            ArcoNativeColors.warning.opacity(hovering ? 0.15 : 0.10)
        case .connecting, .disconnecting:
            ArcoNativeColors.brandSoft.opacity(hovering ? 1.0 : 0.78)
        case .idle:
            hovering ? ArcoNativeColors.surfaceHover : ArcoNativeColors.surfaceSubtle
        }
    }

    private var border: Color {
        switch status.phase {
        case .connected:
            Color.clear
        case .failed:
            ArcoNativeColors.warning.opacity(0.28)
        case .idle, .connecting, .disconnecting:
            ArcoNativeColors.line
        }
    }
}

/// Owns the user-visible session states independently of capture state. A
/// monotonically increasing generation prevents a late worker start from
/// reconnecting after the user has already cancelled.
@MainActor
public final class GPTLiveSessionModel: ObservableObject {
    public typealias Start = (_ request: GPTLiveSessionRequest) async throws -> any GPTLiveSessionHandle
    public typealias StopPending = () async -> Void

    @Published public private(set) var status: GPTLiveSessionStatus = .idle

    private let start: Start
    private let stopPending: StopPending
    private var handle: (any GPTLiveSessionHandle)?
    private var monitorTask: Task<Void, Never>?
    private var generation = 0

    public init(
        start: @escaping Start,
        stopPending: @escaping StopPending
    ) {
        self.start = start
        self.stopPending = stopPending
    }

    public func toggle(request: GPTLiveSessionRequest) async {
        switch status.phase {
        case .idle, .failed:
            await connect(request: request)
        case .connecting, .connected:
            await disconnect()
        case .disconnecting:
            return
        }
    }

    public func disconnect() async {
        guard status.phase != .idle, status.phase != .disconnecting else { return }
        generation += 1
        let currentHandle = handle
        handle = nil
        monitorTask?.cancel()
        monitorTask = nil
        status = GPTLiveSessionStatus(phase: .disconnecting)

        if let currentHandle {
            await currentHandle.stop()
        } else {
            await stopPending()
        }
        status = .idle
    }

    public func connect(request: GPTLiveSessionRequest) async {
        guard status.phase == .idle || status.phase == .failed else { return }
        generation += 1
        let requestGeneration = generation
        status = GPTLiveSessionStatus(phase: .connecting)
        do {
            let nextHandle = try await start(request)
            guard requestGeneration == generation, status.phase == .connecting else {
                await nextHandle.stop()
                return
            }
            handle = nextHandle
            status = GPTLiveSessionStatus(phase: .connected)
            nextHandle.observeStatus { [weak self] update in
                guard let self, self.generation == requestGeneration,
                      self.status.phase == .connected else { return }
                let activity = GPTLiveActivity(rawValue: update.state.rawValue) ?? .listening
                let nextStatus = GPTLiveSessionStatus(
                    phase: .connected, activity: activity,
                    audioLevel: update.audioLevel, meetingOutput: update.meetingOutput
                )
                if self.status != nextStatus { self.status = nextStatus }
            }
            monitorTask?.cancel()
            monitorTask = Task { @MainActor [weak self] in
                do {
                    try await nextHandle.waitUntilExit()
                    self?.workerExited(
                        generation: requestGeneration,
                        message: "GPT Live connection ended unexpectedly."
                    )
                } catch {
                    self?.workerExited(
                        generation: requestGeneration,
                        message: error.localizedDescription
                    )
                }
            }
        } catch {
            guard requestGeneration == generation, status.phase == .connecting else { return }
            status = GPTLiveSessionStatus(
                phase: .failed,
                message: error.localizedDescription
            )
        }
    }

    private func workerExited(generation requestGeneration: Int, message: String) {
        guard requestGeneration == generation, status.phase == .connected else { return }
        handle = nil
        monitorTask = nil
        status = GPTLiveSessionStatus(phase: .failed, message: message)
    }
}
