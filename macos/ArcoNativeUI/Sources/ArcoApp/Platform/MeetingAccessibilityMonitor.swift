import AppKit
import ApplicationServices
import ArcoNativeUI

private func arcoMeetingAccessibilityCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let context = Unmanaged<MeetingAXObserverContext>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    let processIdentifier = context.processIdentifier
    DispatchQueue.main.async {
        context.owner?.scheduleScan(processIdentifier: processIdentifier)
    }
}

private final class MeetingAXObserverContext: @unchecked Sendable {
    weak var owner: MeetingAccessibilityMonitor?
    let processIdentifier: Int32

    init(owner: MeetingAccessibilityMonitor, processIdentifier: Int32) {
        self.owner = owner
        self.processIdentifier = processIdentifier
    }
}

private final class ObservedMeetingApplication {
    let application: NSRunningApplication
    let applicationElement: AXUIElement
    let observer: AXObserver
    let context: MeetingAXObserverContext

    init(
        application: NSRunningApplication,
        applicationElement: AXUIElement,
        observer: AXObserver,
        context: MeetingAXObserverContext
    ) {
        self.application = application
        self.applicationElement = applicationElement
        self.observer = observer
        self.context = context
    }
}

/// Event-driven meeting inspection. There is intentionally no repeating
/// timer: AppKit process events attach AX observers, and AX window events
/// schedule one bounded, debounced inspection of the affected process.
@MainActor
final class MeetingAccessibilityMonitor: NSObject {
    static let maximumInspectedElements = 240

    var onSnapshotsChanged: @MainActor (Int32, [DetectedMeeting]) -> Void = { _, _ in }
    var onApplicationTerminated: @MainActor (Int32) -> Void = { _ in }
    var onAuthorizationChanged: @MainActor (Bool) -> Void = { _ in }

    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    private var observedApplications: [Int32: ObservedMeetingApplication] = [:]
    private var scanWorkItems: [Int32: DispatchWorkItem] = [:]
    private var started = false
    private var suspended = false
    private(set) var authorized = false

    func start(requestAuthorization: Bool) {
        guard !started else { return }
        started = true
        workspaceCenter.addObserver(
            self,
            selector: #selector(applicationLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(arcoBecameActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        refreshAuthorization(prompt: requestAuthorization)
    }

    func stop() {
        guard started else { return }
        started = false
        workspaceCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        scanWorkItems.values.forEach { $0.cancel() }
        scanWorkItems.removeAll(keepingCapacity: false)
        detachAllApplications()
    }

    func requestAuthorization() {
        refreshAuthorization(prompt: true)
    }

    func setSuspended(_ suspended: Bool) {
        guard self.suspended != suspended else { return }
        self.suspended = suspended
        if suspended {
            scanWorkItems.values.forEach { $0.cancel() }
            scanWorkItems.removeAll(keepingCapacity: false)
            detachAllApplications()
        } else if authorized {
            attachRunningApplications()
        }
    }

    func scheduleScan(processIdentifier: Int32) {
        guard authorized, !suspended, observedApplications[processIdentifier] != nil else {
            return
        }
        scanWorkItems[processIdentifier]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scanWorkItems[processIdentifier] = nil
            self.scanApplication(processIdentifier: processIdentifier)
        }
        scanWorkItems[processIdentifier] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
    }

    private func refreshAuthorization(prompt: Bool) {
        let trusted: Bool
        if prompt {
            let options = [
                "AXTrustedCheckOptionPrompt": true,
            ] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
        } else {
            trusted = AXIsProcessTrusted()
        }
        guard authorized != trusted else {
            if trusted, !suspended, observedApplications.isEmpty {
                attachRunningApplications()
            }
            return
        }
        authorized = trusted
        onAuthorizationChanged(trusted)
        if trusted, !suspended {
            attachRunningApplications()
        } else {
            detachAllApplications()
        }
    }

    private func attachRunningApplications() {
        guard authorized, !suspended else { return }
        for application in NSWorkspace.shared.runningApplications {
            attach(application)
        }
    }

