import Foundation
import Security

/// Which notification gets forwarded. Order drives the settings page.
enum ForwardingEventType: String, CaseIterable, Codable, Identifiable {
    case newMessage
    case missedCall
    case incomingCall
    case systemStatus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newMessage: return L10n.tr("新短信")
        case .missedCall: return L10n.tr("未接来电")
        case .incomingCall: return L10n.tr("来电")
        case .systemStatus: return L10n.tr("系统状态")
        }
    }

    var detail: String {
        switch self {
        case .newMessage: return L10n.tr("收到新短信后转发")
        case .missedCall: return L10n.tr("未接来电时转发")
        case .incomingCall: return L10n.tr("来电时转发。IM 延迟较高，可能来不及接听。")
        case .systemStatus: return L10n.tr("模组连接、断开或连接异常时转发")
        }
    }

    /// The request-body template group this event edits in the UI.
    var templateGroup: ForwardingTemplateGroup {
        switch self {
        case .newMessage: return .sms
        case .missedCall, .incomingCall: return .call
        case .systemStatus: return .systemStatus
        }
    }
}

/// The mockup's 短信 / 通话 / 系统状态 template tabs.
enum ForwardingTemplateGroup: String, CaseIterable, Codable {
    case sms
    case call
    case systemStatus

    var title: String {
        switch self {
        case .sms: return L10n.tr("短信")
        case .call: return L10n.tr("通话")
        case .systemStatus: return L10n.tr("系统状态")
        }
    }

    var events: [ForwardingEventType] {
        ForwardingEventType.allCases.filter { $0.templateGroup == self }
    }
}

enum ForwardingChannelKind: String, CaseIterable, Codable, Identifiable {
    case custom
    case feishu
    case dingtalk
    case telegram
    case qqPrivate
    case qqGroup
    case wecom
    case bark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom: return L10n.tr("自定义")
        case .feishu: return L10n.tr("飞书机器人")
        case .dingtalk: return L10n.tr("钉钉机器人")
        case .telegram: return L10n.tr("Telegram")
        case .qqPrivate: return L10n.tr("QQ 机器人（私聊）")
        case .qqGroup: return L10n.tr("QQ 机器人（群）")
        case .wecom: return L10n.tr("企业微信机器人")
        case .bark: return L10n.tr("Bark")
        }
    }

    var systemImage: String {
        switch self {
        case .custom: return "paperplane"
        case .feishu: return "bird"
        case .dingtalk: return "bubble.left.and.bubble.right"
        case .telegram: return "paperplane.fill"
        case .qqPrivate, .qqGroup: return "person.crop.circle.badge.questionmark"
        case .wecom: return "person.3"
        case .bark: return "bell.fill"
        }
    }

    /// Non-secret configuration fields the editor shows for this kind.
    var usesWebhookURL: Bool {
        switch self {
        case .feishu, .wecom, .bark, .custom: return true
        case .dingtalk, .telegram, .qqPrivate, .qqGroup: return false
        }
    }

    var usesToken: Bool {
        switch self {
        case .dingtalk, .telegram, .qqPrivate, .qqGroup: return true
        case .feishu, .wecom, .bark, .custom: return false
        }
    }

    var usesSigningSecret: Bool {
        switch self {
        case .feishu, .dingtalk: return true
        default: return false
        }
    }

    var usesTarget: Bool {
        switch self {
        case .telegram, .qqPrivate, .qqGroup: return true
        default: return false
        }
    }

    var usesHeaders: Bool {
        self == .custom || self == .qqPrivate || self == .qqGroup
    }

    var targetPlaceholder: String {
        switch self {
        case .telegram: return L10n.tr("聊天 ID（chat_id）")
        case .qqPrivate: return L10n.tr("QQ 号")
        case .qqGroup: return L10n.tr("群号")
        default: return ""
        }
    }

    var urlPlaceholder: String {
        switch self {
        case .bark: return L10n.tr("https://api.day.app/你的Key")
        case .custom: return L10n.tr("https://example.com/webhook")
        default: return L10n.tr("https://open.feishu.cn/open-apis/bot/v2/hook/…")
        }
    }
}

