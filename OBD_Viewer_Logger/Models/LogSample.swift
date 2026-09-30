import Foundation
import RealmSwift

// 1秒分のログ = Realm上の1レコード（wide format）。
// tab5_obd_monitor.ino のCSV(1秒1行・PIDが横に並ぶ)と同じ単位で保存する。
// 同一秒に届いた各PIDの値は values に足し込む（RealmManager.record 参照）。
// 値をMapにしているのは、選択PIDの組み合わせや将来のPID追加で列構成が変わっても
// スキーマ変更(マイグレーション)を要さないため。欠測は単にキーが無い（＝CSVでは空欄）。
class LogSample: Object {
    /// エポック秒（1秒に1レコード）。プライマリキーを兼ねる
    @Persisted(primaryKey: true) var second: Int
    /// CoreLocationの測位値。未取得なら nil（CSVでは "-"）
    @Persisted var latitude: Double?
    @Persisted var longitude: Double?
    /// キー = フィールド名（例: "RPM[rpm]"）、値 = 数値
    @Persisted var values: Map<String, Double>
}