    private func attach(_ application: NSRunningApplication) {
        let processIdentifier = application.processIdentifier
        guard observedApplications[processIdentifier] == nil,
              MeetingSurfaceClassifier.isCandidateApplication(
                  bundleIdentifier: application.bundleIdentifier ?? "",
                  applicationName: application.localizedName ?? ""
              ) else { return }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var observerReference: AXObserver?
        guard AXObserverCreate(
            processIdentifier,
            arcoMeetingAccessibilityCallback,
            &observerReference
        ) == .success,
        let observer = observerReference else { return }

        let context = MeetingAXObserverContext(
            owner: self,
            processIdentifier: processIdentifier
        )
        let refcon = Unmanaged.passUnretained(context).toOpaque()
        for name in [
            kAXWindowCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXFocusedUIElementChangedNotification,
            kAXTitleChangedNotification,
        ] {
            let result = AXObserverAddNotification(
                observer,
                applicationElement,
                name as CFString,
                refcon
            )
            if result != .success && result != .notificationUnsupported {
                continue
            }
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        observedApplications[processIdentifier] = ObservedMeetingApplication(
            application: application,
            applicationElement: applicationElement,
            observer: observer,
            context: context
        )
        scheduleScan(processIdentifier: processIdentifier)
    }

    private func detach(processIdentifier: Int32) {
        scanWorkItems[processIdentifier]?.cancel()
        scanWorkItems[processIdentifier] = nil
        guard let observed = observedApplications.removeValue(
            forKey: processIdentifier
        ) else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observed.observer),
            .commonModes
        )
    }

    private func detachAllApplications() {
        for processIdentifier in Array(observedApplications.keys) {
            detach(processIdentifier: processIdentifier)
        }
    }

    private func scanApplication(processIdentifier: Int32) {
        guard let observed = observedApplications[processIdentifier] else { return }
        let windows: [AXUIElement] = copyAttribute(
            observed.applicationElement,
            kAXWindowsAttribute
        ) ?? []
        let refcon = Unmanaged.passUnretained(observed.context).toOpaque()
        var detected: [DetectedMeeting] = []

        for window in windows {
            for name in [kAXTitleChangedNotification, kAXUIElementDestroyedNotification] {
                _ = AXObserverAddNotification(
                    observed.observer,
                    window,
                    name as CFString,
                    refcon
                )
            }

            let title: String = copyAttribute(window, kAXTitleAttribute) ?? ""
            let document = stringAttribute(window, kAXDocumentAttribute)
            let directURL = stringAttribute(window, kAXURLAttribute)
            let candidate = MeetingSurfaceClassifier.isCandidateWindow(
                bundleIdentifier: observed.application.bundleIdentifier ?? "",
                applicationName: observed.application.localizedName ?? "",
                title: title
            ) || [document, directURL].compactMap { $0 }.contains {
                $0.lowercased().contains("meet.google.com")
            }
            guard candidate else { continue }

            let inspection = inspect(window: window)
            let identifier = stringAttribute(window, kAXIdentifierAttribute)
                ?? String(CFHash(window))
            let snapshot = MeetingAccessibilitySnapshot(
                bundleIdentifier: observed.application.bundleIdentifier ?? "",
                applicationName: observed.application.localizedName ?? "",
                processIdentifier: processIdentifier,
                windowIdentifier: identifier,
                windowTitle: title,
                url: inspection.url ?? directURL ?? document,
                accessibilityLabels: inspection.labels
            )
            if let meeting = MeetingSurfaceClassifier.detect(snapshot) {
                detected.append(meeting)
            }
        }
        onSnapshotsChanged(processIdentifier, detected)
    }

    private func inspect(window: AXUIElement) -> (url: String?, labels: [String]) {
        struct QueueItem {
            let element: AXUIElement
            let depth: Int
        }
        var queue = [QueueItem(element: window, depth: 0)]
        var cursor = 0
        var inspected = 0
        var url: String?
        var labels: [String] = []

        while cursor < queue.count, inspected < Self.maximumInspectedElements {
            let item = queue[cursor]
            cursor += 1
            inspected += 1

            let hidden: Bool = copyAttribute(item.element, kAXHiddenAttribute) ?? false
            guard !hidden else { continue }
            if url == nil {
                url = stringAttribute(item.element, kAXURLAttribute)
                    ?? stringAttribute(item.element, kAXDocumentAttribute)
            }

            let role: String = copyAttribute(item.element, kAXRoleAttribute) ?? ""
            if [
                kAXButtonRole as String,
                kAXMenuItemRole as String,
                kAXCheckBoxRole as String,
                kAXRadioButtonRole as String,
            ].contains(role) {
                for attribute in [
                    kAXTitleAttribute,
                    kAXDescriptionAttribute,
                    kAXHelpAttribute,
                    kAXValueAttribute,
                ] {
                    if let label = stringAttribute(item.element, attribute),
                       !label.isEmpty {
                        labels.append(label)
                    }
                }
            }

            guard item.depth < 9 else { continue }
            let children: [AXUIElement] = copyAttribute(
                item.element,
                kAXChildrenAttribute
            ) ?? []
            let remaining = Self.maximumInspectedElements - queue.count
            if remaining > 0 {
                queue.append(contentsOf: children.prefix(remaining).map {
                    QueueItem(element: $0, depth: item.depth + 1)
                })
            }
        }
        return (url, labels)
    }

    private func stringAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let value else { return nil }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    private func copyAttribute<Value>(
        _ element: AXUIElement,
        _ attribute: String
    ) -> Value? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? Value
    }

    @objc private func applicationLaunched(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        if !authorized { refreshAuthorization(prompt: false) }
        attach(application)
    }

    @objc private func applicationActivated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        if !authorized { refreshAuthorization(prompt: false) }
        attach(application)
        scheduleScan(processIdentifier: application.processIdentifier)
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        let processIdentifier = application.processIdentifier
        detach(processIdentifier: processIdentifier)
        onApplicationTerminated(processIdentifier)
    }

    @objc private func arcoBecameActive(_ notification: Notification) {
        refreshAuthorization(prompt: false)
    }
}

