import SwiftUI
import UIKit

@main
struct OBD_Viewer_LoggerApp: App {
    // ★アプリ全体で単一インスタンス。バックグラウンド復帰(state restoration)時も
    //   同一インスタンスが再利用されるよう、Appのプロパティとして保持する。
    @StateObject private var ble = GatewayBLEManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        RealmManager.configure() // 他のRealm利用より前に、デフォルト設定(マイグレーション)を確定する

        // ── アプリログ（実車テストでXcodeのコンソールが使えないため、Realmへ記録する）──
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))"
        // appState=background で起動していれば、iOSがBLE等のイベントでバックグラウンド起動した証拠
        RealmManager.logEvent("APP", "launched v\(version), appState=\(Self.name(UIApplication.shared.applicationState)), lowPowerMode=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")

        // 終了直前（プロセスが落ちる前に書き切る必要があるため同期書き込み）。
        // ※iOSがサスペンド中のアプリを強制終了する場合は通知されない（＝次回起動時に
        //   直前のログが background で終わっていれば、その可能性が高い）。
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification,
                                               object: nil, queue: nil) { _ in
            RealmManager.logEvent("APP", "willTerminate", sync: true)
        }
        // メモリ逼迫はiOSによる終了(jetsam)の前兆になる
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: nil) { _ in
            RealmManager.logEvent("APP", "memory warning")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
        }
        .onChange(of: scenePhase) { old, new in
            RealmManager.logEvent("APP", "scenePhase \(Self.name(old)) -> \(Self.name(new))")
        }
    }

    private static func name(_ p: ScenePhase) -> String {
        switch p {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private static func name(_ s: UIApplication.State) -> String {
        switch s {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}
