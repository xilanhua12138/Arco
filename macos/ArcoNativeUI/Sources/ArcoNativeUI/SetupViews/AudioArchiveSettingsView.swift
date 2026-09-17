import SwiftUI

struct AudioArchiveSettingsView: View {
    @ObservedObject var viewModel: SettingsSheetViewModel
    let translate: ArcoTranslate
    @Environment(\.openURL) private var openURL

    private var locked: Bool { viewModel.snapshot.audioModeLocked || viewModel.snapshot.audioArchiveBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let settings = viewModel.snapshot.audioArchive {
                Toggle(isOn: Binding(get: { settings.enabled }, set: { enabled in
                    Task { await viewModel.actions.onChangeAudioArchive(enabled, settings.directory, settings.maxBytes) }
                })) {
                    Label(translate("audioArchive.title", [:]), systemImage: "waveform")
                        .font(ArcoTypography.sans(13, weight: .medium))
                }
                .toggleStyle(.switch)
                .disabled(locked)

                Text(translate("audioArchive.description", [:]))
                    .font(ArcoTypography.metadata)
                    .foregroundStyle(ArcoNativeColors.inkMuted)

                HStack {
                    Text(translate("audioArchive.limit", [:])).font(ArcoTypography.sans(13))
                    Spacer()
                    Picker(translate("audioArchive.limit", [:]), selection: Binding(
                        get: { settings.maxBytes }, set: { limit in
                            Task { await viewModel.actions.onChangeAudioArchive(settings.enabled, settings.directory, limit) }
                        })) {
                        ForEach(Array(Set([1, 5, 10, 20, 50, 100].map { UInt64($0) * 1_000_000_000 } + [settings.maxBytes])).sorted(), id: \.self) { bytes in
                            Text("\(bytes / 1_000_000_000) GB").tag(bytes)
                        }
                    }
                    .labelsHidden().frame(width: 100).disabled(locked)
                }

                ProgressView(value: min(Double(settings.usedBytes), Double(settings.maxBytes)), total: Double(settings.maxBytes))
                    .tint(ArcoNativeColors.brand)
                Text(translate("audioArchive.usage", [
                    "used": String(format: "%.2f", Double(settings.usedBytes) / 1_000_000_000),
                    "limit": String(settings.maxBytes / 1_000_000_000),
                    "hours": String(settings.maxBytes / 30_000_000),
                ]))
                .font(ArcoTypography.metadata).foregroundStyle(ArcoNativeColors.inkMuted)
                Text(translate("audioArchive.retention", [:]))
                    .font(ArcoTypography.metadata).foregroundStyle(ArcoNativeColors.ink)

                Text(settings.directory)
                    .font(ArcoTypography.mono(11)).foregroundStyle(ArcoNativeColors.inkMuted)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Button(translate("audioArchive.choose", [:])) { Task { await viewModel.actions.onChooseAudioArchiveDirectory() } }
                        .disabled(locked)
                    Button(translate("settings.restoreDefault", [:])) {
                        Task { await viewModel.actions.onChangeAudioArchive(settings.enabled, nil, settings.maxBytes) }
                    }.disabled(locked || settings.directory == settings.defaultDirectory)
                    Button(translate("audioArchive.open", [:])) {
                        openURL(URL(fileURLWithPath: settings.directory, isDirectory: true))
                    }.disabled(!FileManager.default.fileExists(atPath: settings.directory))
                    Spacer()
                    Button(translate("audioArchive.refresh", [:])) { Task { await viewModel.actions.onRefreshAudioArchive() } }
                }
                .buttonStyle(.plain).foregroundStyle(ArcoNativeColors.action)
                .font(ArcoTypography.metadata)

                if viewModel.snapshot.audioModeLocked {
                    Text(translate("settings.storageLocked", [:]))
                        .font(ArcoTypography.metadata).foregroundStyle(ArcoNativeColors.inkMuted)
                }
                if let error = settings.status?.error {
                    Text(translate("audioArchive.partial", [:]) + "\n" + error)
                        .font(ArcoTypography.metadata).foregroundStyle(ArcoNativeColors.warning)
                }
            }
            if let error = viewModel.snapshot.audioArchiveError {
                Text(error).font(ArcoTypography.metadata).foregroundStyle(ArcoNativeColors.warning)
                Button(translate("audioArchive.refresh", [:])) { Task { await viewModel.actions.onRefreshAudioArchive() } }
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }
        .task { await viewModel.actions.onRefreshAudioArchive() }
    }
}
