import CoreFoundation
import Foundation
import SQLite3

public protocol KeyValueStore: AnyObject {
    func contains(_ key: String) -> Bool
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
    func removeObject(forKey key: String)
}

public final class UserDefaultsKeyValueStore: KeyValueStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func contains(_ key: String) -> Bool {
        defaults.object(forKey: key) != nil
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

public enum ArcoPreferenceKey {
    public static let providerConfiguration = "arco.providerConfig"
    public static let transcriptionConfiguration = "arco.transcriptionConfig"
    public static let listeningShortcut = "arco.listeningShortcut.v1"
    public static let generationSettings = "arco.generationSettings"
    public static let onboardingState = "arco.onboarding.v1"
    public static let onboardingDraft = "arco.onboarding.draft.v1"
    public static let audioMode = "arco.audioMode"
    public static let agentWorkspace = "arco.agentWorkspace"
    public static let agentTranscriptVisible = "arco.agentTranscriptVisible"
    public static let locale = "arco.locale"
    public static let nativeMigrationMarker = "arco.nativePreferencesMigration.v1"

    public static let legacyImportKeys: Set<String> = [
        providerConfiguration,
        transcriptionConfiguration,
        listeningShortcut,
        generationSettings,
        onboardingState,
        onboardingDraft,
        audioMode,
        agentWorkspace,
        agentTranscriptVisible,
        locale,
    ]
}

public enum PreferenceValidationError: Error, Equatable, LocalizedError {
    case invalidProviderConfiguration
    case invalidTranscriptionConfiguration
    case invalidListeningShortcut
    case invalidGenerationSettings
    case invalidOnboardingDraft

    public var errorDescription: String? {
        switch self {
        case .invalidProviderConfiguration: "Invalid provider configuration."
        case .invalidTranscriptionConfiguration: "Invalid transcription configuration"
        case .invalidListeningShortcut: "Invalid listening shortcut"
        case .invalidGenerationSettings: "Invalid generation settings."
        case .invalidOnboardingDraft: "Invalid onboarding draft"
        }
    }
}

public struct OnboardingState: Codable, Equatable, Sendable {
    public var completed: Bool
    public var skipped: Bool

    public init(completed: Bool = false, skipped: Bool = false) {
        self.completed = completed
        self.skipped = skipped
    }
}

public enum AppLocale: String, Codable, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-CN"
}

public let maximumGenerationPromptCharacters = 8_000

public let defaultTitlePrompt = """
Create a concise, specific title for this meeting.
Use the main topic, decision, or outcome.
Write in the transcript's primary language and keep it under 8 words or 16 CJK characters.
Do not include dates, speaker labels, or words such as "meeting".
Return only the title.
"""

public let defaultSummaryPrompt = """
Create a concise end-of-meeting note in the transcript's primary language.
Start with the outcome, then capture key decisions, unresolved questions, and action items.
Do not invent owners, commitments, or deadlines.
Leave out sections that were not discussed.
Ground every point in the transcript.
"""

public final class ArcoPreferences {
    public static let defaultListeningShortcut = ListeningShortcut.default
    public static let legacyFunctionListeningShortcut = "Fn+KeyM"
    private static let disabledListeningShortcut = "__disabled__"

    private let store: KeyValueStore

    public init(store: KeyValueStore = UserDefaultsKeyValueStore()) {
        self.store = store
    }

    public func loadProviderConfiguration() -> ProviderConfiguration {
        guard
            let object = jsonObject(store.string(forKey: ArcoPreferenceKey.providerConfiguration)),
            let parsed = Self.parseProviderConfiguration(object)
        else {
            return ProviderConfiguration()
        }
        return parsed
    }

    public func saveProviderConfiguration(_ configuration: ProviderConfiguration) throws {
        guard configuration.isValid else {
            throw PreferenceValidationError.invalidProviderConfiguration
        }
        let object: [String: Any] = [
            "setupComplete": configuration.setupComplete,
            "primary": configuration.primary?.rawValue ?? NSNull(),
            "secondary": configuration.secondary?.rawValue ?? NSNull(),
        ]
        store.set(try jsonString(object), forKey: ArcoPreferenceKey.providerConfiguration)
    }