@MainActor
final class MeetingAwarenessController {
    var onStateChanged: @MainActor (Bool, Bool) -> Void = { _, _ in }

    private let preferences: ArcoPreferences
    private let windowCoordinator: WindowCoordinator
    private let monitor = MeetingAccessibilityMonitor()
    private var tracker = MeetingPromptTracker()
    private var preference: MeetingPromptPreferenceState
    private var capturePhase: CapturePhase = .idle
    private var meetingsByProcess: [Int32: [DetectedMeeting]] = [:]

    init(preferences: ArcoPreferences, windowCoordinator: WindowCoordinator) {
        self.preferences = preferences
        self.windowCoordinator = windowCoordinator
        preference = preferences.loadMeetingPromptPreference()
    }

    func start() {
        monitor.onSnapshotsChanged = { [weak self] processIdentifier, meetings in
            guard let self else { return }
            self.meetingsByProcess[processIdentifier] = meetings
            self.applyPromptState()
        }
        monitor.onApplicationTerminated = { [weak self] processIdentifier in
            guard let self else { return }
            self.meetingsByProcess[processIdentifier] = nil
            if self.tracker.applicationTerminated(processIdentifier: processIdentifier) {
                self.windowCoordinator.hideMeetingPrompt()
            }
            self.applyPromptState()
        }
        monitor.onAuthorizationChanged = { [weak self] authorized in
            guard let self else { return }
            self.onStateChanged(authorized, self.preference.automaticPromptsEnabled)
        }
        monitor.start(requestAuthorization: true)
        synchronizeMonitoring()
        onStateChanged(monitor.authorized, preference.automaticPromptsEnabled)
    }

    func stop() {
        monitor.stop()
        meetingsByProcess.removeAll(keepingCapacity: false)
        windowCoordinator.hideMeetingPrompt()
    }

    func updateCapturePhase(_ phase: CapturePhase) {
        guard capturePhase != phase else { return }
        capturePhase = phase
        applyPromptState()
        synchronizeMonitoring()
    }

    func dismissCurrentPrompt() {
        guard tracker.dismiss() else { return }
        _ = preference.registerDismissal()
        preferences.saveMeetingPromptPreference(preference)
        windowCoordinator.hideMeetingPrompt()
        synchronizeMonitoring()
        onStateChanged(monitor.authorized, preference.automaticPromptsEnabled)
    }

    func registerPromptRecordingStarted() {
        _ = tracker.dismiss()
        preference.registerRecordingStarted()
        preferences.saveMeetingPromptPreference(preference)
        windowCoordinator.hideMeetingPrompt()
        onStateChanged(monitor.authorized, preference.automaticPromptsEnabled)
    }

    func requestAuthorization() {
        monitor.requestAuthorization()
        onStateChanged(monitor.authorized, preference.automaticPromptsEnabled)
    }

    func resumeAutomaticPrompts() {
        preference.resumeAutomaticPrompts()
        preferences.saveMeetingPromptPreference(preference)
        synchronizeMonitoring()
        applyPromptState()
        onStateChanged(monitor.authorized, preference.automaticPromptsEnabled)
    }

    private func synchronizeMonitoring() {
        let captureActive = capturePhase != .idle && capturePhase != .error
        monitor.setSuspended(captureActive || !preference.automaticPromptsEnabled)
    }

    private func applyPromptState() {
        let meetings = meetingsByProcess.values
            .flatMap { $0 }
            .sorted { $0.id < $1.id }
        switch tracker.observe(
            meetings,
            capturePhase: capturePhase,
            automaticPromptsEnabled: preference.automaticPromptsEnabled
        ) {
        case .none:
            break
        case let .show(meeting):
            do { try windowCoordinator.showMeetingPrompt(meeting) }
            catch { windowCoordinator.onSurfaceError(error) }
        case .hide:
            windowCoordinator.hideMeetingPrompt()
        }
    }
}
