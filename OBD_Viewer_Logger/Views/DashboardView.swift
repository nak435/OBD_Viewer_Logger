import CoreLocation
import SwiftUI

// モニター画面。ino の buildDashScreen()/タイル表示 相当。
// 上段：ゲートウェイとの通信状態（接続 / 最終応答からの経過秒）
// 下段：PIDごとのタイル（ino と同様 1PID=1タイル）。値が取れれば数値、
//       車から応答がなければ "N/A" 等をタイル内に表示する
struct DashboardView: View {
    @EnvironmentObject var ble: GatewayBLEManager

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            // 1秒ごとに再描画し、「N秒前」表示と鮮度の色を更新する
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        statusHeader(now: context.date)

                        if !ble.pidResponses.isEmpty {
                            LazyVGrid(columns: columns, spacing: 12) {
                                // PID選択画面・inoと同じ並び（PidCatalogの宣言順）
                                ForEach(PidCatalog.all.map(\.pid).filter { ble.pidResponses[$0] != nil }, id: \.self) { pid in
                                    if let r = ble.pidResponses[pid] {
                                        pidTile(pid: pid, response: r, now: context.date)
                                    }
                                }
                            }
                        }

                        if ble.pidResponses.isEmpty {
                            Text(ble.isRunning ? "Waiting for data..." : "PID選択画面で Start してください")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Dashboard")
        }
    }

    // MARK: - 部品

    private func statusHeader(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row(ok: ble.isConnected,
                text: ble.isConnected ? "Gateway: Connected" : "Gateway: Disconnected")
            if let last = ble.lastResponseAt {
                let age = max(0, now.timeIntervalSince(last))
                row(ok: age < 3,
                    text: String(format: "Last response: %.0f s ago", age))
            } else {
                row(ok: false, text: ble.isRunning ? "Last response: none yet" : "Monitoring stopped")
            }
            GPSRow(location: ble.location)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(ok: Bool, text: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(ok ? Color.green : Color.gray).frame(width: 10, height: 10)
            Text(text).foregroundStyle(ok ? .primary : .secondary)
        }
    }

    /// PID1個分のタイル。値があれば数値（複数値のPIDは行を分ける）、無ければ N/A 等。
    /// 直近1.5秒以内の更新なら緑、それ以外は灰（ino の鮮度表示と同じ閾値）。
    private func pidTile(pid: UInt8, response: GatewayBLEManager.PidResponse, now: Date) -> some View {
        let name = PidCatalog.byPid[pid]?.name ?? "?"
        let fresh = now.timeIntervalSince(response.at) < 1.5
        let fields = response.fields
        let single = fields.count == 1

        return VStack(alignment: .leading, spacing: 4) {
            // 単一値: フィールド名(単位付き)をキャプションに。複数値・N/A: PID名
            Text(single ? fields[0].name : String(format: "0x%02X %@", pid, name))
                .font(.caption).foregroundStyle(.secondary)

            if fields.isEmpty {
                // 車のECUから応答なし(N/A)など。応答が成功でも値が取れない場合もN/A扱い
                Text(response.isOK ? "N/A" : response.statusLabel)
                    .font(.title2.bold())
                    .foregroundStyle(fresh ? Color.orange : Color.secondary)
            } else if single {
                Text(String(format: "%.2f", fields[0].value))
                    .font(.title2.bold())
                    .foregroundStyle(fresh ? Color.green : Color.secondary)
            } else {
                ForEach(fields, id: \.name) { f in
                    HStack {
                        Text(f.name).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f", f.value))
                            .font(.headline)
                            .foregroundStyle(fresh ? Color.green : Color.secondary)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// GPS(CoreLocation)の状態表示。位置が取れていれば緯度経度、無ければ "-"
private struct GPSRow: View {
    @ObservedObject var location: LocationManager

    var body: some View {
        let fix = location.currentFix()
        HStack(spacing: 8) {
            Circle().fill(fix != nil ? Color.green : Color.gray).frame(width: 10, height: 10)
            Text(text(fix)).foregroundStyle(fix != nil ? .primary : .secondary)
        }
    }

    private func text(_ fix: CLLocation?) -> String {
        if let fix {
            return String(format: "GPS: %.6f, %.6f", fix.coordinate.latitude, fix.coordinate.longitude)
        }
        switch location.authorization {
        case .denied, .restricted: return "GPS: 位置情報の許可が必要です（設定アプリ）"
        default: return "GPS: -"
        }
    }
}
