import Foundation

public enum DetectedMeetingSource: String, Equatable, Sendable {
    case googleMeet
    case feishu
}

public struct MeetingAccessibilitySnapshot: Equatable, Sendable {
    public var bundleIdentifier: String
    public var applicationName: String
    public var processIdentifier: Int32
    public var windowIdentifier: String
    public var windowTitle: String
    public var url: String?
    public var accessibilityLabels: [String]

    public init(
        bundleIdentifier: String,
        applicationName: String,
        processIdentifier: Int32,
        windowIdentifier: String,
        windowTitle: String,
        url: String?,
        accessibilityLabels: [String]
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.processIdentifier = processIdentifier
        self.windowIdentifier = windowIdentifier
        self.windowTitle = windowTitle
        self.url = url
        self.accessibilityLabels = accessibilityLabels
    }
}

public struct DetectedMeeting: Equatable, Identifiable, Sendable {
    public var id: String
    public var source: DetectedMeetingSource
    public var processIdentifier: Int32
    public var windowIdentifier: String

    public init(
        id: String,
        source: DetectedMeetingSource,
        processIdentifier: Int32,
        windowIdentifier: String
    ) {
        self.id = id
        self.source = source
        self.processIdentifier = processIdentifier
        self.windowIdentifier = windowIdentifier
    }
}

public enum MeetingSurfaceClassifier {
    public static func isCandidateApplication(
        bundleIdentifier: String,
        applicationName: String
    ) -> Bool {
        isBrowser(bundleIdentifier: bundleIdentifier)
            || isFeishu(
                bundleIdentifier: bundleIdentifier,
                applicationName: applicationName
            )
    }

    public static func isCandidateWindow(
        bundleIdentifier: String,
        applicationName: String,
        title: String
    ) -> Bool {
        let normalizedTitle = normalize(title)
        if isBrowser(bundleIdentifier: bundleIdentifier) {
            return normalizedTitle.contains("google meet")
                || normalizedTitle.contains("meet.google.com")
        }
        if isFeishu(bundleIdentifier: bundleIdentifier, applicationName: applicationName) {
            return normalizedTitle.contains("飞书会议")
                || normalizedTitle.contains("feishu meeting")
                || normalizedTitle.contains("lark meeting")
                || normalizedTitle.contains("video meeting")
                || normalizedTitle.contains("视频会议")
        }
        return false
    }

    public static func detect(_ snapshot: MeetingAccessibilitySnapshot) -> DetectedMeeting? {
        if isBrowser(bundleIdentifier: snapshot.bundleIdentifier) {
            return detectGoogleMeet(snapshot)
        }
        if isFeishu(
            bundleIdentifier: snapshot.bundleIdentifier,
            applicationName: snapshot.applicationName
        ) {
            return detectFeishu(snapshot)
        }
        return nil
    }

    private static func detectGoogleMeet(
        _ snapshot: MeetingAccessibilitySnapshot
    ) -> DetectedMeeting? {
        let meetingCode = googleMeetCode(snapshot.url)
        let title = normalize(snapshot.windowTitle)
        let identifiesMeet = meetingCode != nil
            || title.contains("google meet")
            || title.contains("meet.google.com")
        guard identifiesMeet, hasActiveCallControl(snapshot.accessibilityLabels) else {
            return nil
        }
        let identity = meetingCode
            ?? "\(snapshot.processIdentifier):\(snapshot.windowIdentifier)"
        return DetectedMeeting(
            id: "google-meet:\(identity)",
            source: .googleMeet,
            processIdentifier: snapshot.processIdentifier,
            windowIdentifier: snapshot.windowIdentifier
        )
    }

    private static func detectFeishu(
        _ snapshot: MeetingAccessibilitySnapshot
    ) -> DetectedMeeting? {
        let title = normalize(snapshot.windowTitle)
        let titleIdentifiesMeeting = title.contains("飞书会议")
            || title.contains("feishu meeting")
            || title.contains("lark meeting")
            || title.contains("video meeting")
            || title.contains("视频会议")
        guard titleIdentifiesMeeting,
              hasActiveCallControl(snapshot.accessibilityLabels) else {
            return nil
        }
        return DetectedMeeting(
            id: "feishu:\(snapshot.processIdentifier):\(snapshot.windowIdentifier)",
            source: .feishu,
            processIdentifier: snapshot.processIdentifier,
            windowIdentifier: snapshot.windowIdentifier
        )
    }

