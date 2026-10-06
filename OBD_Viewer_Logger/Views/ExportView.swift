import SwiftUI

// エクスポート画面。Realm -> CSV -> 共有シート(AirDrop含む)。
// ino の requestScreenshot/SDカードログ保存に相当する機能をiOS流に置き換えたもの。
struct ExportView: View {
    @State private var isExporting = false
    @State private var showDeleteConfirm = false
    @State private var recordCount = 0
    @State private var appEventCount = 0
    @State private var exportFailed = false

    /// 走行ログのCSVにアプリログ(AppEvent列)を混ぜるか。次回以降も覚えておく
    @AppStorage("exportIncludeAppLog") private var includeAppLog = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 4) {
                    Text("\(recordCount) 行のログ")
                    Text("\(appEventCount) 件のアプリログ")
                }
                .foregroundStyle(.secondary)

                Toggle("アプリログを一緒に出力", isOn: $includeAppLog)
                    .frame(maxWidth: 420)

                Button {
                    let include = includeAppLog // Sendableなクロージャにはコピーを渡す
                    export { RealmManager.exportCSV(includeAppLog: include) }
                } label: {
                    if isExporting {
                        HStack { ProgressView(); Text("Exporting...") }
                    } else {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.borderedProminent)
                // アプリログ込みなら、走行ログが空でもイベントだけ出せる
                .disabled(isExporting || (recordCount == 0 && !(includeAppLog && appEventCount > 0)))

                Button {
                    export { RealmManager.exportAppLogCSV() }
                } label: {
                    Label("Export app log only", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.bordered)
                .disabled(isExporting || appEventCount == 0)

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete all logs", systemImage: "trash")
                }
                .disabled(isExporting || (recordCount == 0 && appEventCount == 0))
            }
            .padding()
            .navigationTitle("Export")
            .onAppear(perform: refreshCounts)
            .confirmationDialog("走行ログとアプリログをすべて削除しますか？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    RealmManager.deleteAll()
                    recordCount = 0
                    appEventCount = 0
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("CSVの作成に失敗しました", isPresented: $exportFailed) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func refreshCounts() {
        recordCount = RealmManager.recordCount()
        appEventCount = RealmManager.appEventCount()
    }

    /// CSV生成は件数が多いと時間がかかるためバックグラウンドで行い、
    /// 完成後にメインで共有シートを出す
    private func export(_ make: @escaping @Sendable () -> URL?) {
        isExporting = true
        RealmManager.logEvent("APP", "export started")
        Task.detached {
            let url = make()
            await MainActor.run {
                isExporting = false
                refreshCounts()
                if let url {
                    SharePresenter.present([url])
                } else {
                    exportFailed = true
                }
            }
        }
    }
}