    public func loadTranscriptionConfiguration() -> TranscriptionConfiguration {
        guard
            let raw = jsonValue(store.string(forKey: ArcoPreferenceKey.transcriptionConfiguration)),
            let normalized = Self.normalizeTranscriptionConfiguration(raw)
        else {
            return .default
        }
        return normalized
    }

    public func saveTranscriptionConfiguration(_ configuration: TranscriptionConfiguration) throws {
        guard configuration.isValid else {
            throw PreferenceValidationError.invalidTranscriptionConfiguration
        }
        store.set(
            try jsonString(Self.transcriptionObject(configuration)),
            forKey: ArcoPreferenceKey.transcriptionConfiguration
        )
    }

    public func loadListeningShortcut() -> ListeningShortcut? {
        guard let stored = store.string(forKey: ArcoPreferenceKey.listeningShortcut) else {
            return Self.defaultListeningShortcut
        }
        if stored == Self.disabledListeningShortcut {
            return nil
        }
        if stored == Self.legacyFunctionListeningShortcut {
            store.set(Self.defaultListeningShortcut.rawValue, forKey: ArcoPreferenceKey.listeningShortcut)
            return Self.defaultListeningShortcut
        }
        return ListeningShortcut(rawValue: stored) ?? Self.defaultListeningShortcut
    }

    public func saveListeningShortcut(_ shortcut: ListeningShortcut?) throws {
        guard let shortcut else {
            store.set(Self.disabledListeningShortcut, forKey: ArcoPreferenceKey.listeningShortcut)
            return
        }
        guard ListeningShortcut(rawValue: shortcut.rawValue) != nil else {
            throw PreferenceValidationError.invalidListeningShortcut
        }
        store.set(shortcut.rawValue, forKey: ArcoPreferenceKey.listeningShortcut)
    }

    public func loadGenerationSettings() -> GenerationSettings {
        guard
            let object = jsonObject(store.string(forKey: ArcoPreferenceKey.generationSettings)),
            let parsed = Self.parseGenerationSettings(object)
        else {
            return .default
        }
        return parsed
    }

    public func saveGenerationSettings(_ settings: GenerationSettings) throws {
        guard Self.isValidGenerationRule(settings.title), Self.isValidGenerationRule(settings.summary) else {
            throw PreferenceValidationError.invalidGenerationSettings
        }
        let object: [String: Any] = [
            "title": Self.generationRuleObject(settings.title),
            "summary": Self.generationRuleObject(settings.summary),
        ]
        store.set(try jsonString(object), forKey: ArcoPreferenceKey.generationSettings)
    }

    public func loadOnboardingState() -> OnboardingState {
        guard
            let object = jsonObject(store.string(forKey: ArcoPreferenceKey.onboardingState)),
            let completed = jsonBoolean(object["completed"]),
            let skipped = jsonBoolean(object["skipped"])
        else {
            return OnboardingState()
        }
        return OnboardingState(completed: completed, skipped: skipped)
    }

    @discardableResult
    public func completeOnboarding(skipped: Bool = false) -> OnboardingState {
        let state = OnboardingState(completed: true, skipped: skipped)
        let object: [String: Any] = ["completed": state.completed, "skipped": state.skipped]
        if let encoded = try? jsonString(object) {
            store.set(encoded, forKey: ArcoPreferenceKey.onboardingState)
        }
        clearOnboardingDraft()
        return state
    }

