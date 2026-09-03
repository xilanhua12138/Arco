import ArcoNativeUI
import Foundation

private var failures: [String] = []
private var assertionCount = 0

@MainActor
private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    assertionCount += 1
    if actual != expected {
        failures.append("\(message): expected \(expected), got \(actual)")
    }
}

@MainActor
private func expectNil<T>(_ value: T?, _ message: String) {
    assertionCount += 1
    if value != nil { failures.append(message) }
}

private let meetPrejoin = MeetingAccessibilitySnapshot(
    bundleIdentifier: "com.google.Chrome",
    applicationName: "Google Chrome",
    processIdentifier: 501,
    windowIdentifier: "chrome-window-7",
    windowTitle: "Google Meet",
    url: "https://meet.google.com/abc-defg-hij",
    accessibilityLabels: ["Microphone", "Camera", "Join now"]
)

private let meetInCall = MeetingAccessibilitySnapshot(
    bundleIdentifier: "com.google.Chrome",
    applicationName: "Google Chrome",
    processIdentifier: 501,
    windowIdentifier: "chrome-window-7",
    windowTitle: "Weekly research sync - Google Meet",
    url: "https://meet.google.com/abc-defg-hij",
    accessibilityLabels: ["Turn off microphone", "Turn off camera", "Leave call"]
)

private let feishuHome = MeetingAccessibilitySnapshot(
    bundleIdentifier: "com.bytedance.ee.lark.mac",
    applicationName: "Feishu",
    processIdentifier: 702,
    windowIdentifier: "feishu-window-2",
    windowTitle: "Feishu",
    url: nil,
    accessibilityLabels: ["Meetings", "Join meeting", "Calendar"]
)

private let feishuInCall = MeetingAccessibilitySnapshot(
    bundleIdentifier: "com.bytedance.ee.lark.mac",
    applicationName: "Feishu",
    processIdentifier: 702,
    windowIdentifier: "feishu-window-9",
    windowTitle: "Product review - Feishu Meeting",
    url: nil,
    accessibilityLabels: ["Mute", "Participants", "Leave meeting"]
)

@MainActor
private func testClassifierRequiresAnActiveCallControl() {
    expectNil(
        MeetingSurfaceClassifier.detect(meetPrejoin),
        "A Google Meet lobby must not be mistaken for an active call"
    )
    expectNil(
        MeetingSurfaceClassifier.detect(feishuHome),
        "The normal Feishu workspace must not be mistaken for an active call"
    )
    expectNil(
        MeetingSurfaceClassifier.detect(MeetingAccessibilitySnapshot(
            bundleIdentifier: "com.apple.TextEdit",
            applicationName: "TextEdit",
            processIdentifier: 303,
            windowIdentifier: "document-1",
            windowTitle: "Meeting notes",
            url: nil,
            accessibilityLabels: ["Leave call"]
        )),
        "An unsupported app must not trigger even if its document contains meeting words"
    )
}

@MainActor
private func testClassifierIdentifiesSupportedMeetings() {
    expect(
        MeetingSurfaceClassifier.detect(meetInCall),
        DetectedMeeting(
            id: "google-meet:abc-defg-hij",
            source: .googleMeet,
            processIdentifier: 501,
            windowIdentifier: "chrome-window-7"
        ),
        "An in-call Google Meet surface is identified by URL and Leave call control"
    )
    expect(
        MeetingSurfaceClassifier.detect(feishuInCall),
        DetectedMeeting(
            id: "feishu:702:feishu-window-9",
            source: .feishu,
            processIdentifier: 702,
            windowIdentifier: "feishu-window-9"
        ),
        "A Feishu call window is identified by its app and Leave meeting control"
    )
}

@MainActor
private func testPromptAppearsOnlyOncePerMeeting() {
    let first = MeetingSurfaceClassifier.detect(meetInCall)!
    let second = DetectedMeeting(
        id: "google-meet:xyz-abcd-efg",
        source: .googleMeet,
        processIdentifier: 501,
        windowIdentifier: "chrome-window-7"
    )
    var tracker = MeetingPromptTracker()

    expect(
        tracker.observe([first], capturePhase: .idle),
        .show(first),
        "The first active meeting presents the prompt"
    )
    expect(
        tracker.observe([first], capturePhase: .idle),
        .none,
        "Repeated accessibility events do not present the same meeting twice"
    )
    expect(tracker.dismiss(), true, "This time not dismisses the visible prompt")
    expect(
        tracker.observe([first], capturePhase: .idle),
        .none,
        "A dismissed meeting stays quiet for the rest of that session"
    )
    expect(
        tracker.observe([second], capturePhase: .idle),
        .show(second),
        "A different meeting in the same browser process can prompt"
    )
}

