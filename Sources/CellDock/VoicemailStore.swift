import Combine
import Foundation

/// Persistence + Focus polling for the voicemail feature. The call-flow
/// itself (auto-answer, record, finalize) lives in `AppState`; this store
/// owns settings, the record list and the detected Focus state.
@MainActor
final class VoicemailStore: ObservableObject {
    static let shared = VoicemailStore()

    @Published private(set) var settings = VoicemailSettings.default
    @Published private(set) var records: [VoicemailRecord] = []
    @Published private(set) var focusState: FocusModeProbe.State = .unknown

    private let defaults: UserDefaults
    private let settingsKey = "VoicemailSettings.v1"
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var focusPollingTimer: Timer?

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        if let data = defaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(VoicemailSettings.self, from: data) {
            settings = decoded
        }
        let directory = AppDataDirectory.userApplicationSupport(fileManager: fileManager)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("voicemails.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode([VoicemailRecord].self, from: data) {
            records = decoded
        }
    }

    var unreadCount: Int {
        records.lazy.filter { !$0.isAcknowledged }.count
    }

    /// Voicemail takes over only when the master switch is on and either the
    /// trigger is unconditional or Focus is *known* to be active. An unknown
    /// Focus state never auto-answers (fail safe).
    var isTakingOverCalls: Bool {
        guard settings.isEnabled else { return false }
        guard settings.followsFocusMode else { return true }
        return focusState == .active
    }

    func updateSettings(_ newSettings: VoicemailSettings) {
        settings = newSettings
        defaults.set(try? JSONEncoder().encode(settings), forKey: settingsKey)
    }

    func append(_ record: VoicemailRecord) {
        records.insert(record, at: 0)
        persist()
    }

    func acknowledge(_ id: VoicemailRecord.ID) {
        guard let index = records.firstIndex(where: { $0.id == id }),
              !records[index].isAcknowledged else {
            return
        }
        records[index].isAcknowledged = true
        persist()
    }

    func remove(_ id: VoicemailRecord.ID) {
        records.removeAll { $0.id == id }
        persist()
    }

    func startFocusPolling() {
        guard focusPollingTimer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let state = FocusModeProbe.currentState()
                if state != self.focusState {
                    self.focusState = state
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        focusPollingTimer = timer
        focusState = FocusModeProbe.currentState()
    }

    private func persist() {
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
