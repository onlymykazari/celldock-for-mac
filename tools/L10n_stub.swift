// L10n 直通 stub：仅用于命令行探针工具（build_adb_module_probe.sh / build_adb_probe.sh）。
// App 侧真正实现（本地化 bundle 查询）在 Sources/CellDock/AppLanguage.swift——那里拖着
// SwiftUI 与 AppLanguageController，不适合塞进 CLI 编译单元。CLI 场景下 key 即文案。
// ⚠ 若 AppLanguage.swift 的 L10n API 面变化（新增方法/改签名），这里需要同步。
import Foundation

enum L10n {
    static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        guard !arguments.isEmpty else { return key }
        return String(format: key, arguments: arguments)
    }

    static func error(_ key: String, underlying error: Error) -> String {
        let nsError = error as NSError
        let reference = String(format: "错误代码 %@（%lld）",
                               nsError.domain, Int64(nsError.code))
        return String(format: key, reference)
    }
}