@MainActor
private func testCaptureSuppressesTheCurrentMeeting() {
    let meeting = MeetingSurfaceClassifier.detect(feishuInCall)!
    var tracker = MeetingPromptTracker()

    expect(
        tracker.observe([meeting], capturePhase: .idle),
        .show(meeting),
        "An idle Arco prompts for the meeting"
    )
    expect(
        tracker.observe([meeting], capturePhase: .starting),
        .hide,
        "Starting capture immediately hides the meeting prompt"
    )
    expect(
        tracker.observe([meeting], capturePhase: .idle),
        .none,
        "Stopping Arco during the same call does not prompt again"
    )
}

@MainActor
private func testRepeatedDismissalsPauseFuturePromptsUntilExplicitlyResumed() {
    var preference = MeetingPromptPreferenceState()
    expect(preference.registerDismissal(), true, "The first dismissal keeps future prompts enabled")
    expect(preference.consecutiveDismissals, 1, "The first dismissal is counted exactly")
    expect(preference.registerDismissal(), true, "The second dismissal keeps future prompts enabled")
    expect(preference.registerDismissal(), false, "The third consecutive dismissal pauses future prompts")
    expect(preference.automaticPromptsEnabled, false, "Paused prompts remain explicitly disabled")

    let nextMeeting = DetectedMeeting(
        id: "google-meet:new-call-123",
        source: .googleMeet,
        processIdentifier: 501,
        windowIdentifier: "chrome-window-11"
    )
    var tracker = MeetingPromptTracker()
    expect(
        tracker.observe(
            [nextMeeting],
            capturePhase: .idle,
            automaticPromptsEnabled: preference.automaticPromptsEnabled
        ),
        .none,
        "A paused preference prevents another meeting prompt"
    )

    preference.resumeAutomaticPrompts()
    expect(preference.automaticPromptsEnabled, true, "The Settings action explicitly restores prompts")
    expect(preference.consecutiveDismissals, 0, "Restoring prompts clears the old refusal count")
    preference.registerRecordingStarted()
    expect(preference.consecutiveDismissals, 0, "Starting from a prompt keeps the refusal count cleared")
}

private final class MemoryPreferenceStore: KeyValueStore {
    var values: [String: String] = [:]
    func contains(_ key: String) -> Bool { values[key] != nil }
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}

@MainActor
private func testMeetingPromptPreferencePersistsAcrossRelaunch() {
    let store = MemoryPreferenceStore()
    let preferences = ArcoPreferences(store: store)
    var preference = MeetingPromptPreferenceState()
    _ = preference.registerDismissal()
    _ = preference.registerDismissal()
    _ = preference.registerDismissal()
    preferences.saveMeetingPromptPreference(preference)

    expect(
        ArcoPreferences(store: store).loadMeetingPromptPreference(),
        preference,
        "The paused prompt preference and exact dismissal count survive relaunch"
    )
}

@MainActor
private func testTerminatedApplicationReleasesOldSessionFingerprints() {
    let meeting = MeetingSurfaceClassifier.detect(meetInCall)!
    var tracker = MeetingPromptTracker()

    expect(tracker.observe([meeting], capturePhase: .idle), .show(meeting), "Meeting initially prompts")
    expect(tracker.dismiss(), true, "Visible prompt can be dismissed")
    tracker.applicationTerminated(processIdentifier: 501)
    expect(
        tracker.observe([meeting], capturePhase: .idle),
        .show(meeting),
        "A browser relaunch may prompt for a genuinely new session at the same Meet URL"
    )
}

