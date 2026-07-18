#if DEBUG
import SwiftData
import SwiftUI

/// 调试辅助：以 SEED_DEMO=1 启动且图库为空时，生成一批示例图片并走完整导入管线
/// （落盘 + 缩略图 + 入库），用于无 UI 交互的端到端验证。
@MainActor
enum DebugSeeder {
    /// SLOW_ANIM=1 时把窗口动画放慢 ~8 倍，便于逐帧截图验证过渡动画
    static func applyLaunchTweaks() {
        guard ProcessInfo.processInfo.environment["SLOW_ANIM"] == "1" else { return }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.layer.speed = 0.12
            }
        }
    }

    static func seedIfRequested(context: ModelContext) async {
        guard ProcessInfo.processInfo.environment["SEED_DEMO"] == "1" else { return }

        if (try? context.fetchCount(FetchDescriptor<Photo>())) ?? 0 == 0 {
            let sampleCount = 18
            for index in 0..<sampleCount {
                let data = renderSampleImage(index: index, of: sampleCount)
                let photoID = UUID()
                guard let stored = try? ImageStore.shared.store(data: data, photoID: photoID) else { continue }

                let photo = Photo()
                photo.id = photoID
                photo.contentHash = ImageStore.contentHash(of: data)
                photo.fileRelativePath = stored.relativePath
                photo.width = stored.width
                photo.height = stored.height
                photo.originalFilename = "sample-\(index + 1).jpg"
                context.insert(photo)
            }
        }

        if (try? context.fetchCount(FetchDescriptor<Album>())) ?? 0 == 0 {
            let photos = (try? context.fetch(FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
            let album = AlbumOperations.createAlbum(named: "示例角色", in: context)
            AlbumOperations.add(Array(photos.prefix(6)), to: album, in: context)
        }

        try? context.save()
    }

    private static func renderSampleImage(index: Int, of count: Int) -> Data {
        let size = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { renderContext in
            UIColor(hue: CGFloat(index) / CGFloat(count), saturation: 0.55, brightness: 0.9, alpha: 1).setFill()
            renderContext.fill(CGRect(origin: .zero, size: size))

            let text = "\(index + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 180, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                withAttributes: attributes)
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
}
#endif
