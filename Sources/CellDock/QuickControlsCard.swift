import SwiftUI

/// 快捷控制卡 — a phone-control-center style card in the menu bar panel:
/// auto-record, airplane mode and cellular data, each mapped to the exact
/// machinery the settings page and overview card already use.
struct QuickControlsCard: View {
    @EnvironmentObject private var appState: AppState
    let moduleID: CellularModuleID?
    let treatment: AdaptiveGlassTreatment

    @State private var isAirplaneConfirmationPresented = false

    private var displayedModule: CellularModuleSummary? {
        guard let moduleID else { return appState.currentCommunicationModule }
        return appState.cellularModules.first { $0.id == moduleID }
    }

    private var isModuleConnected: Bool {
        displayedModule?.modem.isConnected == true
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label(L10n.tr("快捷控制"), systemImage: "switch.2")
                    .font(.headline)
                Spacer()
            }

            autoRecordToggle
            Divider().opacity(0.55)
            airplaneToggle
            Divider().opacity(0.55)
            cellularDataToggle
        }
        .adaptiveGlassCard(treatment: treatment)
        .confirmationDialog(
            L10n.tr("开启飞行模式？"),
            isPresented: $isAirplaneConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("开启飞行模式"), role: .destructive) {
                appState.toggleAirplaneMode(for: displayedModule?.id)
            }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: {
            Text(L10n.tr("开启后模组射频将关闭，通话、短信和蜂窝数据都会中断，直到你重新关闭飞行模式。"))
        }
    }

    private var autoRecordToggle: some View {
        Toggle(isOn: Binding(
            get: { appState.automaticallyRecordCalls },
            set: { appState.setAutomaticallyRecordCalls($0) }
        )) {
            Label(L10n.tr("自动录音"), systemImage: "record.circle")
        }
        .toggleStyle(.switch)
        .tint(.accentColor)
        .accessibilityIdentifier("QuickControlAutoRecord")
    }

    private var airplaneToggle: some View {
        Toggle(isOn: Binding(
            get: { displayedModule?.modem.isAirplaneModeActive == true },
            set: { shouldEnable in
                if shouldEnable {
                    isAirplaneConfirmationPresented = true
                } else {
                    appState.toggleAirplaneMode(for: displayedModule?.id)
                }
            }
        )) {
            Label(L10n.tr("飞行模式"), systemImage: "airplane")
        }
        .toggleStyle(.switch)
        .tint(.orange)
        .disabled(!isModuleConnected)
        .accessibilityIdentifier("QuickControlAirplaneMode")
    }

    private var cellularDataToggle: some View {
        Toggle(isOn: Binding(
            get: {
                displayedModule.map { appState.networkMode(for: $0.id).isEnabled }
                    ?? appState.presentedCellularNetworkingEnabled
            },
            set: { _ in
                guard let id = displayedModule?.id else { return }
                appState.toggleCellularData(for: id)
            }
        )) {
            Label(L10n.tr("蜂窝数据"), systemImage: "cellularbars")
        }
        .toggleStyle(.switch)
        .tint(.green)
        .disabled(!isModuleConnected)
        .accessibilityIdentifier("QuickControlCellularData")
    }
}
