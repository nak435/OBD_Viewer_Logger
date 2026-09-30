import Foundation
import RealmSwift

// Realmへの書き込みは専用シリアルキューへ寄せる。BLEの受信コールバックは
// メインキュー(CoreBluetoothのdelegateキュー)で動くため、そこから直接
// realm.write()すると受信処理をブロックしうる。writeQueue.async で
// 非同期化し、受信処理自体は速攻で戻れるようにする。
// （ユーザーの過去のバックグラウンドBLEアプリでの知見：「UIを一切更新せず
// データの永続化だけに徹すればバックグラウンドでも途切れない」という設計を踏襲）
enum RealmManager {
    private static let writeQueue = DispatchQueue(label: "com.obdviewerlogger.realm.write")

    /// アプリ起動時に一度だけ呼ぶ（デフォルトRealmの設定）。
    /// schemaVersion 2: 保存形式を long format(PidReading) → 1秒1レコード(LogSample) へ変更。
    /// schemaVersion 3: アプリログ(AppEvent)を追加（追加のみ。既存のLogSampleはそのまま残る）。
    static func configure() {
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            schemaVersion: 3,
            migrationBlock: { migration, oldSchemaVersion in
                if oldSchemaVersion < 2 {
                    migration.deleteData(forType: "PidReading")
                }
            }
        )
    }

    static func write(_ block: @escaping (Realm) -> Void) {
        writeQueue.async {
            autoreleasepool {
                do {
                    let realm = try Realm()
                    try realm.write { block(realm) }
                } catch {
                    print("[RealmManager] write failed: \(error)")
                }
            }
        }
    }

    /// 受信したPID値を「その秒のレコード」へ足し込む（同一秒は横に並ぶ）。
    /// 位置情報はその秒の最新値で上書きする。
    static func record(at date: Date, fields: [PidField], latitude: Double?, longitude: Double?) {
        write { realm in
            let sec = Int(date.timeIntervalSince1970)
            let row = realm.object(ofType: LogSample.self, forPrimaryKey: sec)
                ?? realm.create(LogSample.self, value: ["second": sec])
            if let latitude, let longitude {
                row.latitude = latitude
                row.longitude = longitude
            }
            for f in fields { row.values[f.name] = f.value }
        }
    }

    /// アプリの動作イベントを記録する（任意のスレッドから呼べる）。
    /// sync=true は終了直前(willTerminate)用：非同期だとプロセス終了に間に合わないため。
    static func logEvent(_ category: String, _ message: String, sync: Bool = false) {
        let now = Date()
        let block: () -> Void = {
            autoreleasepool {
                do {
                    let realm = try Realm()
                    try realm.write {
                        let e = AppEvent()
                        e.timestamp = now
                        e.category = category
                        e.message = message
                        realm.add(e)
                    }
                } catch {
                    print("[RealmManager] logEvent failed: \(error)")
                }
            }
        }
        if sync { writeQueue.sync(execute: block) } else { writeQueue.async(execute: block) }
    }

    static func appEventCount() -> Int {
        (try? Realm())?.objects(AppEvent.self).count ?? 0
    }

    static func recordCount() -> Int {
        (try? Realm())?.objects(LogSample.self).count ?? 0
    }

    // MARK: - CSVエクスポート（tab5_obd_monitor.ino のCSVと同じ構成）
    // 列: Time_JST, GPS_Lat[deg], GPS_Lon[deg], elapsed_sec, 以降は取得できたフィールドのみ
    //     （PidCatalogの宣言順）。GPS未取得は "-"、欠測値は空欄（ino と同じ慣例）。
    // includeAppLog=true のときは末尾に AppEvent 列を足し、アプリのイベントを時刻順に
    // 混ぜる。同じ秒のイベントはその秒の行に入り（複数は " | " 区切り）、走行データの
    // 無い時間帯のイベントは、値が空でイベントだけの行として挿入する。
    static func exportCSV(includeAppLog: Bool = false) -> URL? {
        do {
            let realm = try Realm()
            let samples = realm.objects(LogSample.self).sorted(byKeyPath: "second", ascending: true)

            // アプリログを「秒 → イベント文字列」にまとめる
            var eventsBySecond: [Int: String] = [:]
            if includeAppLog {
                let events = realm.objects(AppEvent.self).sorted(byKeyPath: "timestamp", ascending: true)
                for e in events {
                    let sec = Int(e.timestamp.timeIntervalSince1970)
                    let text = "\(e.category): \(e.message)"
                    eventsBySecond[sec] = eventsBySecond[sec].map { $0 + " | " + text } ?? text
                }
            }
            let eventSeconds = eventsBySecond.keys.sorted()

            // 走行データもイベントも無ければ出力するものが無い
            guard samples.first != nil || !eventSeconds.isEmpty else { return nil }
            // elapsed_sec の基準 = 出力する最初の行の秒
            let firstSecond = min(samples.first?.second ?? Int.max, eventSeconds.first ?? Int.max)

            // 1周目: データ中に現れたフィールド名を集める（Tab5の「選択PIDのみ列にする」相当）
            var present = Set<String>()
            for s in samples { for k in s.values.keys { present.insert(k) } }
            var columns = PidCatalog.all.flatMap(\.fieldNames).filter { present.contains($0) }
            columns += present.subtracting(columns).sorted() // カタログに無いキー(将来の互換用)

            let jst = jstFormatter("yyyy-MM-dd HH:mm:ss")

            let stamp = Int(Date().timeIntervalSince1970)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("obd_log_\(stamp).csv")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }

            var headerCols = ["Time_JST", "GPS_Lat[deg]", "GPS_Lon[deg]", "elapsed_sec"] + columns
            if includeAppLog { headerCols.append("AppEvent") }
            try handle.write(contentsOf: Data((headerCols.joined(separator: ",") + "\n").utf8))

            // 2周目: 全件を1つの巨大な文字列にせず、一定件数ごとにファイルへ追記する
            var chunk = ""
            var n = 0
            func flushIfNeeded() throws {
                n += 1
                if n % 1000 == 0 {
                    try handle.write(contentsOf: Data(chunk.utf8))
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            /// 走行データの無い時間帯のイベント行（GPSは"-"、値は全て空欄）
            func eventOnlyRow(_ sec: Int) throws {
                var line = jst.string(from: Date(timeIntervalSince1970: TimeInterval(sec)))
                line += ",-,-,\(sec - firstSecond)"
                line += String(repeating: ",", count: columns.count)
                line += "," + csvEscape(eventsBySecond[sec] ?? "")
                chunk += line + "\n"
                try flushIfNeeded()
            }

            var ei = 0 // eventSeconds の読み取り位置（サンプルと時刻順に併合する）
            for s in samples {
                while ei < eventSeconds.count, eventSeconds[ei] < s.second {
                    try eventOnlyRow(eventSeconds[ei]); ei += 1
                }
                var line = jst.string(from: Date(timeIntervalSince1970: TimeInterval(s.second)))
                if let lat = s.latitude, let lon = s.longitude {
                    line += String(format: ",%.6f,%.6f", lat, lon)
                } else {
                    line += ",-,-"
                }
                line += ",\(s.second - firstSecond)"
                for c in columns {
                    line += ","
                    if let v = s.values[c] { line += format(v) }
                }
                if includeAppLog {
                    line += "," + csvEscape(eventsBySecond[s.second] ?? "")
                    if ei < eventSeconds.count, eventSeconds[ei] == s.second { ei += 1 }
                }
                chunk += line + "\n"
                try flushIfNeeded()
            }
            while ei < eventSeconds.count { try eventOnlyRow(eventSeconds[ei]); ei += 1 }

            if !chunk.isEmpty { try handle.write(contentsOf: Data(chunk.utf8)) }
            return url
        } catch {
            print("[RealmManager] export failed: \(error)")
            return nil
        }
    }

    /// アプリログだけをCSVにする（Time_JST[ミリ秒付き], category, message）
    static func exportAppLogCSV() -> URL? {
        do {
            let realm = try Realm()
            let events = realm.objects(AppEvent.self).sorted(byKeyPath: "timestamp", ascending: true)
            guard !events.isEmpty else { return nil }

            let jst = jstFormatter("yyyy-MM-dd HH:mm:ss.SSS")
            var csv = "Time_JST,category,message\n"
            for e in events {
                csv += "\(jst.string(from: e.timestamp)),\(csvEscape(e.category)),\(csvEscape(e.message))\n"
            }
            let stamp = Int(Date().timeIntervalSince1970)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("obd_applog_\(stamp).csv")
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("[RealmManager] app log export failed: \(error)")
            return nil
        }
    }

    private static func jstFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = format
        return f
    }

    /// カンマ・引用符・改行を含む文字列はCSV規則で "..." に包む
    private static func csvEscape(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 小数4桁までで末尾の0を落とす（790.5 → "790.5"、0.0 → "0"、1.9876 → "1.9876"）
    private static func format(_ v: Double) -> String {
        var s = String(format: "%.4f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func deleteAll() {
        write { realm in
            realm.delete(realm.objects(LogSample.self))
            realm.delete(realm.objects(AppEvent.self))
        }
    }
}
