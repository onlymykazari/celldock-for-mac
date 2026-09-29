import Foundation

/// One captured voicemail message. The audio itself is the M4A file written
/// by `CallRecordingStore` (the answered call IS the recording); this record
/// just tracks number, time, duration and whether the user has seen it.
struct VoicemailRecord: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var number: String
    var timestamp: Date
    var duration: TimeInterval
    var fileName: String
    var callRecordingRecordID: UUID?
    var isAcknowledged = false
}

struct VoicemailSettings: Equatable, Codable {
    /// Feature master switch. When off, nothing ever auto-answers.
    var isEnabled = false
    /// When true, voicemail only takes over while macOS Focus/Do-Not-Disturb
    /// is detected; otherwise it is always active while enabled.
    var followsFocusMode = true
    /// Seconds an incoming call may ring before voicemail answers.
    var answerAfterSeconds: Int = 18
    /// Hard cap for one recorded message.
    var maximumRecordSeconds: Int = 120

    static let `default` = VoicemailSettings()
}

/// Best-effort macOS Focus / Do-Not-Disturb detection.
///
/// macOS exposes no public API for Focus state, so the probe reads the
/// system's DoNotDisturb assertion database under `~/Library/DoNotDisturb`.
/// That file can disappear or become unreadable across OS versions, so every
/// failure surfaces as `.unknown` and callers must fail safe (manual mode
/// only) — the feature never auto-answers on an unknown Focus state.
enum FocusModeProbe {
    enum State: Equatable {
        case active
        case inactive
        case unknown
    }

    static func currentState(fileManager: FileManager = .default) -> State {
        guard let url = assertionsURL(fileManager: fileManager),
              let data = try? Data(contentsOf: url) else {
            return .unknown
        }
        return evaluate(assertionsJSON: data)
    }

    static func assertionsURL(fileManager: FileManager) -> URL? {
        fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json", isDirectory: false)
    }

    /// Parses the assertion database. Any entry whose `assertionType`
    /// mentions "donotdisturb" (covers classic DND and every Focus mode) is
    /// an active suppression assertion. Malformed JSON also reports
    /// `.unknown` so the UI can distinguish "can't know" from "known off".
    static func evaluate(assertionsJSON: Data) -> State {
        guard let object = (try? JSONSerialization.jsonObject(with: assertionsJSON)) as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else {
            return .unknown
        }
        if entries.isEmpty { return .inactive }
        for entry in entries {
            guard let details = entry["assertionDetails"] as? [String: Any],
                  let type = details["assertionType"] as? String else {
                continue
            }
            if type.lowercased().contains("donotdisturb") {
                return .active
            }
        }
        return .inactive
    }
}
