#if DEBUG
import SwiftData
import SwiftUI

/// 调试辅助：以 SEED_DEMO=1 启动且图库为空时，生成一批示例图片并走完整导入管线
/// （落盘 + 缩略图 + 入库），用于无 UI 交互的端到端验证。
@MainActor
enum DebugSeeder {
    /// SLOW_ANIM=1 时把窗口动画放慢 ~8 倍，便于逐帧截图验证过渡动画
    static func applyLaunchTweaks() {
        // READING_ORDER=leftToRight|rightToLeft|topToBottom|continuous：查看器的查看顺序
        if let order = ProcessInfo.processInfo.environment["READING_ORDER"] {
            UserDefaults.standard.set(order, forKey: "viewerReadingOrder")
        }
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
            // SEED_COUNT 可覆盖数量（如 6 张验证"不满一屏"的布局）
            let sampleCount = ProcessInfo.processInfo.environment["SEED_COUNT"]
                .flatMap(Int.init) ?? 18
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

        // SEED_PDF=1 再追加一份 4 页的示例 PDF（前 3 页矢量、第 4 页整页一张图 = 扫描页；走与导入相同的落盘 + 拆页）
        if ProcessInfo.processInfo.environment["SEED_PDF"] == "1",
           ((try? context.fetch(FetchDescriptor<Photo>())) ?? []).allSatisfy({ !$0.isPDF }) {
            let data = renderSamplePDF(pages: 3)
            let photoID = UUID()
            if let stored = try? ImageStore.shared.store(data: data, photoID: photoID) {
                let photo = Photo()
                photo.id = photoID
                photo.contentHash = ImageStore.contentHash(of: data)
                photo.fileRelativePath = stored.relativePath
                photo.width = stored.width
                photo.height = stored.height
                photo.originalFilename = "示例文档.pdf"
                photo.mediaType = Photo.MediaType.pdf.rawValue
                photo.pageCount = stored.pageCount ?? 1
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

    private static func renderSamplePDF(pages: Int) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for page in 1...pages {
                context.beginPage()
                UIColor(hue: CGFloat(page) / CGFloat(pages + 1), saturation: 0.35, brightness: 0.95, alpha: 1).setFill()
                context.fill(CGRect(x: 40, y: 40, width: bounds.width - 80, height: 220))
                let title = "示例文档 第 \(page) 页" as NSString
                title.draw(at: CGPoint(x: 60, y: 300), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 36, weight: .bold), .foregroundColor: UIColor.black,
                ])
                let body = String(repeating: "角色设定资料 · ", count: 40) as NSString
                body.draw(in: CGRect(x: 60, y: 370, width: bounds.width - 120, height: 400), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.darkGray,
                ])
            }
            // 扫描页：整页只有一张 JPEG
            context.beginPage()
            if let scan = UIImage(data: renderSampleImage(index: 7, of: 18, size: CGSize(width: 1190, height: 1684))) {
                scan.draw(in: bounds)
            }
        }
    }

    private static func renderSampleImage(index: Int, of count: Int, size: CGSize = CGSize(width: 600, height: 600)) -> Data {
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
