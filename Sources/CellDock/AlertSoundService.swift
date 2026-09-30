import AVFoundation
import Combine
import Foundation

struct BundledAlertSound: Identifiable, Hashable {
    let id: String
    let displayNameKey: String
    let duration: TimeInterval
    fileprivate let resourceName: String
    fileprivate let resourceExtension: String

    var displayName: String { L10n.tr(displayNameKey) }
}

enum AlertSoundPreviewState {
    case stopped
    case playing
    case paused
}

enum AlertSoundKind: String, CaseIterable, Identifiable {
    case message
    case incomingCall

    var id: Self { self }

    var title: String {
        switch self {
        case .message: return L10n.tr("短信提示音")
        case .incomingCall: return L10n.tr("来电铃声")
        }
    }

    var bundledSounds: [BundledAlertSound] {
        switch self {
        case .message:
            return [
                BundledAlertSound(
                    id: "classic",
                    displayNameKey: "默认提示音",
                    duration: 0.281,
                    resourceName: "bleeps",
                    resourceExtension: "wav"
                ),
                BundledAlertSound(
                    id: "notification-09",
                    displayNameKey: "水滴",
                    duration: 1.152,
                    resourceName: "notification-09",
                    resourceExtension: "mp3"
                ),
                BundledAlertSound(
                    id: "notification-010",
                    displayNameKey: "清脆",
                    duration: 1.272,
                    resourceName: "notification-010",
                    resourceExtension: "mp3"
                ),
                BundledAlertSound(
                    id: "ping",
                    displayNameKey: "消息脉冲",
                    duration: 1.128,
                    resourceName: "message-ping",
                    resourceExtension: "mp3"
                )
            ]
        case .incomingCall:
            return [
                BundledAlertSound(
                    id: "classic",
                    displayNameKey: "经典铃声",
                    duration: 42.318,
                    resourceName: "ring",
                    resourceExtension: "mp3"
                ),
                BundledAlertSound(
                    id: "ringtone-023",
                    displayNameKey: "晨曦",
                    duration: 6.922,
                    resourceName: "ringtone-023",
                    resourceExtension: "mp3"
                ),
                BundledAlertSound(
                    id: "ringtone-030",
                    displayNameKey: "涟漪",
                    duration: 7.758,
                    resourceName: "ringtone-030",
                    resourceExtension: "mp3"
                ),
                BundledAlertSound(
                    id: "ringtone-043",
                    displayNameKey: "星河",
                    duration: 8.803,
                    resourceName: "ringtone-043",
                    resourceExtension: "mp3"
                ),
                BundledAlertSound(
                    id: "ringtone-088",
                    displayNameKey: "远航",
                    duration: 8.688,
                    resourceName: "ringtone-088",
                    resourceExtension: "mp3"
                )
            ]
        }
    }

    fileprivate var defaultBundledSound: BundledAlertSound { bundledSounds[0] }

    fileprivate var customFileKey: String {
        "CellDock.AlertSound.\(rawValue).customFile.v1"
    }

    fileprivate var customDisplayNameKey: String {
        "CellDock.AlertSound.\(rawValue).displayName.v1"
    }

    fileprivate var bundledSoundKey: String {
        "CellDock.AlertSound.\(rawValue).bundledSound.v1"
    }
}

enum AlertSoundServiceError: LocalizedError {
    case bundledSoundMissing(String)
    case invalidAudio

    var errorDescription: String? {
        switch self {
        case let .bundledSoundMissing(fileName):
            return L10n.tr("应用内置声音 %@ 不存在，请重新安装 CellDockPlus。", fileName)
        case .invalidAudio:
            return L10n.tr("无法读取该音频文件，请选择 macOS 支持的音频格式。")
        }
    }
}

@MainActor
final class AlertSoundService: ObservableObject {
    static let shared = AlertSoundService()

    @Published private(set) var configurationRevision = 0
    @Published private(set) var previewingKind: AlertSoundKind?
    @Published private(set) var previewingSoundID: String?
    @Published private(set) var previewState: AlertSoundPreviewState = .stopped

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private var messagePlayer: AVAudioPlayer?
    private var ringtonePlayer: AVAudioPlayer?
    private var outgoingRingbackPlayer: AVAudioPlayer?
    private var hangupPlayer: AVAudioPlayer?
    private var previewPlayer: AVAudioPlayer?
    private var previewStopTask: Task<Void, Never>?
    private var previewGeneration = UUID()

    private init() {}

    func displayName(for kind: AlertSoundKind) -> String {
        _ = configurationRevision
        if customSoundURL(for: kind) != nil {
            return defaults.string(forKey: kind.customDisplayNameKey) ?? L10n.tr("自定义音频")
        }
        return selectedBundledSound(for: kind).displayName
    }

    func isUsingDefault(_ kind: AlertSoundKind) -> Bool {
        _ = configurationRevision
        return customSoundURL(for: kind) == nil &&
            selectedBundledSound(for: kind).id == kind.defaultBundledSound.id
    }

