#if DEBUG
import SwiftData
import SwiftUI

/// 调试辅助：以 SEED_DEMO=1 启动且图库为空时，生成一批示例图片并走完整导入管线
/// （落盘 + 缩略图 + 入库），用于无 UI 交互的端到端验证。
@MainActor
enum DebugSeeder {
    /// SLOW_ANIM=1 时把窗口动画放慢 ~8 倍，便于逐帧截图验证过渡动画
    static func applyLaunchTweaks() {
        // READING_ORDER=leftToRight|topToBottom|continuous：查看器的查看顺序
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

    /// SEED_SHOWCASE=<目录>：图库为空时按子文件夹导入展示用内容（tools/make_showcase.py 生成），每个子文件夹一个相簿
    /// （数字前缀定顺序、导入后去掉；H- 开头的相簿标为隐藏；hidden- 开头的文件标为隐藏照片）。走与「从文件导入」相同的管线
    static func seedShowcase(context: ModelContext) async {
        guard let path = ProcessInfo.processInfo.environment["SEED_SHOWCASE"],
              (try? context.fetchCount(FetchDescriptor<Photo>())) ?? 0 == 0
        else {
            return
        }
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let folders = ((try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let importer = PhotoImporter()
        var imported: [Photo] = []
        for folder in folders {
            let files = ((try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let result = await importer.importFiles(at: files, context: context)
            let folderName = folder.lastPathComponent
            let name = folderName.split(separator: "-", maxSplits: 1).last.map(String.init) ?? folderName
            let album = AlbumOperations.createAlbum(named: name, in: context)
            AlbumOperations.add(result.photos, to: album, in: context)
            album.isHidden = folderName.hasPrefix("H-")
            for photo in result.photos where photo.originalFilename?.hasPrefix("hidden-") == true {
                photo.isHidden = true
            }
            imported += result.photos
        }
        // 图库按导入时间排：打散（固定种子），风景 / 插画 / 视频 / PDF 混在一起，不是一个相簿一大块
        var generator = SeededGenerator(seed: 20261028)
        let now = Date()
        for (index, photo) in imported.shuffled(using: &generator).enumerated() {
            photo.createdAt = now.addingTimeInterval(Double(index - imported.count) * 60)
        }
        try? context.save()
    }

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
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

        // SEED_LIVE=静态图,视频：按实况照片导入一对文件（走与选择器导入相同的存储）
        if let raw = ProcessInfo.processInfo.environment["SEED_LIVE"],
           ((try? context.fetch(FetchDescriptor<Photo>())) ?? []).allSatisfy({ $0.kind != .live }) {
            let parts = raw.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
            if parts.count == 2, let data = try? Data(contentsOf: parts[0]) {
                let photoID = UUID()
                if let stored = try? await ImageStore.shared.storeLivePhoto(photoData: data, videoAt: parts[1], photoID: photoID) {
                    let photo = Photo()
                    photo.id = photoID
                    photo.contentHash = ImageStore.contentHash(of: data)
                    photo.fileRelativePath = stored.relativePath
                    photo.width = stored.width
                    photo.height = stored.height
                    photo.mediaType = stored.mediaType.rawValue
                    photo.duration = stored.duration
                    photo.pairedVideoRelativePath = stored.pairedVideoRelativePath
                    photo.originalFilename = "实况示例.jpg"
                    context.insert(photo)
                }
            }
        }

        // ALBUM_FILL=1：把图库里所有照片加进第一个相簿（造大相簿，复现首次进入卡顿）
        if ProcessInfo.processInfo.environment["ALBUM_FILL"] == "1",
           let album = (try? context.fetch(FetchDescriptor<Album>(sortBy: [SortDescriptor(\.sortIndex)])))?.first {
            let photos = (try? context.fetch(FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
            AlbumOperations.add(photos, to: album, in: context)
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
