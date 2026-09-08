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
            .buttonStyle(.bordered).controlSize(.regular)
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
        Menu {
            Text(directory)
            Divider()
            Button(translate("audioArchive.choose", [:])) { Task { await choose() } }
                .disabled(locked)
            if let reset {
                Button(translate("settings.restoreDefault", [:])) { Task { await reset() } }
                    .disabled(locked || usingDefault)
            }
        } label: {
            Label(translate("settings.storageOptions", [:]), systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 28, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(translate("settings.storageOptions", [:]))
        .help(directory)
    }
}
