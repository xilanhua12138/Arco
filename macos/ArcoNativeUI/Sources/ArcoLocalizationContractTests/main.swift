import ArcoNativeUI
import Foundation

private struct ContractFailure: Error, CustomStringConvertible {
    let description: String
}

private final class MemoryKeyValueStore: KeyValueStore {
    private(set) var values: [String: String] = [:]

    func contains(_ key: String) -> Bool { values[key] != nil }
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

@main
private struct ArcoLocalizationContractTests {
    @MainActor
    static func main() throws {
        var assertions = 0

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            guard condition() else { throw ContractFailure(description: message) }
        }

        let englishKeys = Set(ArcoTranslations.englishMessages.keys)
        let chineseKeys = Set(ArcoTranslations.simplifiedChineseMessages.keys)
        try expect(englishKeys.count == 569, "English must contain the 568 migrated keys plus the requested home title")
        try expect(chineseKeys.count == 569, "zh-CN must contain the 568 migrated keys plus the requested home title")
        try expect(englishKeys == chineseKeys, "en and zh-CN key sets must be identical")

        try expect(
            ArcoTranslations.english("nav.history", [:]) == "History",
            "English resources must preserve literal source copy"
        )
        try expect(
            ArcoTranslations.simplifiedChinese("nav.history", [:]) == "历史",
            "zh-CN resources must preserve literal source copy"
        )
        try expect(
            ArcoTranslations.english("capture.homeTitle", [:]) == "Put communication into context",
            "English must carry the requested home-title meaning"
        )
        try expect(
            ArcoTranslations.simplifiedChinese("capture.homeTitle", [:]) == "把沟通放进上下文",
            "Chinese home title must preserve the user-provided copy exactly"
        )
        try expect(
            ArcoTranslations.simplifiedChinese(
                "agent.failover",
                ["primary": "Codex", "provider": "Claude"]
            ) == "Codex 当前不可用，正在使用 Claude。",
            "all named parameters must be interpolated"
        )
        try expect(
            ArcoTranslations.text(
                "capture.audioLabel",
                locale: .english,
                parameters: ["mode": "Hybrid", "source": "System audio"]
            ) == "Audio capture · Hybrid · System audio",
            "multi-parameter interpolation must match replaceAll semantics"
        )
        try expect(
            ArcoTranslations.text("unknown.contract.key", locale: .simplifiedChinese)
                == "unknown.contract.key",
            "unknown runtime keys must remain visible as their key"
        )

        try expect(
            ArcoLocalization.resolveLocale(
                storedLocale: "en",
                preferredLanguages: ["zh-CN"]
            ) == .english,
            "a supported saved locale must beat preferred languages"
        )
        try expect(
            ArcoLocalization.resolveLocale(
                storedLocale: "zh-CN",
                preferredLanguages: ["en-US"]
            ) == .simplifiedChinese,
            "saved zh-CN must remain zh-CN"
        )
        try expect(
            ArcoLocalization.resolveLocale(
                storedLocale: nil,
                preferredLanguages: ["zh-HK", "en-US"]
            ) == .simplifiedChinese,
            "all zh-prefixed system locales must normalize to zh-CN"
        )
        try expect(
            ArcoLocalization.resolveLocale(
                storedLocale: "unsupported",
                preferredLanguages: ["fr-FR", "de-DE"]
            ) == .english,
            "invalid persisted values must fall back to English for non-Chinese systems"
        )
        try expect(
            ArcoLocalization.resolveLocale(
                storedLocale: "ZH-cn",
                preferredLanguages: ["en-US"]
            ) == .english,
            "persisted locale matching must stay exact and case-sensitive"
        )

        let store = MemoryKeyValueStore()
        let preferences = ArcoPreferences(store: store)
        let localization = ArcoLocalization(
            preferences: preferences,
            preferredLanguages: ["zh-Hans-CN"]
        )
        try expect(localization.locale == .simplifiedChinese, "initial locale must follow system language")
        localization.setLocale(.english)
        try expect(
            store.string(forKey: ArcoLocalization.localeStorageKey) == "en",
            "explicit locale changes must persist under arco.locale"
        )
        let restored = ArcoLocalization(
            preferences: preferences,
            preferredLanguages: ["zh-CN"]
        )
        try expect(restored.locale == .english, "persisted locale must restore across app launches")
        localization.synchronize(
            storedLocale: "not-a-locale",
            preferredLanguages: ["zh-TW"]
        )
        try expect(
            localization.locale == .simplifiedChinese,
            "external malformed values must normalize through preferred languages"
        )

        try expect(
            formatDurationLabel(" 001 MIN ", translate: ArcoTranslations.simplifiedChinese)
                == "1 分钟",
            "duration normalization must mirror Number conversion and case-insensitive min"
        )
        try expect(
            formatDurationLabel("about 3m", translate: ArcoTranslations.english) == "about 3m",
            "non-contract duration labels must remain byte-for-byte unchanged"
        )
        try expect(
            localizedSpeakerLabel("REMOTE speaker 12", translate: ArcoTranslations.english)
                == "Remote 12",
            "remote labels must use the first numeric sequence"
        )
        try expect(
            localizedSpeakerLabel("in room", translate: ArcoTranslations.simplifiedChinese)
                == "现场 1",
            "room labels without a number must use one"
        )
        try expect(
            localizedSpeakerLabel("Host", translate: ArcoTranslations.simplifiedChinese) == "Host",
            "custom speaker labels must not be rewritten"
        )

        print("Arco localization contract tests passed (\(assertions) assertions)")
    }
}