    public func loadOnboardingDraft() -> OnboardingDraftState? {
        guard var object = jsonObject(store.string(forKey: ArcoPreferenceKey.onboardingDraft)) else {
            clearOnboardingDraftIfPresent()
            return nil
        }

        if object["listeningShortcut"] as? String == Self.legacyFunctionListeningShortcut {
            object["listeningShortcut"] = Self.defaultListeningShortcut.rawValue
        }
        if let normalized = Self.normalizeTranscriptionConfiguration(object["transcriptionConfig"] as Any) {
            object["transcriptionConfig"] = Self.transcriptionObject(normalized)
        }

        if let rewritten = try? jsonString(object) {
            store.set(rewritten, forKey: ArcoPreferenceKey.onboardingDraft)
        }

        guard let draft = Self.parseOnboardingDraft(object) else {
            clearOnboardingDraft()
            return nil
        }
        return draft
    }

    public func saveOnboardingDraft(_ draft: OnboardingDraftState) throws {
        guard Self.isValidOnboardingDraft(draft) else {
            throw PreferenceValidationError.invalidOnboardingDraft
        }
        store.set(
            try jsonString(Self.onboardingDraftObject(draft)),
            forKey: ArcoPreferenceKey.onboardingDraft
        )
    }

    public func clearOnboardingDraft() {
        store.removeObject(forKey: ArcoPreferenceKey.onboardingDraft)
    }

    public func loadAudioMode() -> AudioMode {
        guard
            let raw = store.string(forKey: ArcoPreferenceKey.audioMode),
            let mode = AudioMode(rawValue: raw)
        else {
            return .both
        }
        return mode
    }

    public func saveAudioMode(_ mode: AudioMode) {
        store.set(mode.rawValue, forKey: ArcoPreferenceKey.audioMode)
    }

    public func loadAgentWorkspace() -> String? {
        guard let workspace = store.string(forKey: ArcoPreferenceKey.agentWorkspace)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            workspace.hasPrefix("/")
        else {
            return nil
        }
        return workspace
    }

    public func saveAgentWorkspace(_ workspace: String) {
        store.set(
            workspace.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: ArcoPreferenceKey.agentWorkspace
        )
    }

