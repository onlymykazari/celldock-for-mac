import Combine
import Foundation

struct NotificationForwardingSettings: Codable, Equatable {
    var isEnabled = false
    var enabledEvents: Set<ForwardingEventType> = [.newMessage, .missedCall]
    var channels: [ForwardingChannel] = []
}

struct ForwardingResult: Equatable {
    enum Outcome: Equatable {
        case success
        case failure(String)
    }

    var outcome: Outcome
    var date: Date

    var isSuccess: Bool {
        if case .success = outcome { return true }
        return false
    }

    var errorMessage: String? {
        if case let .failure(message) = outcome { return message }
        return nil
    }

    init(outcome: Outcome, date: Date) {
        self.outcome = outcome
        self.date = date
    }

    init(_ result: Result<Void, Error>, date: Date = Date()) {
        switch result {
        case .success:
            self = ForwardingResult(outcome: .success, date: date)
        case let .failure(error):
            self = ForwardingResult(
                outcome: .failure(error.localizedDescription),
                date: date
            )
        }
    }
}

/// Configuration store for notification forwarding: master switch, per-event
/// toggles and the outbound channel list. Only the non-secret shape persists
/// here; endpoint URLs, tokens and signing secrets live in the Keychain via
/// `ForwardingCredentialStore`.
@MainActor
final class NotificationForwardingStore: ObservableObject {
    static let shared = NotificationForwardingStore()

    @Published private(set) var settings: NotificationForwardingSettings
    @Published private(set) var secretsByChannelID: [UUID: ForwardingChannelSecrets] = [:]
    @Published var lastResults: [UUID: ForwardingResult] = [:]

    private let defaults: UserDefaults
    private let credentialStore: ForwardingCredentialStore
    private let key = "NotificationForwardingSettings.v1"
    private static let migrationKey = "NotificationForwarding.MigratedFromSMSForwarding.v1"

    init(
        defaults: UserDefaults = .standard,
        credentialStore: ForwardingCredentialStore = ForwardingCredentialStore()
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        settings = defaults.data(forKey: key).flatMap {
            try? JSONDecoder().decode(NotificationForwardingSettings.self, from: $0)
        } ?? NotificationForwardingSettings()
        reloadSecrets()
        Self.migrateLegacySMSForwardingIfNeeded(into: self)
    }

    var channels: [ForwardingChannel] {
        settings.channels
    }

    func isEnabled(_ event: ForwardingEventType) -> Bool {
        settings.isEnabled && settings.enabledEvents.contains(event)
    }

    func setMasterEnabled(_ enabled: Bool) {
        settings.isEnabled = enabled
        persist()
    }

    func setEventEnabled(_ enabled: Bool, for event: ForwardingEventType) {
        if enabled {
            settings.enabledEvents.insert(event)
        } else {
            settings.enabledEvents.remove(event)
        }
        persist()
    }

    func addChannel(_ channel: ForwardingChannel, secrets: ForwardingChannelSecrets) {
        settings.channels.append(channel)
        credentialStore.save(secrets, for: channel.id)
        reloadSecrets()
        persist()
    }

    func updateChannel(_ channel: ForwardingChannel, secrets: ForwardingChannelSecrets) {
        guard let index = settings.channels.firstIndex(where: { $0.id == channel.id }) else {
            return
        }
        settings.channels[index] = channel
        credentialStore.save(secrets, for: channel.id)
        reloadSecrets()
        persist()
    }

    func setChannelEnabled(_ enabled: Bool, for channelID: UUID) {
        guard let index = settings.channels.firstIndex(where: { $0.id == channelID }) else {
            return
        }
        settings.channels[index].isEnabled = enabled
        persist()
    }

    func removeChannel(_ channelID: UUID) {
        settings.channels.removeAll { $0.id == channelID }
        credentialStore.deleteSecrets(for: channelID)
        reloadSecrets()
        persist()
    }

    func secrets(for channel: ForwardingChannel) -> ForwardingChannelSecrets {
        secretsByChannelID[channel.id] ?? ForwardingChannelSecrets()
    }

    func recordResult(_ result: ForwardingResult, for channel: ForwardingChannel) {
        lastResults[channel.id] = result
    }

    private func reloadSecrets() {
        var map: [UUID: ForwardingChannelSecrets] = [:]
        for channel in settings.channels {
            map[channel.id] = credentialStore.secrets(for: channel.id)
        }
        secretsByChannelID = map
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(settings), forKey: key)
    }

    /// One-time import of the legacy SMS-forwarding configuration (Bark,
    /// Feishu, DingTalk from `SMSForwardingSettings.v1`), so upgrading users
    /// keep working channels without re-entering secrets.
    private static func migrateLegacySMSForwardingIfNeeded(
        into store: NotificationForwardingStore
    ) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }
        defaults.set(true, forKey: migrationKey)

        guard let data = defaults.data(forKey: "SMSForwardingSettings.v1"),
              let legacy = try? JSONDecoder().decode(LegacySMSForwardingSettings.self, from: data),
              !legacy.enabledChannels.isEmpty else {
            return
        }
        let legacyStore = LegacySMSForwardingCredentialStore()
        for kind in legacy.enabledChannels {
            var secrets = ForwardingChannelSecrets()
            switch kind {
            case .bark:
                secrets.url = ((try? legacyStore.value(for: .barkServerURL)) ?? nil) ?? ""
            case .feishu:
                secrets.url = ((try? legacyStore.value(for: .feishuWebhookURL)) ?? nil) ?? ""
                secrets.secret = ((try? legacyStore.value(for: .feishuSecret)) ?? nil) ?? ""
            case .dingtalk:
                secrets.token = ((try? legacyStore.value(for: .dingtalkAccessToken)) ?? nil) ?? ""
                secrets.secret = ((try? legacyStore.value(for: .dingtalkSecret)) ?? nil) ?? ""
            }
            guard secrets.isConfigured else { continue }
            let channel = ForwardingChannel(
                kind: ForwardingChannelKind(rawValue: kind.rawValue) ?? .custom
            )
            store.addChannel(channel, secrets: secrets)
            store.settings.enabledEvents.insert(.newMessage)
            store.setMasterEnabled(true)
        }
    }
}

/// Read-only shapes of the pre-migration configuration, kept only for the
/// one-time import above.
private struct LegacySMSForwardingSettings: Codable {
    var enabledChannels: Set<LegacySMSForwardChannel>
}

private enum LegacySMSForwardChannel: String, Codable {
    case bark
    case feishu
    case dingtalk
}

private struct LegacySMSForwardingCredentialStore {
    enum Field: String {
        case barkServerURL = "bark.serverURL"
        case feishuWebhookURL = "feishu.webhookURL"
        case feishuSecret = "feishu.secret"
        case dingtalkAccessToken = "dingtalk.accessToken"
        case dingtalkSecret = "dingtalk.secret"
    }

    private let service = "app.celldockplus.mac.sms-forwarding"

    func value(for field: Field) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: field.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
