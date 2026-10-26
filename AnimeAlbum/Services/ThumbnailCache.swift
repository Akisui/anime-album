import Foundation
import UIKit

/// 解码后缩略图的内存缓存；磁盘读取与解码在全局并发执行器上进行，不阻塞主线程。
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    func image(for photoID: UUID, kind: ThumbnailKind, store: ImageStore = .shared) async -> UIImage? {
        let key = cacheKey(photoID: photoID, kind: kind)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let loaded: UIImage?
        if kind == .tiny {
            loaded = await store.loadTinyThumbnail(photoID: photoID)
        } else {
            await store.ensureThumbnail(photoID: photoID, kind: kind)
            loaded = store.loadThumbnail(photoID: photoID, kind: kind)
        }
        guard let image = loaded else { return nil }
        let pixelCount = Int(image.size.width * image.scale * image.size.height * image.scale)
        cache.setObject(image, forKey: key, cost: pixelCount * 4)
        return image
    }

    /// 仅查内存缓存（同步），过渡动画取当前已解码图用
    func cachedImage(for photoID: UUID, kind: ThumbnailKind) -> UIImage? {
        cache.object(forKey: cacheKey(photoID: photoID, kind: kind))
    }

    // MARK: PDF 页面

    /// PDF 单页图片：tiny 给胶片条；large 给查看器（扫描页最长 4096px，原图更小则原尺寸、无损；
    /// 矢量页按长边 2048 渲染作底图，放大后由查看器分块矢量重绘）
    func pageImage(photoID: UUID, page: Int, kind: ThumbnailKind) async -> UIImage? {
        let key = pageCacheKey(photoID: photoID, page: page, kind: kind)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let store = PDFPageStore.shared
        let maxPixel: Int
        switch kind {
        case .tiny: maxPixel = 240
        case .small: maxPixel = 1024
        case .large:
            let pages = store.pages(photoID: photoID)
            maxPixel = pages.indices.contains(page) && pages[page].kind == .raster ? 4096 : 2048
        }
        guard let image = await store.image(photoID: photoID, page: page, maxPixel: maxPixel) else { return nil }
        let pixelCount = Int(image.size.width * image.scale * image.size.height * image.scale)
        cache.setObject(image, forKey: key, cost: pixelCount * 4)
        return image
    }

    func cachedPageImage(photoID: UUID, page: Int, kind: ThumbnailKind) -> UIImage? {
        cache.object(forKey: pageCacheKey(photoID: photoID, page: page, kind: kind))
    }

    private func pageCacheKey(photoID: UUID, page: Int, kind: ThumbnailKind) -> NSString {
        "\(photoID.uuidString)-p\(page)-\(kind.rawValue)" as NSString
    }

    func evict(photoID: UUID) {
        for kind in ThumbnailKind.allCases {
            cache.removeObject(forKey: cacheKey(photoID: photoID, kind: kind))
        }
    }

    private func cacheKey(photoID: UUID, kind: ThumbnailKind) -> NSString {
        "\(photoID.uuidString)-\(kind.rawValue)" as NSString
    }
}
