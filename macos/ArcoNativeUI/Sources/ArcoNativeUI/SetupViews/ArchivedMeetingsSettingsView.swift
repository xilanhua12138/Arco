import SwiftUI

struct ArchivedMeetingsSettingsView: View {
    let store: ArcoStore
    let translate: ArcoTranslate

    var body: some View {
        SettingsSection(title: translate("history.archived", [:]), symbol: "archivebox") {
            Text(translate("history.archivedHelp", [:]))
                .font(ArcoTypography.small)
                .foregroundStyle(ArcoNativeColors.inkMuted)
            if store.archivedMeetingsLoading && store.archivedMeetings.isEmpty {
                ProgressView().controlSize(.small).padding(.vertical, 12)
            } else if store.archivedMeetings.isEmpty {
                Text(translate("history.noArchived", [:]))
                    .font(ArcoTypography.body).foregroundStyle(ArcoNativeColors.inkMuted)
                    .padding(.vertical, 16)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(store.archivedMeetings) { meeting in
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(meeting.title ?? translate("common.untitledMeeting", [:]))
                                    .font(ArcoTypography.bodyStrong).lineLimit(2)
                                    .foregroundStyle(ArcoNativeColors.inkStrong)
                                Text(meeting.startedAt.prefix(10))
                                    .font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.inkMuted)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                Task { await store.manageMeeting(meeting.id, archived: false) }
                            } label: {
                                Label(translate("history.restore", [:]), systemImage: "arrow.uturn.backward")
                            }
                            .buttonStyle(.bordered)
                            .disabled(store.meetingManagementBusy)
                            .help(translate("history.restoreHelp", [:]))
                            .accessibilityLabel(translate("history.restore", [:]) + " " + (meeting.title ?? translate("common.untitledMeeting", [:])))
                        }.padding(.vertical, 12)
                        if meeting.id != store.archivedMeetings.last?.id { Divider() }
                    }
                }.padding(.top, 8)
            }
            if let error = store.meetingManagementError {
                HStack {
                    Text(error).font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.warning)
                    Spacer()
                    Button(translate("history.retry", [:])) { Task { await store.loadArchivedMeetings() } }
                }
            }
        }
        .task { await store.loadArchivedMeetings() }
    }
}
