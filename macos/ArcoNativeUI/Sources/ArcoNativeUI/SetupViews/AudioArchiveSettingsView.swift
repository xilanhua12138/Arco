import SwiftUI

struct AudioArchiveSettingsView: View {
    @ObservedObject var viewModel: SettingsSheetViewModel
    let translate: ArcoTranslate
    @Environment(\.openURL) private var openURL

    private var locked: Bool { viewModel.snapshot.audioModeLocked || viewModel.snapshot.audioArchiveBusy }

    private func formattedUsage(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let settings = viewModel.snapshot.audioArchive {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(translate("audioArchive.title", [:])).font(ArcoTypography.sans(14, weight: .medium))
                        Text(translate("audioArchive.description", [:]))
                            .font(ArcoTypography.sans(13)).foregroundStyle(ArcoNativeColors.inkMuted)
                    }
                    Spacer()
                    Toggle(translate("audioArchive.title", [:]), isOn: Binding(
                        get: { settings.enabled }, set: { enabled in
                            Task { await viewModel.actions.onChangeAudioArchive(enabled, settings.directory, settings.maxBytes) }
                        }))
                        .labelsHidden().toggleStyle(.switch).disabled(locked)
                }
                .padding(.vertical, 20)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(translate("audioArchive.storage", [:])).font(ArcoTypography.sans(14, weight: .medium))
                            Text(translate("audioArchive.used", ["size": formattedUsage(settings.usedBytes)]))
                                .font(ArcoTypography.sans(13)).foregroundStyle(ArcoNativeColors.inkMuted)
                        }
                        Spacer(minLength: 0)
                        Button(translate("settings.openFolder", [:])) {
                            openURL(URL(fileURLWithPath: settings.directory, isDirectory: true))
                        }
                        .buttonStyle(.bordered).controlSize(.regular)
                        .disabled(!FileManager.default.fileExists(atPath: settings.directory))
                        .help(settings.directory)
                        Picker(translate("audioArchive.limit", [:]), selection: Binding(
                            get: { settings.maxBytes }, set: { limit in
                                Task { await viewModel.actions.onChangeAudioArchive(settings.enabled, settings.directory, limit) }
                            })) {
                            ForEach(Array(Set([1, 5, 10, 20, 50, 100].map { UInt64($0) * 1_000_000_000 } + [settings.maxBytes])).sorted(), id: \.self) { bytes in
                                Text("\(bytes / 1_000_000_000) GB").tag(bytes)
                            }
                        }
                        .labelsHidden().frame(width: 95).disabled(locked)
                        SettingsLocationMenu(directory: settings.directory,
                            usingDefault: settings.directory == settings.defaultDirectory, locked: locked, translate: translate,
                            choose: { await viewModel.actions.onChooseAudioArchiveDirectory() },
                            reset: { await viewModel.actions.onChangeAudioArchive(settings.enabled, nil, settings.maxBytes) })
                    }
                    ProgressView(value: min(Double(settings.usedBytes), Double(settings.maxBytes)), total: max(1, Double(settings.maxBytes)))
                        .tint(ArcoNativeColors.inkMuted)
                        .accessibilityLabel(translate("audioArchive.storage", [:]))
                    Text(translate("audioArchive.retention", [:]))
                        .font(ArcoTypography.sans(13)).foregroundStyle(ArcoNativeColors.inkMuted)
                    if let error = settings.status?.error {
                        Text(translate("audioArchive.partial", [:]) + "\n" + error)
                            .font(ArcoTypography.sans(13)).foregroundStyle(ArcoNativeColors.warning)
                    }
                }
                .padding(.vertical, 20)
            }
            if let error = viewModel.snapshot.audioArchiveError {
                Text(error).font(ArcoTypography.sans(13)).foregroundStyle(ArcoNativeColors.warning).padding(.top, 12)
                Button(translate("audioArchive.refresh", [:])) { Task { await viewModel.actions.onRefreshAudioArchive() } }
                    .padding(.top, 8)
            }
        }
        .task { await viewModel.actions.onRefreshAudioArchive() }
    }
}
