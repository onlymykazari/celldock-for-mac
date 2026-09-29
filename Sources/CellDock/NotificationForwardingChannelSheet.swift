import SwiftUI

/// Configure one outbound forwarding channel: endpoint fields per kind, the
/// per-event request-body templates (短信 / 通话 / 系统状态 tabs, mirroring
/// the mockup) and a test send.
struct NotificationForwardingChannelSheet: View {
    let channel: ForwardingChannel
    let isNew: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isEnabled: Bool
    @State private var templates: [String: String]
    @State private var secrets: ForwardingChannelSecrets
    @State private var selectedGroup: ForwardingTemplateGroup = .sms
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testIsError = false
    @State private var testEvent: ForwardingEventType = .newMessage

    private let service = NotificationForwardingService()

    init(channel: ForwardingChannel, isNew: Bool) {
        self.channel = channel
        self.isNew = isNew
        _name = State(initialValue: channel.name)
        _isEnabled = State(initialValue: channel.isEnabled)
        _templates = State(initialValue: channel.templates)
        _secrets = State(initialValue: NotificationForwardingStore.shared.secrets(for: channel))
        _testEvent = State(initialValue: .newMessage)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    basicsSection
                    endpointSection
                    templateSection
                    testSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 640)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isNew
                ? L10n.tr("添加%@", channel.kind.title)
                : L10n.tr("配置%@", channel.kind.title))
                .font(.title3.bold())
            Text(L10n.tr("请求体会按类型填入，可再自行修改。"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var basicsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent(L10n.tr("渠道名称")) {
                TextField(
                    text: $name,
                    prompt: Text(verbatim: channel.kind.title)
                ) {
                    Text(verbatim: channel.kind.title)
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            }
            Toggle(L10n.tr("启用该渠道"), isOn: $isEnabled)
                .toggleStyle(.switch)
        }
    }

    private var endpointSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("渠道配置"))
                .font(.headline)
            if channel.kind.usesWebhookURL {
                fieldRow(title: L10n.tr("Webhook 地址"), text: $secrets.url, placeholder: channel.kind.urlPlaceholder)
            }
            if channel.kind.usesToken {
                fieldRow(
                    title: channel.kind == .dingtalk
                        ? L10n.tr("Access Token")
                        : L10n.tr("Bot Token"),
                    text: $secrets.token,
                    placeholder: L10n.tr("由对应平台生成的凭据")
                )
            }
            if channel.kind.usesSigningSecret {
                fieldRow(
                    title: L10n.tr("加签密钥（可选）"),
                    text: $secrets.secret,
                    placeholder: L10n.tr("机器人开启签名校验时填写")
                )
            }
            if channel.kind.usesTarget {
                fieldRow(
                    title: L10n.tr("目标 ID"),
                    text: $secrets.target,
                    placeholder: channel.kind.targetPlaceholder
                )
            }
            if channel.kind.usesHeaders {
                headersField
            }
            if channel.kind == .qqPrivate || channel.kind == .qqGroup {
                Text(L10n.tr("填 OneBot v11 HTTP 接口地址，例如 http://127.0.0.1:5700"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var headersField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("自定义请求头（可选，每行一条“名称: 值”）"))
                .font(.caption.weight(.medium))
            TextEditor(text: $secrets.headers)
                .font(.caption.monospaced())
                .frame(height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.7)
                )
        }
    }

    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L10n.tr("请求体模板"))
                    .font(.headline)
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(L10n.tr("变量：{{title}}、{{content}}、{{sender}}、{{time}}、{{operator}}、{{event}}、{{target}}、{{signal}} 等。JSON 模板中的值会自动转义；留空使用默认模板。"))
                Spacer()
                Picker(L10n.tr("模板分组"), selection: $selectedGroup) {
                    ForEach(ForwardingTemplateGroup.allCases, id: \.self) { group in
                        Text(group.title).tag(group)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            ForEach(selectedGroup.events) { event in
                templateEditor(for: event)
            }
        }
    }

    private func templateEditor(for event: ForwardingEventType) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(event.title)
                    .font(.caption.weight(.semibold))
                Text(L10n.tr("用于%@通知", event.title))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if templates[event.rawValue] != nil {
                    Button(L10n.tr("恢复默认")) {
                        templates.removeValue(forKey: event.rawValue)
                        templates[event.rawValue] = ""
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                }
            }
            TextEditor(text: Binding(
                get: { templates[event.rawValue] ?? "" },
                set: { templates[event.rawValue] = $0 }
            ))
            .font(.caption.monospaced())
            .frame(minHeight: 88, maxHeight: 140)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.7)
            )
        }
    }

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    sendTest()
                } label: {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L10n.tr("发送测试"))
                    }
                }
                .disabled(isTesting)

                Picker(L10n.tr("测试事件"), selection: $testEvent) {
                    ForEach(ForwardingEventType.allCases) { event in
                        Text(event.title).tag(event)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)

                if let testMessage {
                    Text(testMessage)
                        .font(.caption)
                        .foregroundStyle(testIsError ? Color.red : Color.green)
                        .lineLimit(2)
                }
                Spacer()
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L10n.tr("取消"), role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(L10n.tr("保存")) {
                save()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func fieldRow(
        title: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
            TextField(text: text, prompt: Text(placeholder)) {
                Text(verbatim: title)
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private func sendTest() {
        isTesting = true
        testMessage = nil
        let draft = currentChannel()
        let service = self.service
        Task { @MainActor in
            let result = await service.sendTest(channel: draft, event: testEvent)
            isTesting = false
            switch result {
            case .success:
                testIsError = false
                testMessage = L10n.tr("测试消息已发送。")
            case let .failure(error):
                testIsError = true
                testMessage = error.localizedDescription
            }
        }
    }

    private func save() {
        var draft = currentChannel()
        let trimmedTemplates = templates.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.value.isEmpty }
        draft.templates = trimmedTemplates
        if isNew {
            NotificationForwardingStore.shared.addChannel(draft, secrets: secrets)
        } else {
            NotificationForwardingStore.shared.updateChannel(draft, secrets: secrets)
        }
        dismiss()
    }

    private func currentChannel() -> ForwardingChannel {
        var draft = channel
        draft.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.isEnabled = isEnabled
        return draft
    }
}
