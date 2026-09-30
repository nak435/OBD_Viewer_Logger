import SwiftUI
import UIKit

// 共有シート(AirDrop含む)をUIKitから直接提示する。
// ★SwiftUIの .sheet の中身に UIActivityViewController を入れる方式は、iPadで
//   中身が真っ白のまま表示されない不具合があったため使わない。
enum SharePresenter {
    @MainActor
    static func present(_ items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController else { return }

        var top = root
        while let presented = top.presentedViewController { top = presented }

        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPadではポップオーバー扱い。基準(sourceView)が無いとクラッシュ/非表示になる
        if let popover = vc.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(vc, animated: true)
    }
}