    func selectedBundledSoundID(for kind: AlertSoundKind) -> String? {
        _ = configurationRevision
        guard customSoundURL(for: kind) == nil else { return nil }
        return selectedBundledSound(for: kind).id
    }

    func hasCustomSound(for kind: AlertSoundKind) -> Bool {
        _ = configurationRevision
        return customSoundURL(for: kind) != nil
    }

    func customSoundDuration(for kind: AlertSoundKind) -> TimeInterval? {
        guard let url = customSoundURL(for: kind),
              let player = try? AVAudioPlayer(contentsOf: url),
              player.duration.isFinite else { return nil }
        return player.duration
    }

    func selectBundledSound(_ sound: BundledAlertSound, for kind: AlertSoundKind) throws {
        guard kind.bundledSounds.contains(sound) else { return }
        guard let url = bundledSoundURL(sound),
              let validationPlayer = makePlayer(url: url, numberOfLoops: 0) else {
            throw AlertSoundServiceError.bundledSoundMissing(
                "\(sound.resourceName).\(sound.resourceExtension)"
            )
        }
        validationPlayer.stop()

        let previousURL = customSoundURL(for: kind)
        let wasRinging = kind == .incomingCall && ringtonePlayer?.isPlaying == true
        stopPreview()
        if kind == .incomingCall {
            stopIncomingRingtone()
        }
        defaults.set(sound.id, forKey: kind.bundledSoundKey)
        defaults.removeObject(forKey: kind.customFileKey)
        defaults.removeObject(forKey: kind.customDisplayNameKey)
        configurationRevision &+= 1
        if let previousURL {
            try? fileManager.removeItem(at: previousURL)
        }
        if wasRinging {
            startIncomingRingtone()
        }
    }

    func playMessageAlert() {
        guard let url = soundURL(for: .message) else { return }
        messagePlayer?.stop()
        messagePlayer = makePlayer(url: url, numberOfLoops: 0)
        messagePlayer?.play()
    }

    func startIncomingRingtone() {
        guard ringtonePlayer?.isPlaying != true,
              let url = soundURL(for: .incomingCall) else { return }
        stopOutgoingRingback()
        hangupPlayer?.stop()
        hangupPlayer = nil
        ringtonePlayer = makePlayer(url: url, numberOfLoops: -1)
        ringtonePlayer?.play()
    }

    func stopIncomingRingtone() {
        ringtonePlayer?.stop()
        ringtonePlayer = nil
    }

    func startOutgoingRingback() {
        guard outgoingRingbackPlayer?.isPlaying != true else { return }
        stopIncomingRingtone()
        hangupPlayer?.stop()
        hangupPlayer = nil
        outgoingRingbackPlayer = makePlayer(
            data: CallToneSynthesizer.wavData(for: .outgoingRingback),
            numberOfLoops: -1
        )
        outgoingRingbackPlayer?.play()
    }

    func stopOutgoingRingback() {
        outgoingRingbackPlayer?.stop()
        outgoingRingbackPlayer = nil
    }

    func playHangupTone() {
        stopOutgoingRingback()
        stopIncomingRingtone()
        hangupPlayer?.stop()
        hangupPlayer = makePlayer(
            data: CallToneSynthesizer.wavData(for: .hangup),
            numberOfLoops: 0
        )
        hangupPlayer?.play()
    }

    func stopAll() {
        messagePlayer?.stop()
        messagePlayer = nil
        stopIncomingRingtone()
        stopOutgoingRingback()
        hangupPlayer?.stop()
        hangupPlayer = nil
        stopPreview()
    }

    func togglePreview(for kind: AlertSoundKind) throws {
        if let customURL = customSoundURL(for: kind) {
            try togglePreview(for: kind, soundID: "__custom__", url: customURL)
        } else {
            try togglePreview(for: kind, sound: selectedBundledSound(for: kind))
        }
    }

    func togglePreview(for kind: AlertSoundKind, sound: BundledAlertSound) throws {
        guard kind.bundledSounds.contains(sound), let url = bundledSoundURL(sound) else {
            throw AlertSoundServiceError.bundledSoundMissing(
                "\(sound.resourceName).\(sound.resourceExtension)"
            )
        }
        try togglePreview(for: kind, soundID: sound.id, url: url)
    }

    func toggleCustomPreview(for kind: AlertSoundKind) throws {
        guard let url = customSoundURL(for: kind) else {
            throw AlertSoundServiceError.invalidAudio
        }
        try togglePreview(for: kind, soundID: "__custom__", url: url)
    }

    func isPreviewPlaying(kind: AlertSoundKind, soundID: String) -> Bool {
        previewingKind == kind && previewingSoundID == soundID && previewState == .playing
    }

    private func togglePreview(for kind: AlertSoundKind, soundID: String, url: URL) throws {
        if previewingKind == kind, previewingSoundID == soundID, let previewPlayer {
            if previewState == .playing {
                previewPlayer.pause()
                previewStopTask?.cancel()
                previewStopTask = nil
                previewState = .paused
            } else {
                guard previewPlayer.play() else { throw AlertSoundServiceError.invalidAudio }
                previewState = .playing
                schedulePreviewStop()
            }
            return
        }

        stopPreview()
        guard let player = makePlayer(url: url, numberOfLoops: 0) else {
            throw AlertSoundServiceError.invalidAudio
        }

        previewPlayer = player
        previewingKind = kind
        previewingSoundID = soundID
        previewState = .playing
        previewGeneration = UUID()
        player.play()

        schedulePreviewStop()
    }

