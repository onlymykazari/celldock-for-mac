import AppKit
import Combine
import Foundation
import Sparkle

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case beta

    static let defaultsKey = "CellDockUpdateChannel"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stable: return L10n.tr("稳定版")
        case .beta: return L10n.tr("测试版")
        }
    }

    fileprivate var feedURL: String? {
        // CellDockPlus 分叉暂无自己的更新源。返回 nil 禁用 Sparkle，
        // 避免误抓上游 celldock.app 的 appcast 把分叉覆盖回上游版本。
        nil
    }
}

@MainActor
final class UpdaterManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdaterManager()

    private var controller: SPUStandardUpdaterController!

    @Published private(set) var canCheckForUpdates = false
    @Published var channel: UpdateChannel {
        didSet {
            UserDefaults.standard.set(channel.rawValue, forKey: UpdateChannel.defaultsKey)
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var currentVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "—"
        return L10n.tr("版本 %@（构建 %@）", version, build)
    }

    private override init() {
        let storedChannel = UserDefaults.standard.string(forKey: UpdateChannel.defaultsKey)
        channel = UpdateChannel(rawValue: storedChannel ?? "") ?? .stable
        super.init()

        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func start() {
        #if !DEBUG
        controller.startUpdater()
        #endif
    }

    func checkForUpdates() {
        #if !DEBUG
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
        #endif
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated { channel.feedURL }
    }
}
