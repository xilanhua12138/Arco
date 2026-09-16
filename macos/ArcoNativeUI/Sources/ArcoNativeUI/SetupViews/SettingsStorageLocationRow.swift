import SwiftUI

/// Storage controls share one quiet row; changing a location is a secondary action.
struct SettingsStorageLocationRow: View {
    let title: String
    let detail: String
    let directory: String
    let usingDefault: Bool
    let locked: Bool
    let translate: ArcoTranslate
    var choose: (() async -> Void)? = nil
    var reset: (() async -> Void)? = nil
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(ArcoTypography.sans(14, weight: .medium)).foregroundStyle(ArcoNativeColors.inkStrong)
                Text(detail).font(ArcoTypography.sans(13)).foregroundStyle(ArcoNativeColors.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(translate("settings.openFolder", [:])) {
                openURL(URL(fileURLWithPath: directory, isDirectory: true))
            }
            .buttonStyle(SettingsActionButtonStyle())
            .disabled(!FileManager.default.fileExists(atPath: directory))
            .help(directory)
            if let choose {
                SettingsLocationMenu(directory: directory, usingDefault: usingDefault,
                    locked: locked, translate: translate, choose: choose, reset: reset)
            }
        }
        .padding(.vertical, 20)
        .frame(minHeight: 72)
        .overlay(alignment: .bottom) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }
    }
}

struct SettingsLocationMenu: View {
    let directory: String
    let usingDefault: Bool
    let locked: Bool
    let translate: ArcoTranslate
    let choose: () async -> Void
    var reset: (() async -> Void)? = nil

    var body: some View {
        ArcoActionMenuButton(title: translate("settings.storageOptions", [:]), actions: actions)
            .frame(width: 28, height: 30)
            .help(directory)
    }

    private var actions: [ArcoMenuAction] {
        var entries: [ArcoMenuAction] = [
            .init(title: directory, symbol: "folder", enabled: false),
            .divider,
            .init(title: translate("audioArchive.choose", [:]), symbol: "folder", enabled: !locked,
                  perform: { Task { await choose() } }),
        ]
        if let reset {
            entries.append(.init(title: translate("settings.restoreDefault", [:]), symbol: "arrow.uturn.backward",
                enabled: !locked && !usingDefault, perform: { Task { await reset() } }))
        }
        return entries
    }
}
