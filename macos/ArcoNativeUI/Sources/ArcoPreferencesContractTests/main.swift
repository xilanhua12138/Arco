import ArcoNativeUI
import Foundation
import SQLite3

private final class MemoryKeyValueStore: KeyValueStore {
    private(set) var values: [String: String]

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    func contains(_ key: String) -> Bool { values.keys.contains(key) }
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

private struct ContractFailure: Error, CustomStringConvertible {
    var description: String
}

nonisolated(unsafe) private var assertions = 0

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    assertions += 1
    guard condition() else {
        throw ContractFailure(description: "\(file):\(line): \(message)")
    }
}

private func expectThrows(
    _ expected: PreferenceValidationError,
    _ body: () throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    assertions += 1
    do {
        try body()
        throw ContractFailure(description: "\(file):\(line): expected \(expected), but no error was thrown")
    } catch let error as PreferenceValidationError {
        guard error == expected else {
            throw ContractFailure(description: "\(file):\(line): expected \(expected), got \(error)")
        }
    }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("arco-preferences-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try body(url)
}

private enum SQLiteFixtureError: Error {
    case failed(String)
}

nonisolated(unsafe) private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func createLegacyDatabase(at url: URL, values: [String: String]) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw SQLiteFixtureError.failed("open")
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(
        database,
        "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB NOT NULL ON CONFLICT FAIL)",
        nil,
        nil,
        nil
    ) == SQLITE_OK else {
        throw SQLiteFixtureError.failed("create")
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "INSERT INTO ItemTable(key, value) VALUES(?, ?)", -1, &statement, nil) == SQLITE_OK,
          let statement
    else {
        throw SQLiteFixtureError.failed("prepare")
    }
    defer { sqlite3_finalize(statement) }
    for (key, value) in values.sorted(by: { $0.key < $1.key }) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        guard sqlite3_bind_text(statement, 1, key, -1, sqliteTransient) == SQLITE_OK else {
            throw SQLiteFixtureError.failed("bind key")
        }
        let data = value.data(using: .utf16LittleEndian)!
        let bindResult = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
        guard bindResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteFixtureError.failed("insert")
        }
    }
}