    private static func googleMeetCode(_ rawURL: String?) -> String? {
        guard let rawURL,
              let components = URLComponents(string: rawURL),
              components.host?.lowercased() == "meet.google.com" else {
            return nil
        }
        return components.path
            .split(separator: "/")
            .map(String.init)
            .first { component in
                component.range(
                    of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil
            }
            .map { $0.lowercased() }
    }

    private static func hasActiveCallControl(_ labels: [String]) -> Bool {
        let activeCallLabels = [
            "leave call",
            "end call",
            "leave meeting",
            "end meeting",
            "离开通话",
            "退出通话",
            "离开会议",
            "退出会议",
            "结束会议",
            "挂断",
        ]
        return labels.lazy
            .map(normalize)
            .contains { label in
                activeCallLabels.contains { label.contains($0) }
            }
    }

    private static func isBrowser(bundleIdentifier: String) -> Bool {
        let identifier = normalize(bundleIdentifier)
        return [
            "com.google.chrome",
            "com.microsoft.edgemac",
            "com.apple.safari",
            "company.thebrowser.browser",
            "com.brave.browser",
            "com.vivaldi.vivaldi",
            "com.operasoftware.opera",
        ].contains { identifier == $0 || identifier.hasPrefix("\($0).") }
    }

    private static func isFeishu(
        bundleIdentifier: String,
        applicationName: String
    ) -> Bool {
        let identifier = normalize(bundleIdentifier)
        let name = normalize(applicationName)
        return identifier.contains("lark")
            || identifier.contains("feishu")
            || identifier.contains("bytedance.ee")
            || name == "feishu"
            || name == "lark"
            || name.contains("飞书")
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public enum MeetingPromptTransition: Equatable, Sendable {
    case none
    case show(DetectedMeeting)
    case hide
}

public struct MeetingPromptPreferenceState: Codable, Equatable, Sendable {
    public static let dismissalLimit = 3

    public private(set) var automaticPromptsEnabled: Bool
    public private(set) var consecutiveDismissals: Int

    public init(
        automaticPromptsEnabled: Bool = true,
        consecutiveDismissals: Int = 0
    ) {
        self.automaticPromptsEnabled = automaticPromptsEnabled
        self.consecutiveDismissals = max(0, consecutiveDismissals)
    }

    /// Returns whether prompts remain enabled after this dismissal.
    @discardableResult
    public mutating func registerDismissal() -> Bool {
        guard automaticPromptsEnabled else { return false }
        consecutiveDismissals += 1
        if consecutiveDismissals >= Self.dismissalLimit {
            automaticPromptsEnabled = false
        }
        return automaticPromptsEnabled
    }

    public mutating func registerRecordingStarted() {
        consecutiveDismissals = 0
    }

    public mutating func resumeAutomaticPrompts() {
        automaticPromptsEnabled = true
        consecutiveDismissals = 0
    }
}

public struct MeetingPromptTracker: Sendable {
    public private(set) var presented: DetectedMeeting?

    private var promptedProcessByMeetingID: [String: Int32] = [:]

    public init() {}

    public mutating func observe(
        _ meetings: [DetectedMeeting],
        capturePhase: CapturePhase,
        automaticPromptsEnabled: Bool = true
    ) -> MeetingPromptTransition {
        guard automaticPromptsEnabled else {
            guard presented != nil else { return .none }
            presented = nil
            return .hide
        }
        if capturePhase != .idle && capturePhase != .error {
            for meeting in meetings {
                promptedProcessByMeetingID[meeting.id] = meeting.processIdentifier
            }
            guard presented != nil else { return .none }
            presented = nil
            return .hide
        }

        if let presented {
            if meetings.contains(where: { $0.id == presented.id }) {
                return .none
            }
            self.presented = nil
            return .hide
        }

        guard let next = meetings.first(where: {
            promptedProcessByMeetingID[$0.id] == nil
        }) else {
            return .none
        }
        promptedProcessByMeetingID[next.id] = next.processIdentifier
        presented = next
        return .show(next)
    }

    @discardableResult
    public mutating func dismiss() -> Bool {
        guard presented != nil else { return false }
        presented = nil
        return true
    }

    @discardableResult
    public mutating func applicationTerminated(processIdentifier: Int32) -> Bool {
        promptedProcessByMeetingID = promptedProcessByMeetingID.filter {
            $0.value != processIdentifier
        }
        guard presented?.processIdentifier == processIdentifier else { return false }
        presented = nil
        return true
    }
}
