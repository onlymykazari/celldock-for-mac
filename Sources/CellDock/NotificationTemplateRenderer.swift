import Foundation

/// Renders `{{variable}}` placeholders in request-body templates.
///
/// Two substitution modes, chosen by the template's shape:
/// - JSON mode (template starts with `{`): every substituted value is
///   JSON-string-escaped, so message bodies containing quotes or newlines
///   cannot corrupt the payload.
/// - Plain mode: values are substituted verbatim for non-JSON receivers.
///
/// Defaults exist per channel kind and event, mirroring each service's wire
/// format (Feishu card/text, DingTalk markdown-style text, Telegram
/// sendMessage, Bark JSON, WeCom text, OneBot v11 send_*_msg).
enum NotificationTemplateRenderer {
    static func render(
        template: String,
        variables: [String: String],
        channelKind: ForwardingChannelKind,
        event: ForwardingEventType
    ) -> String {
        let body = template.isEmpty
            ? defaultTemplate(for: channelKind, event: event)
            : template
        let isJSON = body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
        return substitute(body, variables: variables, jsonEscape: isJSON)
    }

    static func defaultTemplate(
        for kind: ForwardingChannelKind,
        event: ForwardingEventType
    ) -> String {
        switch kind {
        case .bark:
            return """
            {
              "title": "{{title}}",
              "body": "{{content}}"
            }
            """
        case .feishu:
            return """
            {
              "msg_type": "text",
              "content": {
                "text": "{{title}}\\n{{content}}"
              }
            }
            """
        case .dingtalk:
            return """
            {
              "msgtype": "text",
              "text": {
                "content": "{{title}}\\n{{content}}"
              }
            }
            """
        case .telegram:
            return """
            {
              "chat_id": "{{target}}",
              "text": "{{title}}\\n{{content}}"
            }
            """
        case .qqPrivate:
            return """
            {
              "user_id": {{target}},
              "message": "{{title}}\\n{{content}}"
            }
            """
        case .qqGroup:
            return """
            {
              "group_id": {{target}},
              "message": "{{title}}\\n{{content}}"
            }
            """
        case .wecom:
            return """
            {
              "msgtype": "text",
              "text": {
                "content": "{{title}}\\n{{content}}"
              }
            }
            """
        case .custom:
            return """
            {
              "event": "{{event}}",
              "title": "{{title}}",
              "content": "{{content}}",
              "sender": "{{sender}}",
              "time": "{{time}}",
              "operator": "{{operator}}"
            }
            """
        }
    }

    static func defaultBodyText(for event: ForwardingEventContext) -> String {
        let parts = [event.title, event.content].filter { !$0.isEmpty }
        return parts.joined(separator: "\n")
    }

    private static let tokenRegex = try? NSRegularExpression(
        pattern: #"\{\{\s*([A-Za-z0-9_]+)\s*\}\}"#
    )

    /// Single-pass substitution: values are never re-scanned, so a message
    /// body containing `{{…}}` cannot loop or re-expand.
    private static func substitute(
        _ template: String,
        variables: [String: String],
        jsonEscape: Bool
    ) -> String {
        guard let regex = tokenRegex else { return template }
        let nsTemplate = template as NSString
        let matches = regex.matches(
            in: template,
            range: NSRange(location: 0, length: nsTemplate.length)
        )
        var result = ""
        var cursor = 0
        for match in matches {
            let tokenRange = match.range
            if tokenRange.location > cursor {
                result += nsTemplate.substring(with: NSRange(location: cursor, length: tokenRange.location - cursor))
            }
            let key = nsTemplate.substring(with: match.range(at: 1))
            let rawValue = variables[key] ?? ""
            result += jsonEscape ? jsonEscaped(rawValue) : rawValue
            cursor = tokenRange.location + tokenRange.length
        }
        if cursor < nsTemplate.length {
            result += nsTemplate.substring(from: cursor)
        }
        return result
    }

    /// Escapes a value for safe placement inside a JSON string literal. Note
    /// `\/` is left alone: forward slashes are legal unescaped in JSON.
    static func jsonEscaped(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped
    }
}