private func testDefaultsAndRoundTrips() throws {
    let store = MemoryKeyValueStore()
    let preferences = ArcoPreferences(store: store)

    try expect(preferences.loadProviderConfiguration() == ProviderConfiguration(), "missing provider config must use first-run state")
    try expect(preferences.loadTranscriptionConfiguration() == .default, "missing transcription config must use Deepgram default")
    try expect(preferences.loadGenerationSettings() == .default, "missing generation settings must use enabled defaults")
    try expect(preferences.loadListeningShortcut() == .default, "missing shortcut must use the native default")
    try expect(preferences.loadAudioMode() == .both, "missing audio mode must use both")
    try expect(preferences.loadOnboardingState() == OnboardingState(), "missing onboarding state must be incomplete")
    try expect(preferences.loadAgentWorkspace() == nil, "missing workspace must stay nil")
    try expect(!preferences.loadGPTLiveBetaEnabled(), "GPT-Live Beta must be disabled by default")
    try expect(preferences.loadLocale(preferredLanguages: ["zh-Hans-CN"]) == .simplifiedChinese, "Chinese system locale must map to zh-CN")

    let provider = ProviderConfiguration(setupComplete: true, primary: .codex, secondary: .claude)
    try preferences.saveProviderConfiguration(provider)
    try expect(preferences.loadProviderConfiguration() == provider, "provider configuration must round-trip")

    let transcription = TranscriptionConfiguration(
        asr: ASRConfiguration(provider: .local, model: "whisper-small", language: "auto"),
        diarization: DiarizationConfiguration(provider: .none, model: nil)
    )
    try preferences.saveTranscriptionConfiguration(transcription)
    try expect(preferences.loadTranscriptionConfiguration() == transcription, "independent ASR and diarization must round-trip")
    try expect(store.values[ArcoPreferenceKey.transcriptionConfiguration]?.contains("\"model\":null") == true, "none diarization must preserve the explicit null model")

    var generation = GenerationSettings.default
    generation.title.enabled = false
    generation.title.promptOverride = "Keep the title literal."
    generation.summary.promptOverride = "Lead with the decision.\nNever invent an owner."
    try preferences.saveGenerationSettings(generation)
    try expect(preferences.loadGenerationSettings() == generation, "generation rules must round-trip without rewriting prompts")

    try preferences.saveListeningShortcut(nil)
    try expect(preferences.loadListeningShortcut() == nil, "disabled shortcut must remain disabled")
    let customShortcut = ListeningShortcut(rawValue: "CommandOrControl+Alt+KeyL")!
    try preferences.saveListeningShortcut(customShortcut)
    try expect(preferences.loadListeningShortcut() == customShortcut, "custom shortcut must round-trip")

    preferences.saveAudioMode(.system)
    try expect(preferences.loadAudioMode() == .system, "audio mode must round-trip")
    preferences.saveAgentWorkspace("  /Users/example/Arco  ")
    try expect(preferences.loadAgentWorkspace() == "/Users/example/Arco", "workspace must be trimmed and remain absolute")
    preferences.saveGPTLiveBetaEnabled(true)
    try expect(preferences.loadGPTLiveBetaEnabled(), "GPT-Live Beta opt-in must round-trip")
    preferences.saveGPTLiveBetaEnabled(false)
    try expect(!preferences.loadGPTLiveBetaEnabled(), "GPT-Live Beta opt-out must round-trip")
    preferences.saveLocale(.english)
    try expect(preferences.loadLocale(preferredLanguages: ["zh-CN"]) == .english, "saved locale must beat the system locale")

    let draft = OnboardingDraftState(
        step: 3,
        furthestStep: 4,
        agentChoice: .transcript,
        primary: nil,
        secondary: nil,
        testedProvider: nil,
        transcriptionConfiguration: transcription,
        audioMode: .both,
        listeningShortcut: customShortcut
    )
    try preferences.saveOnboardingDraft(draft)
    try expect(preferences.loadOnboardingDraft() == draft, "onboarding draft must round-trip exact completed choices")
    let completed = preferences.completeOnboarding(skipped: true)
    try expect(completed == OnboardingState(completed: true, skipped: true), "explicit skip must complete onboarding as skipped")
    try expect(preferences.loadOnboardingDraft() == nil, "completion must clear resumable onboarding progress")
}

private func testUserDefaultsAdapter() throws {
    let suiteName = "app.arco.desktop.preferences-contract.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw ContractFailure(description: "could not create isolated UserDefaults suite")
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = ArcoPreferences(store: UserDefaultsKeyValueStore(defaults: defaults))

    preferences.saveAudioMode(.mic)
    preferences.saveAgentWorkspace("/tmp/Arco")
    preferences.saveGPTLiveBetaEnabled(true)
    preferences.saveLocale(.simplifiedChinese)
    try expect(preferences.loadAudioMode() == .mic, "UserDefaults adapter must persist scalar preferences")
    try expect(preferences.loadAgentWorkspace() == "/tmp/Arco", "UserDefaults adapter must persist workspace")
    try expect(preferences.loadGPTLiveBetaEnabled(), "UserDefaults adapter must persist the GPT-Live Beta opt-in")
    try expect(preferences.loadLocale(preferredLanguages: ["en-US"]) == .simplifiedChinese, "UserDefaults adapter must persist locale")
}