    public func loadLocale(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLocale {
        if let saved = store.string(forKey: ArcoPreferenceKey.locale), let locale = AppLocale(rawValue: saved) {
            return locale
        }
        return preferredLanguages.contains(where: { $0.lowercased().hasPrefix("zh") })
            ? .simplifiedChinese
            : .english
    }

    public func saveLocale(_ locale: AppLocale) {
        store.set(locale.rawValue, forKey: ArcoPreferenceKey.locale)
    }

    private func clearOnboardingDraftIfPresent() {
        if store.contains(ArcoPreferenceKey.onboardingDraft) {
            clearOnboardingDraft()
        }
    }

    private static func parseProviderConfiguration(_ object: [String: Any]) -> ProviderConfiguration? {
        guard let setupComplete = jsonBoolean(object["setupComplete"]) else { return nil }
        if !setupComplete, object["primary"] is NSNull, object["secondary"] is NSNull {
            return ProviderConfiguration()
        }
        guard
            setupComplete,
            let primaryRaw = object["primary"] as? String,
            let primary = ProviderID(rawValue: primaryRaw),
            object.keys.contains("secondary")
        else {
            return nil
        }
        let secondary: ProviderID?
        if object["secondary"] is NSNull {
            secondary = nil
        } else if let raw = object["secondary"] as? String, let provider = ProviderID(rawValue: raw) {
            secondary = provider
        } else {
            return nil
        }
        guard primary != secondary else { return nil }
        return ProviderConfiguration(setupComplete: true, primary: primary, secondary: secondary)
    }

    private static func normalizeTranscriptionConfiguration(_ value: Any) -> TranscriptionConfiguration? {
        if let object = value as? [String: Any], let current = parseCurrentTranscriptionConfiguration(object) {
            return current
        }
        guard
            let legacy = value as? [String: Any],
            let providerRaw = legacy["provider"] as? String,
            let provider = TranscriptionProvider(rawValue: providerRaw),
            let model = legacy["model"] as? String,
            let language = legacy["language"] as? String,
            ["auto", "zh-CN", "en-US"].contains(language),
            let originalDiarization = legacy["diarization"] as? String
        else {
            return nil
        }

        let rawDiarization = originalDiarization == "local-streaming"
            ? "sortformer-streaming"
            : originalDiarization
        let diarization: DiarizationConfiguration
        if rawDiarization == "provider", provider == .deepgram {
            diarization = DiarizationConfiguration(provider: .deepgram, model: "latest")
        } else if TranscriptionConfiguration.localDiarizationModels.contains(rawDiarization) {
            diarization = DiarizationConfiguration(provider: .local, model: rawDiarization)
        } else if rawDiarization == "none" {
            diarization = DiarizationConfiguration(provider: .none, model: nil)
        } else {
            return nil
        }

        let migrated = TranscriptionConfiguration(
            asr: ASRConfiguration(provider: provider, model: model, language: language),
            diarization: diarization
        )
        return migrated.isValid ? migrated : nil
    }

    private static func parseCurrentTranscriptionConfiguration(
        _ object: [String: Any]
    ) -> TranscriptionConfiguration? {
        guard
            let asr = object["asr"] as? [String: Any],
            let diarization = object["diarization"] as? [String: Any],
            let providerRaw = asr["provider"] as? String,
            let provider = TranscriptionProvider(rawValue: providerRaw),
            let model = asr["model"] as? String,
            let language = asr["language"] as? String,
            let diarizationProviderRaw = diarization["provider"] as? String,
            let diarizationProvider = DiarizationProvider(rawValue: diarizationProviderRaw),
            diarization.keys.contains("model")
        else {
            return nil
        }
        let diarizationModel: String?
        if diarization["model"] is NSNull {
            diarizationModel = nil
        } else if let raw = diarization["model"] as? String {
            diarizationModel = raw
        } else {
            return nil
        }
        let configuration = TranscriptionConfiguration(
            asr: ASRConfiguration(provider: provider, model: model, language: language),
            diarization: DiarizationConfiguration(provider: diarizationProvider, model: diarizationModel)
        )
        return configuration.isValid ? configuration : nil
    }

    private static func transcriptionObject(_ configuration: TranscriptionConfiguration) -> [String: Any] {
        let diarization: [String: Any] = [
            "provider": configuration.diarization.provider.rawValue,
            "model": configuration.diarization.model ?? NSNull(),
        ]
        return [
            "asr": [
                "provider": configuration.asr.provider.rawValue,
                "model": configuration.asr.model,
                "language": configuration.asr.language,
            ],
            "diarization": diarization,
        ]
    }

    private static func parseGenerationSettings(_ object: [String: Any]) -> GenerationSettings? {
        guard
            let titleObject = object["title"] as? [String: Any],
            let summaryObject = object["summary"] as? [String: Any],
            let title = parseGenerationRule(titleObject),
            let summary = parseGenerationRule(summaryObject)
        else {
            return nil
        }
        return GenerationSettings(title: title, summary: summary)
    }

    private static func parseGenerationRule(_ object: [String: Any]) -> GenerationRule? {
        guard
            let enabled = jsonBoolean(object["enabled"]),
            object.keys.contains("promptOverride")
        else {
            return nil
        }
        let prompt: String?
        if object["promptOverride"] is NSNull {
            prompt = nil
        } else if let raw = object["promptOverride"] as? String,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  raw.unicodeScalars.count <= maximumGenerationPromptCharacters {
            prompt = raw
        } else {
            return nil
        }
        return GenerationRule(enabled: enabled, promptOverride: prompt)
    }

    private static func isValidGenerationRule(_ rule: GenerationRule) -> Bool {
        guard let prompt = rule.promptOverride else { return true }
        return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && prompt.unicodeScalars.count <= maximumGenerationPromptCharacters
    }

    private static func generationRuleObject(_ rule: GenerationRule) -> [String: Any] {
        ["enabled": rule.enabled, "promptOverride": rule.promptOverride ?? NSNull()]
    }

    private static func parseOnboardingDraft(_ object: [String: Any]) -> OnboardingDraftState? {
        guard
            jsonInteger(object["version"]) == 1,
            let step = jsonInteger(object["step"]), (1 ... 5).contains(step),
            let furthestStep = jsonInteger(object["furthestStep"]),
            furthestStep >= step, furthestStep <= 5,
            let choiceRaw = object["agentChoice"] as? String,
            let choice = OnboardingAgentChoice(rawValue: choiceRaw),
            let primary = nullableProvider(object, key: "primary"),
            let secondary = nullableProvider(object, key: "secondary"),
            let testedProvider = nullableProvider(object, key: "testedProvider"),
            primary.value == nil || primary.value != secondary.value,
            let transcription = normalizeTranscriptionConfiguration(object["transcriptionConfig"] as Any),
            let audioRaw = object["audioMode"] as? String,
            let audioMode = AudioMode(rawValue: audioRaw),
            let shortcut = nullableShortcut(object, key: "listeningShortcut")
        else {
            return nil
        }
        return OnboardingDraftState(
            step: step,
            furthestStep: furthestStep,
            agentChoice: choice,
            primary: primary.value,
            secondary: secondary.value,
            testedProvider: testedProvider.value,
            transcriptionConfiguration: transcription,
            audioMode: audioMode,
            listeningShortcut: shortcut.value
        )
    }

    private static func isValidOnboardingDraft(_ draft: OnboardingDraftState) -> Bool {
        draft.version == 1
            && (1 ... 5).contains(draft.step)
            && draft.furthestStep >= draft.step
            && draft.furthestStep <= 5
            && (draft.primary == nil || draft.primary != draft.secondary)
            && draft.transcriptionConfiguration.isValid
            && (draft.listeningShortcut == nil
                || ListeningShortcut(rawValue: draft.listeningShortcut?.rawValue ?? "") != nil)
    }

    private static func onboardingDraftObject(_ draft: OnboardingDraftState) -> [String: Any] {
        [
            "version": draft.version,
            "step": draft.step,
            "furthestStep": draft.furthestStep,
            "agentChoice": draft.agentChoice.rawValue,
            "primary": draft.primary?.rawValue ?? NSNull(),
            "secondary": draft.secondary?.rawValue ?? NSNull(),
            "testedProvider": draft.testedProvider?.rawValue ?? NSNull(),
            "transcriptionConfig": transcriptionObject(draft.transcriptionConfiguration),
            "audioMode": draft.audioMode.rawValue,
            "listeningShortcut": draft.listeningShortcut?.rawValue ?? NSNull(),
        ]
    }
}

private struct NullableValue<Value> {
    var value: Value?
}

private func nullableProvider(
    _ object: [String: Any],
    key: String
) -> NullableValue<ProviderID>? {
    guard object.keys.contains(key) else { return nil }
    if object[key] is NSNull { return NullableValue(value: nil) }
    guard let raw = object[key] as? String, let provider = ProviderID(rawValue: raw) else { return nil }
    return NullableValue(value: provider)
}

private func nullableShortcut(
    _ object: [String: Any],
    key: String
) -> NullableValue<ListeningShortcut>? {
    guard object.keys.contains(key) else { return nil }
    if object[key] is NSNull { return NullableValue(value: nil) }
    guard let raw = object[key] as? String, let shortcut = ListeningShortcut(rawValue: raw) else { return nil }
    return NullableValue(value: shortcut)
}

private func jsonValue(_ string: String?) -> Any? {
    guard let data = string?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

private func jsonObject(_ string: String?) -> [String: Any]? {
    jsonValue(string) as? [String: Any]
}

private func jsonString(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    guard let string = String(data: data, encoding: .utf8) else {
        throw CocoaError(.fileWriteInapplicableStringEncoding)
    }
    return string
}

private func jsonBoolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
        return nil
    }
    return number.boolValue
}

