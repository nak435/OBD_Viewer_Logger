import Foundation
import RealmSwift

// アプリの動作イベント（起動・フォアグラウンド/バックグラウンド遷移・BLE接続/切断/再接続など）。
// 実車テストではXcodeのコンソールが使えないため、後からCSVで動作を追跡できるよう
// 走行ログ(LogSample)とは別テーブルにRealmへ保存する。
// 件数は少ない（状態が変わった時だけ記録する。毎秒の処理は記録しない）。
class AppEvent: Object {
    @Persisted(primaryKey: true) var id: ObjectId
    @Persisted var timestamp: Date
    /// 種別。APP=ライフサイクル / BLE=接続 / MON=監視Start/Stop / GPS=位置情報
    @Persisted var category: String
    @Persisted var message: String
}
