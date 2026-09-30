import SwiftUI

// PID選択画面。ino の buildSelectScreen() 相当（並べ替え・SDカードUI等はv1では省略）。
struct PidSelectView: View {
    @EnvironmentObject var ble: GatewayBLEManager

    /// Start押下後に呼ばれる（呼び出し側でDashboardタブへ切り替える）
    var onStarted: () -> Void = {}

    // 選択状態はUserDefaultsへ即時保存（ino の savePidSelection/Preferences相当）
    @AppStorage("selectedPIDsCSV") private var selectedPIDsRaw: String = ""
    @State private var selected: Set<UInt8> = []

    // iPadは縦横どちらの向きでも2列、iPhoneは1列
    private var columns: [GridItem] {
        let count = UIDevice.current.userInterfaceIdiom == .pad ? 2 : 1
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // ★接続状態はツールバーではなく本文先頭に置く（iPadでは上部中央のタブバーに
                    //   幅を取られ、左端のツールバー項目が "C..." に切り詰められるため）
                    statusRow

                    HStack(spacing: 12) {
                        Button("Select All") { setAll(true) }
                        Button("Deselect All") { setAll(false) }
                    }
                    .buttonStyle(.bordered)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(PidCatalog.all, id: \.pid) { def in
                            Toggle(isOn: binding(for: def.pid)) {
                                Text(String(format: "0x%02X  %@", def.pid, def.name))
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Select PIDs")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(ble.isRunning ? "Stop" : "Start") {
                        ble.isRunning ? ble.stopMonitoring() : startMonitoring()
                    }
                    .disabled(selected.isEmpty && !ble.isRunning)
                }
            }
        }
        .onAppear(perform: loadSelection)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ble.isConnected ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
            Text(ble.isConnected ? "Gateway: Connected" : "Gateway: Disconnected")
                .foregroundStyle(ble.isConnected ? .green : .secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func binding(for pid: UInt8) -> Binding<Bool> {
        Binding(
            get: { selected.contains(pid) },
            set: { newValue in
                if newValue { selected.insert(pid) } else { selected.remove(pid) }
                applySelection()
            }
        )
    }

    /// 全選択 / 全解除（ino の onSelectAllClicked / onDeselectAllClicked 相当）
    private func setAll(_ on: Bool) {
        selected = on ? Set(PidCatalog.all.map(\.pid)) : []
        applySelection()
    }

    private func applySelection() {
        saveSelection()
        if ble.isRunning { ble.selectedPIDs = selected } // 稼働中でも即時反映
    }

    private func loadSelection() {
        selected = Set(selectedPIDsRaw.split(separator: ",").compactMap { UInt8($0) })
    }

    private func saveSelection() {
        selectedPIDsRaw = selected.map(String.init).joined(separator: ",")
    }

    private func startMonitoring() {
        ble.selectedPIDs = selected
        ble.startMonitoring()
        onStarted()
    }
}