private func jsonInteger(_ value: Any?) -> Int? {
    guard
        let number = value as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue.rounded() == number.doubleValue,
        number.doubleValue >= Double(Int.min),
        number.doubleValue <= Double(Int.max)
    else {
        return nil
    }
    return number.intValue
}

public enum LegacyPreferencesMigrationResult: Equatable, Sendable {
    case alreadyCompleted
    case noLegacyData
    case imported(Int)
}

public enum LegacyPreferencesMigrationError: Error, Equatable, LocalizedError {
    case cannotOpenDatabase(path: String, message: String)
    case cannotReadDatabase(path: String, message: String)
    case invalidUTF16Value(path: String, key: String)

    public var errorDescription: String? {
        switch self {
        case let .cannotOpenDatabase(path, message):
            "Could not open legacy preferences at \(path): \(message)"
        case let .cannotReadDatabase(path, message):
            "Could not read legacy preferences at \(path): \(message)"
        case let .invalidUTF16Value(path, key):
            "Legacy preference \(key) at \(path) is not valid UTF-16LE."
        }
    }
}

public final class LegacyWebKitPreferencesImporter {
    private let store: KeyValueStore
    private let rootURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        store: KeyValueStore = UserDefaultsKeyValueStore(),
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/WebKit/app.arco.desktop", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    @discardableResult
    public func migrateIfNeeded() throws -> LegacyPreferencesMigrationResult {
        lock.lock()
        defer { lock.unlock() }

        if store.string(forKey: ArcoPreferenceKey.nativeMigrationMarker) == "1" {
            return .alreadyCompleted
        }

        var legacyValues: [String: String] = [:]
        for databaseURL in legacyDatabaseURLs() {
            for (key, value) in try readLegacyDatabase(databaseURL) {
                legacyValues[key] = value
            }
        }

        var imported = 0
        for key in ArcoPreferenceKey.legacyImportKeys.sorted() {
            guard let value = legacyValues[key], !store.contains(key) else { continue }
            store.set(value, forKey: key)
            imported += 1
        }

        // This marker is deliberately the final write. A process interruption before it is
        // harmless: the next launch retries and the no-overwrite rule preserves completed keys.
        store.set("1", forKey: ArcoPreferenceKey.nativeMigrationMarker)

        if legacyValues.isEmpty {
            return .noLegacyData
        }
        return .imported(imported)
    }

