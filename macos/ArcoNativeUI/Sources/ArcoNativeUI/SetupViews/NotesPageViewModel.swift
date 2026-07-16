import Foundation
import SwiftUI

public enum NotesPendingConfirmation: Equatable, Sendable {
    case replace(NoteDraft)
    case openMeeting(String)
    case delete(NoteDocument)
}

@MainActor
public final class NotesPageViewModel: ObservableObject {
    @Published public private(set) var notes: [NoteDocument]
    @Published public private(set) var meetings: [MeetingSummary]
    @Published public private(set) var loading: Bool
    @Published public var query: String {
        didSet {
            guard query != oldValue, !applyingExternalQuery else { return }
            onQueryChange(query)
        }
    }
    @Published public private(set) var draft: NoteDraft?
    @Published public private(set) var dirty = false
    @Published public private(set) var saving = false
    @Published public private(set) var savedReceipt = false
    @Published public var editorMode: NotesEditorMode = .write
    @Published public var formatOpen = false
    @Published public var indexOpen = true
    @Published public private(set) var pendingConfirmation: NotesPendingConfirmation?
    @Published public private(set) var bodySelection = NSRange(location: 0, length: 0)
    @Published public private(set) var bodyFocusRequest = 0

    private let onQueryChange: (String) -> Void
    private let onOpenMeeting: (String) -> Void
    private let onSaveNote: (NoteDraft) async -> NoteDocument?
    private let onDeleteNote: (String) async -> Bool
    private var saveInFlight = false
    private var autosaveTask: Task<Void, Never>?
    private var applyingExternalQuery = false

    public init(
        notes: [NoteDocument],
        meetings: [MeetingSummary],
        query: String = "",
        loading: Bool = false,
        onQueryChange: @escaping (String) -> Void,
        onOpenMeeting: @escaping (String) -> Void,
        onSaveNote: @escaping (NoteDraft) async -> NoteDocument?,
        onDeleteNote: @escaping (String) async -> Bool
    ) {
        self.notes = notes
        self.meetings = meetings
        self.query = query
        self.loading = loading
        self.onQueryChange = onQueryChange
        self.onOpenMeeting = onOpenMeeting
        self.onSaveNote = onSaveNote
        self.onDeleteNote = onDeleteNote
    }

    deinit { autosaveTask?.cancel() }

    public func teardown() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    public var visibleDraft: NoteDraft? {
        draft ?? notes.first.map(NoteDraft.init(note:))
    }

    public var canCreateNote: Bool { !meetings.isEmpty }

    public func update(
        notes: [NoteDocument],
        meetings: [MeetingSummary],
        query: String,
        loading: Bool
    ) {
        self.notes = notes
        self.meetings = meetings
        self.loading = loading
        if self.query != query {
            // React received `query` as a controlled prop. A parent refresh did
            // not call `onQueryChange` back into the parent, so preserve that
            // one-way update instead of creating a native feedback loop.
            applyingExternalQuery = true
            self.query = query
            applyingExternalQuery = false
        }
    }