    private func schedulePreviewStop() {
        guard let player = previewPlayer else { return }
        previewStopTask?.cancel()
        let generation = previewGeneration
        let previewDuration = min(max(player.duration - player.currentTime, 0.25), 8)
        previewStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(previewDuration * 1_000_000_000)
            )
            guard !Task.isCancelled,
                  let self,
                  self.previewGeneration == generation else { return }
            self.stopPreview()
        }
    }

    func installCustomSound(from sourceURL: URL, for kind: AlertSoundKind) throws {
        let accessedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let validationPlayer = try? AVAudioPlayer(contentsOf: sourceURL),
              validationPlayer.duration.isFinite,
              validationPlayer.duration > 0 else {
            throw AlertSoundServiceError.invalidAudio
        }

        let directory = customSoundsDirectory
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileExtension = sourceURL.pathExtension.isEmpty
            ? "audio"
            : sourceURL.pathExtension.lowercased()
        let destination = directory.appendingPathComponent(
            "\(kind.rawValue)-\(UUID().uuidString).\(fileExtension)",
            isDirectory: false
        )
        try fileManager.copyItem(at: sourceURL, to: destination)

        guard let copiedPlayer = try? AVAudioPlayer(contentsOf: destination),
              copiedPlayer.duration.isFinite,
              copiedPlayer.duration > 0 else {
            try? fileManager.removeItem(at: destination)
            throw AlertSoundServiceError.invalidAudio
        }

        let previousURL = customSoundURL(for: kind)
        let wasRinging = kind == .incomingCall && ringtonePlayer?.isPlaying == true
        stopPreview()
        if kind == .incomingCall {
            stopIncomingRingtone()
        }
        defaults.set(destination.lastPathComponent, forKey: kind.customFileKey)
        defaults.set(sourceURL.lastPathComponent, forKey: kind.customDisplayNameKey)
        configurationRevision &+= 1

        if let previousURL, previousURL != destination {
            try? fileManager.removeItem(at: previousURL)
        }
        if wasRinging {
            startIncomingRingtone()
        }
    }

    func restoreDefault(for kind: AlertSoundKind) {
        let previousURL = customSoundURL(for: kind)
        let wasRinging = kind == .incomingCall && ringtonePlayer?.isPlaying == true
        stopPreview()
        if kind == .incomingCall {
            stopIncomingRingtone()
        }
        defaults.removeObject(forKey: kind.customFileKey)
        defaults.removeObject(forKey: kind.customDisplayNameKey)
        defaults.removeObject(forKey: kind.bundledSoundKey)
        configurationRevision &+= 1
        if let previousURL {
            try? fileManager.removeItem(at: previousURL)
        }
        if wasRinging {
            startIncomingRingtone()
        }
    }

    func stopPreview() {
        previewStopTask?.cancel()
        previewStopTask = nil
        previewPlayer?.stop()
        previewPlayer = nil
        previewingKind = nil
        previewingSoundID = nil
        previewState = .stopped
        previewGeneration = UUID()
    }

    private func makePlayer(url: URL, numberOfLoops: Int) -> AVAudioPlayer? {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        return prepare(player, numberOfLoops: numberOfLoops)
    }

    private func makePlayer(data: Data, numberOfLoops: Int) -> AVAudioPlayer? {
        guard let player = try? AVAudioPlayer(data: data) else { return nil }
        return prepare(player, numberOfLoops: numberOfLoops)
    }

    private func prepare(_ player: AVAudioPlayer, numberOfLoops: Int) -> AVAudioPlayer? {
        player.numberOfLoops = numberOfLoops
        player.volume = 1
        guard player.prepareToPlay() else { return nil }
        return player
    }

    private func soundURL(for kind: AlertSoundKind) -> URL? {
        customSoundURL(for: kind) ?? bundledSoundURL(selectedBundledSound(for: kind))
    }

    private func selectedBundledSound(for kind: AlertSoundKind) -> BundledAlertSound {
        guard let selectedID = defaults.string(forKey: kind.bundledSoundKey),
              let selected = kind.bundledSounds.first(where: { $0.id == selectedID }) else {
            return kind.defaultBundledSound
        }
        return selected
    }

    private func bundledSoundURL(_ sound: BundledAlertSound) -> URL? {
        Bundle.main.url(
            forResource: sound.resourceName,
            withExtension: sound.resourceExtension,
            subdirectory: "Sounds"
        )
    }

    private func customSoundURL(for kind: AlertSoundKind) -> URL? {
        guard let fileName = defaults.string(forKey: kind.customFileKey),
              !fileName.isEmpty else { return nil }
        let url = customSoundsDirectory.appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private var customSoundsDirectory: URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
        return applicationSupport
            .appendingPathComponent("CellDockPlus", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
    }
}
