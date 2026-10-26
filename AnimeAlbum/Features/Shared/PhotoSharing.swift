import UIKit

/// 系统分享 Sheet（DESIGN.md §1.3：不做社交流，只用系统分享）。分享原图文件 URL：
/// 系统按图片类型给出「存储图像」「拷贝」等项，且不必先把大图解码进内存
@MainActor
enum PhotoSharing {
    /// sourceRect：窗口坐标里触发分享的位置（iPad 上分享 Sheet 以 popover 从这里弹出）；为 nil 时从屏幕底部中央弹出
    static func share(_ photos: [Photo], sourceRect: CGRect? = nil) {
        // 实况照片连同配套视频一起分享
        let urls = photos.flatMap { photo in
            [photo.fileRelativePath] + (photo.pairedVideoRelativePath.map { [$0] } ?? [])
        }
            .map { ImageStore.shared.url(forRelativePath: $0) }
            .filter { url in
                // iCloud 云盘里还没下载的：发起下载（这次分享不了，下载好后再分享）
                if !FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                    return false
                }
                return true
            }
        guard !urls.isEmpty, let presenter = topViewController() else { return }
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let popover = controller.popoverPresentationController, let window = presenter.view.window {
            popover.sourceView = window
            popover.sourceRect = sourceRect
                ?? CGRect(x: window.bounds.midX, y: window.bounds.maxY - 60, width: 1, height: 1)
        }
        presenter.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
