import SwiftUI

/// 语音信箱 — message list + inline settings (trigger mode, answer delay,
/// recording cap, detected Focus state). Playback reuses the call-recording
/// player because a voicemail IS the M4A recording of the answered call.
struct VoicemailListView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var voicemail: VoicemailStore
    @ObservedObject var recordings: CallRecordingStore
    @ObservedObject var contacts: SystemContactStore

    @State private var deletingRecord: VoicemailRecord?

    var body: some View {
        ResizableCommunicationSplit(sidebarWidth: .constant(CommunicationUI.sidebarWidth)) {
            list
        } detail: {
            settingsDetail
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Label(
                    L10n.tr("语音信箱"),
                    systemImage: "voicemail"
                )
                .font(.headline)
                if voicemail.unreadCount > 0 {
                    Text("\(voicemail.unreadCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.blue, in: Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            if voicemail.records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "voicemail")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(L10n.tr("暂无留言"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("启用语音信箱后，未及时接听的来电会在响铃超时后自动接听并录制留言。"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(voicemail.records) { record in
                            voicemailRow(record)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .confirmationDialog(
            L10n.tr("删除这条留言？"),
            isPresented: Binding(
                get: { deletingRecord != nil },
                set: { if !$0 { deletingRecord = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("删除留言"), role: .destructive) {
                if let record = deletingRecord {
                    voicemail.remove(record.id)
                }
                deletingRecord = nil
            }
            Button(L10n.tr("取消"), role: .cancel) { deletingRecord = nil }
        } message: {
            Text(L10n.tr("留言条目将从列表移除；底层录音文件仍保留在通话录音中。"))
        }
    }

    private func voicemailRow(_ record: VoicemailRecord) -> some View {
        let displayName = contacts.displayName(for: record.number)
        let identity = appState.privacyPresentation.identity(
            contactName: displayName,
            number: record.number
        )
        let recordingRecord = record.callRecordingRecordID.flatMap { id in
            recordings.records.first { $0.id == id }
        }
        let isPlaying = recordings.playingRecordingID == record.callRecordingRecordID
        return HStack(spacing: 10) {
            Button {
                if let recordingRecord {
                    recordings.play(recordingRecord)
                }
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(recordingRecord == nil)
            .help(recordingRecord == nil ? L10n.tr("该留言没有可用音频") : L10n.tr("播放"))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if !record.isAcknowledged {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 7, height: 7)
                    }
                    Text(verbatim: identity)
                        .font(.subheadline.weight(record.isAcknowledged ? .regular : .bold))
                        .lineLimit(1)
                    Spacer()
                    Text(record.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(L10n.tr("留言时长 %lld 秒", Int64(record.duration.rounded())))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Menu {
                if !record.isAcknowledged {
                    Button(L10n.tr("标记为已读")) { voicemail.acknowledge(record.id) }
                }
                Button(L10n.tr("删除"), role: .destructive) {
                    deletingRecord = record
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            voicemail.acknowledge(record.id)
        }
    }

    private var settingsDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(L10n.tr("启用语音信箱"), isOn: Binding(
                    get: { voicemail.settings.isEnabled },
                    set: { newValue in
                        voicemail.updateSettings(
                            VoicemailSettingsAdapter.copy(voicemail.settings) { $0.isEnabled = newValue }
                        )
                    }
                ))
                .toggleStyle(.switch)

                Toggle(L10n.tr("跟随 macOS 专注模式"), isOn: Binding(
                    get: { voicemail.settings.followsFocusMode },
                    set: { newValue in
                        voicemail.updateSettings(
                            VoicemailSettingsAdapter.copy(voicemail.settings) { $0.followsFocusMode = newValue }
                        )
                    }
                ))
                .toggleStyle(.switch)
                .disabled(!voicemail.settings.isEnabled)

                focusStatusCallout

                Stepper(
                    L10n.tr("响铃 %@ 秒后自动接听", "\(voicemail.settings.answerAfterSeconds)"),
                    value: Binding(
                        get: { voicemail.settings.answerAfterSeconds },
                        set: { newValue in
                            voicemail.updateSettings(
                                VoicemailSettingsAdapter.copy(voicemail.settings) {
                                    $0.answerAfterSeconds = min(max(newValue, 5), 60)
                                }
                            )
                        }
                    ),
                    in: 5 ... 60,
                    step: 1
                )
                .disabled(!voicemail.settings.isEnabled)

                Stepper(
                    L10n.tr("单条留言最长 %@ 秒", "\(voicemail.settings.maximumRecordSeconds)"),
                    value: Binding(
                        get: { voicemail.settings.maximumRecordSeconds },
                        set: { newValue in
                            voicemail.updateSettings(
                                VoicemailSettingsAdapter.copy(voicemail.settings) {
                                    $0.maximumRecordSeconds = min(max(newValue, 15), 300)
                                }
                            )
                        }
                    ),
                    in: 15 ... 300,
                    step: 5
                )
                .disabled(!voicemail.settings.isEnabled)

                Text(L10n.tr("语音信箱在通话音频可用时工作：响铃超时后自动接听并录音，通话结束（对方挂断或到达最长时长）后保存留言。跟随专注模式依赖系统状态探测；无法读取状态时语音信箱不会自动接管。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private var focusStatusCallout: some View {
        if voicemail.settings.isEnabled && voicemail.settings.followsFocusMode {
            switch voicemail.focusState {
            case .active:
                Label(L10n.tr("专注模式：开启中，语音信箱接管中"), systemImage: "moon.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .inactive:
                Label(L10n.tr("专注模式：已关闭，来电正常响铃"), systemImage: "moon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unknown:
                Label(L10n.tr("无法读取专注模式状态，语音信箱暂不接管"), systemImage: "moon.zzz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Pure-copy helper keeping the settings form rows terse.
enum VoicemailSettingsAdapter {
    static func copy(
        _ settings: VoicemailSettings,
        _ mutate: (inout VoicemailSettings) -> Void
    ) -> VoicemailSettings {
        var copy = settings
        mutate(&copy)
        return copy
    }
}
