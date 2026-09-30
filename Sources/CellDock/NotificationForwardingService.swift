import Foundation

/// Dispatches notification events (new SMS, missed/incoming calls, system
/// status) to the configured outbound channels. Rendering happens on the main
/// actor from the store snapshot; the network calls run detached so a slow
/// webhook can never delay call or SMS handling.
final class NotificationForwardingService {
    static let shared = NotificationForwardingService()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Event entry points (fire and forget)

    @MainActor
    func forward(_ message: SMSMessage, moduleName: String?, operatorName: String?) {
        dispatch(.init(
            type: .newMessage,
            title: L10n.tr("[CellDockPlus] 新短信"),
            content: message.body,
            sender: message.sender,
            operatorName: operatorName,
            signal: nil,
            moduleName: moduleName,
            direction: L10n.tr("接收"),
            duration: nil
        ))
    }

    @MainActor
    func forwardMissedCall(_ record: CallHistoryRecord, moduleName: String?, operatorName: String?) {
        dispatch(.init(
            type: .missedCall,
            title: L10n.tr("[CellDockPlus] 未接来电"),
            content: L10n.tr("未接来电：%@", record.number),
            sender: record.number,
            operatorName: operatorName,
            signal: nil,
            moduleName: moduleName,
            direction: L10n.tr("入"),
            duration: nil
        ))
    }

    @MainActor
    func forwardIncomingCall(number: String?, moduleName: String?, operatorName: String?) {
        guard let number, !number.isEmpty else { return }
        dispatch(.init(
            type: .incomingCall,
            title: L10n.tr("[CellDockPlus] 来电"),
            content: L10n.tr("来电：%@", number),
            sender: number,
            operatorName: operatorName,
            signal: nil,
            moduleName: moduleName,
            direction: L10n.tr("入"),
            duration: nil
        ))
    }

    @MainActor
    func forwardSystemStatus(
        _ summary: String,
        moduleName: String?,
        operatorName: String?,
        signal: String?
    ) {
        dispatch(.init(
            type: .systemStatus,
            title: L10n.tr("[CellDockPlus] 系统状态"),
            content: summary,
            sender: nil,
            operatorName: operatorName,
            signal: signal,
            moduleName: moduleName,
            direction: nil,
            duration: nil
        ))
    }

    @MainActor
    func dispatch(_ event: ForwardingEventContext) {
        let store = NotificationForwardingStore.shared
        guard store.isEnabled(event.type) else { return }
        let targets = store.channels.filter { $0.isEnabled }
        guard !targets.isEmpty else { return }
        let secretsByID = store.secretsByChannelID
        for channel in targets {
            let secrets = secretsByID[channel.id] ?? ForwardingChannelSecrets()
            // {{target}} is channel-specific (chat id / QQ number), supplied
            // from the channel's secrets rather than the event context.
            let variables = event.variables.merging(["target": secrets.target]) { _, new in new }
            let rendered = NotificationTemplateRenderer.render(
                template: channel.template(for: event.type) ?? "",
                variables: variables,
                channelKind: channel.kind,
                event: event.type
            )
            // Off-main delivery: a slow webhook must never delay SMS/call
            // handling, and the semaphore-based send must not touch the
            // main thread.
            Task.detached(priority: .utility) {
                let result = Self.deliver(
                    kind: channel.kind,
                    secrets: secrets,
                    rendered: rendered
                )
                await MainActor.run {
                    NotificationForwardingStore.shared.recordResult(
                        ForwardingResult(result),
                        for: channel
                    )
                }
            }
        }
    }

    // MARK: - Delivery