private func testMalformedAndInvalidStorage() throws {
    let store = MemoryKeyValueStore([
        ArcoPreferenceKey.providerConfiguration: "{not json",
        ArcoPreferenceKey.transcriptionConfiguration: #"{"asr":{"provider":"doubao","model":"nova-3","language":"zh-CN"},"diarization":{"provider":"none","model":null}}"#,
        ArcoPreferenceKey.generationSettings: #"{"title":{"enabled":"yes","promptOverride":null},"summary":{"enabled":true,"promptOverride":""}}"#,
        ArcoPreferenceKey.onboardingState: #"{"completed":"yes","skipped":false}"#,
        ArcoPreferenceKey.audioMode: "surround",
        ArcoPreferenceKey.agentWorkspace: "projects/Arco",
        ArcoPreferenceKey.gptLiveBetaEnabled: "yes",
        ArcoPreferenceKey.locale: "not-a-locale",
    ])
    let preferences = ArcoPreferences(store: store)

    try expect(preferences.loadProviderConfiguration() == ProviderConfiguration(), "malformed provider JSON must reset to first-run state")
    try expect(preferences.loadTranscriptionConfiguration() == .default, "provider/model mismatch must reset transcription")
    try expect(preferences.loadGenerationSettings() == .default, "invalid generation rule must reset both rules")
    try expect(preferences.loadOnboardingState() == OnboardingState(), "non-boolean onboarding fields must be rejected")
    try expect(preferences.loadAudioMode() == .both, "unknown audio mode must use both")
    try expect(preferences.loadAgentWorkspace() == nil, "relative workspace must not load")
    try expect(!preferences.loadGPTLiveBetaEnabled(), "malformed GPT-Live Beta storage must fail closed")
    try expect(preferences.loadLocale(preferredLanguages: ["en-US"]) == .english, "malformed locale must fall back to the system locale")

    var valid = GenerationSettings.default
    valid.title.promptOverride = "Use the clearest decision."
    try preferences.saveGenerationSettings(valid)
    let persisted = store.values[ArcoPreferenceKey.generationSettings]
    var invalid = valid
    invalid.title.promptOverride = String(repeating: "界", count: maximumGenerationPromptCharacters + 1)
    try expectThrows(.invalidGenerationSettings) { try preferences.saveGenerationSettings(invalid) }
    try expect(store.values[ArcoPreferenceKey.generationSettings] == persisted, "rejected generation settings must not replace the last valid value")

    store.set(#"{"version":99,"step":3}"#, forKey: ArcoPreferenceKey.onboardingDraft)
    try expect(preferences.loadOnboardingDraft() == nil, "future onboarding drafts must be dropped")
    try expect(!store.contains(ArcoPreferenceKey.onboardingDraft), "future onboarding drafts must be removed from persistence")
}

private func testLegacyNormalization() throws {
    let legacyDraft = #"{"version":1,"step":4,"furthestStep":4,"agentChoice":"transcript","primary":null,"secondary":null,"testedProvider":null,"transcriptionConfig":{"provider":"deepgram","model":"nova-3","language":"zh-CN","diarization":"provider"},"audioMode":"both","listeningShortcut":"Fn+KeyM"}"#
    let store = MemoryKeyValueStore([
        ArcoPreferenceKey.transcriptionConfiguration: #"{"provider":"local","model":"whisper-small","language":"auto","diarization":"local-streaming"}"#,
        ArcoPreferenceKey.listeningShortcut: "Fn+KeyM",
        ArcoPreferenceKey.onboardingDraft: legacyDraft,
    ])
    let preferences = ArcoPreferences(store: store)

    let normalized = preferences.loadTranscriptionConfiguration()
    try expect(normalized.asr.provider == .local && normalized.asr.model == "whisper-small", "legacy ASR choice must be preserved")
    try expect(normalized.diarization == DiarizationConfiguration(provider: .local, model: "sortformer-streaming"), "legacy local-streaming must migrate to Sortformer")
    try expect(preferences.loadListeningShortcut() == .default, "legacy Fn shortcut must migrate to the native default")
    try expect(store.values[ArcoPreferenceKey.listeningShortcut] == ListeningShortcut.default.rawValue, "legacy shortcut migration must be persisted")

    let draft = preferences.loadOnboardingDraft()
    try expect(draft?.step == 4 && draft?.furthestStep == 4, "legacy normalization must preserve onboarding progress")
    try expect(draft?.listeningShortcut == .default, "legacy onboarding shortcut must normalize")
    try expect(draft?.transcriptionConfiguration == .default, "provider-coupled Deepgram must normalize to independent ASR and diarization")
    try expect(store.values[ArcoPreferenceKey.onboardingDraft]?.contains("transcriptionConfig") == true, "rewritten draft must retain the TypeScript transcriptionConfig key")
    try expect(store.values[ArcoPreferenceKey.onboardingDraft]?.contains("transcriptionConfiguration") == false, "Swift property naming must never leak into persisted onboarding JSON")
}

private func testLegacySQLiteImportAndNoOverwrite() throws {
    try withTemporaryDirectory { root in
        let databaseURL = root
            .appendingPathComponent("WebsiteData/Default/hash/hash/LocalStorage", isDirectory: true)
            .appendingPathComponent("localstorage.sqlite3")
        try createLegacyDatabase(at: databaseURL, values: [
            ArcoPreferenceKey.providerConfiguration: #"{"setupComplete":true,"primary":"claude","secondary":null}"#,
            ArcoPreferenceKey.audioMode: "mic",
            ArcoPreferenceKey.agentWorkspace: "/用户/项目",
            "arco.agentTranscriptVisible": "false",
            "arco.unknownFutureKey": "must not import",
        ])

        let existingProvider = #"{"setupComplete":true,"primary":"codex","secondary":null}"#
        let store = MemoryKeyValueStore([ArcoPreferenceKey.providerConfiguration: existingProvider])
        let importer = LegacyWebKitPreferencesImporter(store: store, rootURL: root)
        let result = try importer.migrateIfNeeded()
        try expect(result == .imported(3), "only missing known keys must be imported")
        try expect(store.values[ArcoPreferenceKey.providerConfiguration] == existingProvider, "legacy import must never overwrite an existing native preference")
        try expect(store.values[ArcoPreferenceKey.audioMode] == "mic", "UTF-16LE localStorage value must import exactly")
        try expect(store.values[ArcoPreferenceKey.agentWorkspace] == "/用户/项目", "UTF-16LE surrogate-free CJK text must decode exactly")
        try expect(store.values["arco.agentTranscriptVisible"] == "false", "Agent transcript visibility must survive the WebKit-to-native migration")
        try expect(!store.contains("arco.unknownFutureKey"), "unknown arco keys must not cross the migration boundary")
        try expect(store.values[ArcoPreferenceKey.nativeMigrationMarker] == "1", "migration marker must be written after imported values")
        let repeatedResult = try importer.migrateIfNeeded()
        try expect(repeatedResult == .alreadyCompleted, "migration marker must make import one-shot")
    }
}

private func testMissingAndDamagedLegacyDatabase() throws {
    try withTemporaryDirectory { root in
        let store = MemoryKeyValueStore()
        let importer = LegacyWebKitPreferencesImporter(store: store, rootURL: root)
        let result = try importer.migrateIfNeeded()
        try expect(result == .noLegacyData, "missing WebKit data must complete as an empty migration")
        try expect(store.values[ArcoPreferenceKey.nativeMigrationMarker] == "1", "empty migration must still be marked complete")
    }

    try withTemporaryDirectory { root in
        let databaseURL = root
            .appendingPathComponent("Default/hash/LocalStorage", isDirectory: true)
            .appendingPathComponent("localstorage.sqlite3")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a sqlite database".utf8).write(to: databaseURL)
        let store = MemoryKeyValueStore()
        let importer = LegacyWebKitPreferencesImporter(store: store, rootURL: root)
        assertions += 1
        do {
            _ = try importer.migrateIfNeeded()
            throw ContractFailure(description: "damaged SQLite database must fail migration")
        } catch is LegacyPreferencesMigrationError {
            // Expected: no destination value, especially the marker, may be written before a full read.
        }
        try expect(!store.contains(ArcoPreferenceKey.nativeMigrationMarker), "failed migration must not commit its marker")
        try expect(store.values.count == 0, "failed migration must not partially import preferences")
    }
}

do {
    try testDefaultsAndRoundTrips()
    try testUserDefaultsAdapter()
    try testMalformedAndInvalidStorage()
    try testLegacyNormalization()
    try testLegacySQLiteImportAndNoOverwrite()
    try testMissingAndDamagedLegacyDatabase()
    print("ArcoPreferencesContractTests: \(assertions) assertions passed")
} catch {
    fputs("ArcoPreferencesContractTests failed: \(error)\n", stderr)
    exit(1)
}