/// One configured outbound channel. Secret-bearing values live in the
/// Keychain (`ForwardingCredentialStore`), keyed by this channel's ID; only
/// the non-secret shape persists here.
struct ForwardingChannel: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var kind: ForwardingChannelKind
    var name: String = ""
    var isEnabled = true
    /// Per-event body template overrides. A missing entry uses the kind's
    /// default template.
    var templates: [String: String] = [:]

    var displayName: String {
        name.isEmpty ? kind.title : name
    }

    func template(for event: ForwardingEventType) -> String? {
        templates[event.rawValue]
    }

    mutating func setTemplate(_ template: String?, for event: ForwardingEventType) {
        if let template, !template.isEmpty {
            templates[event.rawValue] = template
        } else {
            templates.removeValue(forKey: event.rawValue)
        }
    }
}

/// Secret/endpoint values for one channel. Fields the kind does not use stay
/// empty.
struct ForwardingChannelSecrets: Equatable {
    var url = ""
    var token = ""
    var secret = ""
    var target = ""
    /// Custom request headers, one "Name: value" per line.
    var headers = ""

    var isConfigured: Bool {
        !url.trimmingCharacters(in: .whitespaces).isEmpty ||
            !token.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Keychain-backed storage for per-channel endpoint/secret values, mirroring
/// the previous `SMSForwardingCredentialStore` (fixed service, per-item
/// accounts) but keyed by channel UUID so channels can be added and removed.
struct ForwardingCredentialStore {
    private let service = "app.celldock.mac.notification-forwarding"

    private enum Field: String, CaseIterable {
        case url
        case token
        case secret
        case target
        case headers
    }

    func secrets(for channelID: UUID) -> ForwardingChannelSecrets {
        var secrets = ForwardingChannelSecrets()
        for field in Field.allCases {
            let value = (try? read(account: account(channelID, field))) ?? nil
            switch field {
            case .url: secrets.url = value ?? ""
            case .token: secrets.token = value ?? ""
            case .secret: secrets.secret = value ?? ""
            case .target: secrets.target = value ?? ""
            case .headers: secrets.headers = value ?? ""
            }
        }
        return secrets
    }

    func save(_ secrets: ForwardingChannelSecrets, for channelID: UUID) {
        for field in Field.allCases {
            let value: String
            switch field {
            case .url: value = secrets.url
            case .token: value = secrets.token
            case .secret: value = secrets.secret
            case .target: value = secrets.target
            case .headers: value = secrets.headers
            }
            try? write(value, account: account(channelID, field))
        }
    }

    func deleteSecrets(for channelID: UUID) {
        for field in Field.allCases {
            try? delete(account: account(channelID, field))
        }
    }

    private func account(_ channelID: UUID, _ field: Field) -> String {
        "channel.\(channelID.uuidString).\(field.rawValue)"
    }

    private func read(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw BoundSocketError.systemCall(operation: "Keychain read", code: status)
        }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw BoundSocketError.systemCall(operation: "Keychain update", code: updated)
        }
        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BoundSocketError.systemCall(operation: "Keychain add", code: status)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BoundSocketError.systemCall(operation: "Keychain delete", code: status)
        }
    }
}

/// Sheet payload pairing a channel with whether it is being created.
struct ForwardingChannelDraft: Identifiable, Equatable {
    let channel: ForwardingChannel
    let isNew: Bool
    var id: UUID { channel.id }
}

/// One outbound notification, already resolved to its display values.
struct ForwardingEventContext {
    let type: ForwardingEventType
    let title: String
    let content: String
    let sender: String?
    let operatorName: String?
    let signal: String?
    let moduleName: String?
    let direction: String?
    let duration: String?

    var variables: [String: String] {
        [
            "event": type.title,
            "title": title,
            "content": content,
            "sender": sender ?? "",
            "number": sender ?? "",
            "time": ForwardingEventContext.timestampFormatter.string(from: Date()),
            "operator": operatorName ?? "",
            "signal": signal ?? "",
            "direction": direction ?? "",
            "duration": duration ?? "",
            "module": moduleName ?? "",
        ]
    }

    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