    private func legacyDatabaseURLs() -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }
        var matches: [URL] = []
        for case let url as URL in enumerator {
            guard
                url.lastPathComponent == "localstorage.sqlite3",
                url.deletingLastPathComponent().lastPathComponent == "LocalStorage"
            else {
                continue
            }
            matches.append(url)
        }
        return matches.sorted { $0.path < $1.path }
    }

    private func readLegacyDatabase(_ url: URL) throws -> [String: String] {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            if let database { sqlite3_close(database) }
            throw LegacyPreferencesMigrationError.cannotOpenDatabase(path: url.path, message: message)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            "SELECT key, value FROM ItemTable",
            -1,
            &statement,
            nil
        )
        guard prepareResult == SQLITE_OK, let statement else {
            throw LegacyPreferencesMigrationError.cannotReadDatabase(
                path: url.path,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }

        var values: [String: String] = [:]
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW else {
                throw LegacyPreferencesMigrationError.cannotReadDatabase(
                    path: url.path,
                    message: String(cString: sqlite3_errmsg(database))
                )
            }
            guard
                let keyBytes = sqlite3_column_text(statement, 0),
                sqlite3_column_type(statement, 1) == SQLITE_BLOB
            else {
                continue
            }
            let key = String(cString: keyBytes)
            guard ArcoPreferenceKey.legacyImportKeys.contains(key) else { continue }

            let byteCount = Int(sqlite3_column_bytes(statement, 1))
            let data: Data
            if byteCount == 0 {
                data = Data()
            } else if let bytes = sqlite3_column_blob(statement, 1) {
                data = Data(bytes: bytes, count: byteCount)
            } else {
                throw LegacyPreferencesMigrationError.invalidUTF16Value(path: url.path, key: key)
            }
            guard byteCount.isMultiple(of: 2), let value = String(data: data, encoding: .utf16LittleEndian) else {
                throw LegacyPreferencesMigrationError.invalidUTF16Value(path: url.path, key: key)
            }
            values[key] = value
        }
        return values
    }
}