    enum DeliveryError: LocalizedError {
        case missingConfiguration
        case invalidURL
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .missingConfiguration: return L10n.tr("尚未填写该渠道的配置")
            case .invalidURL: return L10n.tr("配置里的地址无效")
            case let .transport(message): return message
            }
        }
    }

    /// Blocking network send for one channel. Only call from a detached task
    /// or an async context — never the main thread.
    static func deliver(
        kind: ForwardingChannelKind,
        secrets: ForwardingChannelSecrets,
        rendered: String
    ) -> Result<Void, Error> {
        do {
            let body = try body(
                for: kind,
                secrets: secrets,
                rendered: rendered
            )
            let request = try buildRequest(kind: kind, secrets: secrets, body: body)
            try sendSynchronously(request)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    static func buildRequest(
        kind: ForwardingChannelKind,
        secrets: ForwardingChannelSecrets,
        body: String
    ) throws -> URLRequest {
        let payload = body.data(using: .utf8)
        var request: URLRequest
        switch kind {
        case .bark, .feishu, .wecom, .custom:
            guard let url = URL(string: secrets.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw DeliveryError.missingConfiguration
            }
            request = URLRequest(url: url)
        case .dingtalk:
            guard !secrets.token.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw DeliveryError.missingConfiguration
            }
            // Built by hand rather than via URLComponents.queryItems: that
            // API's default percent-encoding leaves "+" untouched, and
            // DingTalk's base64 signature routinely contains it — a literal
            // "+" a server decodes as a space, silently breaking signature
            // verification.
            var query = "access_token=\(SMSForwardingSigning.urlEncodedQueryValue(secrets.token))"
            let secret = secrets.secret.trimmingCharacters(in: .whitespacesAndNewlines)
            if !secret.isEmpty {
                let timestamp = Int(Date().timeIntervalSince1970 * 1000)
                let sign = SMSForwardingSigning.dingTalkSign(
                    secret: secret,
                    timestampMilliseconds: timestamp
                )
                query += "&timestamp=\(timestamp)"
                query += "&sign=\(SMSForwardingSigning.urlEncodedQueryValue(sign))"
            }
            guard let url = URL(string: "https://oapi.dingtalk.com/robot/send?\(query)") else {
                throw DeliveryError.invalidURL
            }
            request = URLRequest(url: url)
        case .telegram:
            let token = secrets.token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw DeliveryError.missingConfiguration }
            guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else {
                throw DeliveryError.invalidURL
            }
            request = URLRequest(url: url)
        case .qqPrivate, .qqGroup:
            let base = secrets.url.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasSuffix("/") ? String(secrets.url.trimmingCharacters(in: .whitespacesAndNewlines).dropLast()) : secrets.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else { throw DeliveryError.missingConfiguration }
            let endpoint = kind == .qqPrivate ? "send_private_msg" : "send_group_msg"
            guard let url = URL(string: "\(base)/\(endpoint)") else {
                throw DeliveryError.invalidURL
            }
            request = URLRequest(url: url)
            let accessToken = secrets.token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !accessToken.isEmpty {
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }
        }

        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        for header in parsedHeaders(secrets.headers) {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        return request
    }

    /// Feishu signing needs the JSON payload as a dictionary, so the final
    /// body for that kind is re-serialized after injecting timestamp/sign.
    static func body(
        for kind: ForwardingChannelKind,
        secrets: ForwardingChannelSecrets,
        rendered: String
    ) throws -> String {
        guard kind == .feishu else { return rendered }
        let secret = secrets.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty,
              var object = (try? JSONSerialization.jsonObject(with: Data(rendered.utf8))) as? [String: Any] else {
            return rendered
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        object["timestamp"] = String(timestamp)
        object["sign"] = SMSForwardingSigning.feishuSign(
            secret: secret,
            timestampSeconds: timestamp
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? rendered
    }

    static func parsedHeaders(_ text: String) -> [(name: String, value: String)] {
        text
            .split(separator: "\n")
            .compactMap { line -> (String, String)? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !value.isEmpty else { return nil }
                return (name, value)
            }
    }

    /// Blocking send used from `deliver`'s detached-task context. Semaphores
    /// here are safe because the caller is always a background Task, never
    /// the main thread.
    private static func sendSynchronously(_ request: URLRequest) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var receivedData: Data?
        var receivedResponse: URLResponse?
        var transportError: Error?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            receivedData = data
            receivedResponse = response
            transportError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        if let transportError {
            throw DeliveryError.transport(transportError.localizedDescription)
        }
        guard let httpResponse = receivedResponse as? HTTPURLResponse else {
            throw DeliveryError.transport(L10n.tr("无效的服务端响应"))
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = String(data: receivedData ?? Data(), encoding: .utf8) ?? ""
            throw DeliveryError.transport(L10n.tr("HTTP %d：%@", httpResponse.statusCode, body))
        }
    }

    // MARK: - Test send (settings UI)

    func sendTest(
        channel: ForwardingChannel,
        event: ForwardingEventType
    ) async -> Result<Void, Error> {
        let store = NotificationForwardingStore.shared
        let secrets = await MainActor.run { store.secrets(for: channel) }
        let context = ForwardingEventContext(
            type: event,
            title: L10n.tr("[CellDockPlus] 测试推送"),
            content: L10n.tr("这是一条来自 CellDockPlus 通知转发功能的测试消息。"),
            sender: "10086",
            operatorName: nil,
            signal: nil,
            moduleName: nil,
            direction: nil,
            duration: nil
        )
        let rendered = NotificationTemplateRenderer.render(
            template: channel.template(for: event) ?? "",
            variables: context.variables.merging(["target": secrets.target]) { _, new in new },
            channelKind: channel.kind,
            event: event
        )
        return await Task.detached(priority: .utility) {
            Self.deliver(kind: channel.kind, secrets: secrets, rendered: rendered)
        }.value
    }
}