    public func setBodySelection(_ range: NSRange) {
        let length = visibleDraft?.body.utf16.count ?? 0
        let location = min(max(0, range.location), length)
        bodySelection = NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    public func updateTitle(_ title: String) {
        mutateDraft { $0.title = title.utf16Prefix(120) }
    }

    public func updateBody(_ body: String) {
        mutateDraft { $0.body = body }
        let length = body.utf16.count
        if bodySelection.location > length {
            bodySelection = NSRange(location: length, length: 0)
        }
    }

    public func updateMeeting(_ meetingID: String?) {
        mutateDraft {
            $0.meetingId = meetingID
            $0.meetingTitle = meetings.first(where: { $0.id == meetingID })?.title
        }
    }

    public func createNew() {
        guard let meetingID = meetings.first?.id else { return }
        requestReplacement(.empty(meetingId: meetingID))
    }

    public func select(_ note: NoteDocument) {
        requestReplacement(NoteDraft(note: note))
    }

    public func requestOpenCurrentMeeting() {
        guard let meetingID = visibleDraft?.meetingId else { return }
        if dirty {
            pendingConfirmation = .openMeeting(meetingID)
        } else {
            onOpenMeeting(meetingID)
        }
    }

    public func requestDelete(_ note: NoteDocument) {
        pendingConfirmation = .delete(note)
    }

    public func cancelConfirmation() {
        pendingConfirmation = nil
    }

    public func confirmPendingAction() async {
        guard let pendingConfirmation else { return }
        self.pendingConfirmation = nil
        switch pendingConfirmation {
        case let .replace(next):
            commitReplacement(next)
        case let .openMeeting(meetingID):
            onOpenMeeting(meetingID)
        case let .delete(note):
            guard await onDeleteNote(note.id) else { return }
            if visibleDraft?.id == note.id {
                let next = notes.first(where: { $0.id != note.id }).map(NoteDraft.init(note:))
                autosaveTask?.cancel()
                draft = next
                dirty = false
                savedReceipt = false
                bodySelection = NSRange(location: next?.body.utf16.count ?? 0, length: 0)
            }
        }
    }

    public func saveNow() async {
        guard let visibleDraft else { return }
        autosaveTask?.cancel()
        await persist(visibleDraft)
    }

    public func apply(_ action: NotesFormattingAction, textPlaceholder: String, codePlaceholder: String) {
        guard editorMode == .write else { return }
        switch action {
        case .title: applyLinePrefix("# ")
        case .heading: applyLinePrefix("## ")
        case .subheading: applyLinePrefix("### ")
        case .body: applyLinePrefix("")
        case .monostyled, .code: applyInline(before: "`", after: "`", placeholder: codePlaceholder)
        case .bold: applyInline(before: "**", after: "**", placeholder: textPlaceholder)
        case .italic: applyInline(before: "_", after: "_", placeholder: textPlaceholder)
        case .strikethrough: applyInline(before: "~~", after: "~~", placeholder: textPlaceholder)
        case .bullet: applyLinePrefix("* ")
        case .dash: applyLinePrefix("- ")
        case .numbered: applyLinePrefix("1. ")
        case .checklist: applyLinePrefix("- [ ] ")
        case .quote: applyLinePrefix("> ")
        case .table: insertAtSelection("| Column 1 | Column 2 |\n| --- | --- |\n|  |  |")
        }
        bodyFocusRequest &+= 1
    }

    public static func plainTextPreview(_ body: String, fallback: String) -> String {
        guard let first = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        else { return fallback }
        var value = first
        value = value.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"^(?:[-+*>]|\d+\.)\s+"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\[([^\]]+)]\([^)]+\)"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[*_`~#]"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }

    private func requestReplacement(_ next: NoteDraft) {
        if dirty {
            pendingConfirmation = .replace(next)
        } else {
            commitReplacement(next)
        }
    }

    private func commitReplacement(_ next: NoteDraft) {
        autosaveTask?.cancel()
        draft = next
        dirty = false
        savedReceipt = false
        editorMode = .write
        formatOpen = false
        bodySelection = NSRange(location: next.body.utf16.count, length: 0)
    }

    private func mutableDraft() -> NoteDraft {
        visibleDraft ?? .empty(meetingId: meetings.first?.id)
    }

    private func mutateDraft(_ mutation: (inout NoteDraft) -> Void) {
        var next = mutableDraft()
        mutation(&next)
        draft = next
        dirty = true
        savedReceipt = false
        scheduleAutosave(for: next)
    }

    private func scheduleAutosave(for snapshot: NoteDraft) {
        autosaveTask?.cancel()
        guard !snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              snapshot.meetingId != nil,
              !saveInFlight
        else { return }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            await self?.persist(snapshot)
        }
    }

    private func persist(_ snapshot: NoteDraft) async {
        guard !snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              snapshot.meetingId != nil,
              !saveInFlight
        else { return }
        saveInFlight = true
        saving = true
        var payload = snapshot
        payload.title = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = await onSaveNote(payload)
        saveInFlight = false
        saving = false
        guard let saved else { return }

        if let latest = visibleDraft, latest.hasSamePersistedContent(as: snapshot) {
            let savedDraft = NoteDraft(note: saved)
            draft = savedDraft
            dirty = false
            savedReceipt = true
            return
        }
        if var latest = visibleDraft, snapshot.id == nil, latest.id == nil {
            latest.id = saved.id
            latest.updatedAt = saved.updatedAt
            draft = latest
        }
    }

    private func normalizedSelection(in text: NSString) -> NSRange {
        let location = min(max(0, bodySelection.location), text.length)
        return NSRange(location: location, length: min(max(0, bodySelection.length), text.length - location))
    }

    private func applyInline(before: String, after: String, placeholder: String) {
        let current = mutableDraft().body as NSString
        let range = normalizedSelection(in: current)
        let selected = range.length > 0 ? current.substring(with: range) : placeholder
        let replacement = before + selected + after
        let next = current.replacingCharacters(in: range, with: replacement)
        bodySelection = NSRange(location: range.location + before.utf16.count, length: selected.utf16.count)
        updateBody(next)
    }

    private func insertAtSelection(_ content: String) {
        let current = mutableDraft().body as NSString
        let range = normalizedSelection(in: current)
        let next = current.replacingCharacters(in: range, with: content)
        bodySelection = NSRange(location: range.location + content.utf16.count, length: 0)
        updateBody(next)
    }

    private func applyLinePrefix(_ prefix: String) {
        let current = mutableDraft().body as NSString
        let selection = normalizedSelection(in: current)
        let start = current.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let endLocation = min(current.length, NSMaxRange(selection))
        let endLine = current.lineRange(for: NSRange(location: endLocation, length: 0))
        var lineEnd = min(current.length, NSMaxRange(endLine))
        if lineEnd > start, current.substring(with: NSRange(location: lineEnd - 1, length: 1)) == "\n" {
            lineEnd -= 1
        }
        let range = NSRange(location: start, length: max(0, lineEnd - start))
        let blockPattern = #"^(?:#{1,6}\s+|>\s+|(?:[-+*]\s+(?:\[[ xX]\]\s+)?)|\d+\.\s+)"#
        let replacement = current.substring(with: range)
            .components(separatedBy: "\n")
            .map { prefix + $0.replacingOccurrences(of: blockPattern, with: "", options: .regularExpression) }
            .joined(separator: "\n")
        let next = current.replacingCharacters(in: range, with: replacement)
        bodySelection = NSRange(
            location: start + prefix.utf16.count,
            length: max(0, replacement.utf16.count - prefix.utf16.count)
        )
        updateBody(next)
    }
}