@MainActor
private func testPlatformUsesEventsAndReleasesTheMainSurfaceInMenuBarMode() {
    let sourcesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    func source(_ relativePath: String) -> String {
        (try? String(
            contentsOf: sourcesRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )) ?? ""
    }

    let monitor = source("ArcoApp/Platform/MeetingAccessibilityMonitor.swift")
    let menuBar = source("ArcoApp/Platform/MenuBarController.swift")
    let coordinator = source("ArcoApp/Platform/WindowCoordinator.swift")
    let prompt = source("ArcoNativeUI/MeetingPromptView.swift")
    let idle = source("ArcoNativeUI/SetupViews/CurrentIdleView.swift")
    let settings = source("ArcoNativeUI/AppViews/ArcoSettingsSheetView.swift")
    let application = source("ArcoApp/ArcoApplication.swift")

    expect(
        monitor.contains("AXObserverCreate")
            && monitor.contains("AXObserverAddNotification")
            && monitor.contains("kAXWindowCreatedNotification")
            && monitor.contains("kAXFocusedWindowChangedNotification")
            && monitor.contains("kAXTitleChangedNotification"),
        true,
        "Meeting awareness must react to Accessibility events instead of continuously polling windows"
    )
    expect(
        monitor.contains("maximumInspectedElements = 240")
            && !monitor.contains("scheduledTimer")
            && !monitor.contains("Task.sleep"),
        true,
        "Accessibility inspection must stay bounded and contain no repeating timer"
    )
    expect(
        menuBar.contains("NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)")
            && menuBar.contains("ArcoStatusTemplate")
            && menuBar.contains("NSSize(width: 18, height: 16)")
            && menuBar.contains("statusIcon.isTemplate = true")
            && menuBar.contains(".imagePosition = .imageOnly")
            && !menuBar.contains("statusItem.button?.title")
            && menuBar.contains("captureActive ? .systemRed : nil")
            && menuBar.contains("NSMenu")
            && !menuBar.contains("NSPopover"),
        true,
        "Menu bar mode must expose the Arco template icon without retaining a popover view tree"
    )
    expect(
        !menuBar.contains("let status = NSMenuItem")
            && !menuBar.contains("status.isEnabled = false"),
        true,
        "The compact menu must begin with actions instead of repeating the idle status"
    )
    expect(
        menuBar.contains("NSEvent.addGlobalMonitorForEvents")
            && menuBar.contains("cancelTracking()")
            && menuBar.contains("performSelector(")
            && menuBar.contains("RunLoop.Mode.eventTracking.rawValue")
            && menuBar.contains("NSEvent.removeMonitor"),
        true,
        "The menu must stop tracking when the user clicks another app or the desktop"
    )
    expect(
        settings.contains("settings.resumeMeetingPrompts")
            && settings.contains("onResumeMeetingPrompts")
            && !menuBar.contains("resumeMeetingPrompts"),
        true,
        "Restoring prompts belongs in Settings rather than the compact menu bar"
    )
    expect(
        coordinator.contains("showMeetingPrompt")
            && coordinator.contains(".nonactivatingPanel")
            && coordinator.contains("meetingPrompt.orderFrontRegardless()"),
        true,
        "The meeting prompt must appear above the meeting without stealing its focus"
    )
    expect(
        coordinator.contains("created.isReleasedWhenClosed = false")
            && coordinator.contains("mainWindow = nil")
            && coordinator.contains("NSApp.setActivationPolicy(.accessory)"),
        true,
        "Closing the main window must release its SwiftUI tree exactly once and leave only menu bar mode"
    )
    expect(
        prompt.contains("meetingPrompt.title")
            && prompt.contains("meetingPrompt.context")
            && prompt.contains("meetingPrompt.start")
            && prompt.contains("meetingPrompt.notThisTime"),
        true,
        "The prompt must use the approved natural copy and direct start button"
    )
    expect(
        !idle.contains("capture.shortcutHeroHint")
            && !idle.contains("private var shortcutHeroHint"),
        true,
        "The idle home hero must not repeat the shortcut that already lives in Settings"
    )
    expect(
        menuBar.contains("func updateShortcut(_ shortcut: ListeningShortcut?)")
            && application.contains("menuBarController?.updateShortcut(shortcut)"),
        true,
        "Changing the global shortcut must immediately refresh the compact menu bar action"
    )
}

testClassifierRequiresAnActiveCallControl()
testClassifierIdentifiesSupportedMeetings()
testPromptAppearsOnlyOncePerMeeting()
testCaptureSuppressesTheCurrentMeeting()
testRepeatedDismissalsPauseFuturePromptsUntilExplicitlyResumed()
testMeetingPromptPreferencePersistsAcrossRelaunch()
testTerminatedApplicationReleasesOldSessionFingerprints()
testPlatformUsesEventsAndReleasesTheMainSurfaceInMenuBarMode()

if failures.isEmpty {
    print("Arco meeting awareness contract tests passed (\(assertionCount) assertions)")
} else {
    failures.forEach { fputs("FAIL: \($0)\n", stderr) }
    exit(1)
}
