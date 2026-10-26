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

    /// PDF 单页图片（导入时生成好的预览图）：tiny 给胶片条，其余给查看器（长边 2048；
    /// 放大后矢量页由查看器分块重绘、扫描页换原图）
    func pageImage(photoID: UUID, page: Int, kind: ThumbnailKind) async -> UIImage? {
        let key = pageCacheKey(photoID: photoID, page: page, kind: kind)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let preview: PDFPageStore.PreviewKind = kind == .tiny ? .tiny : .large
        guard let image = await PDFPageStore.shared.previewImage(photoID: photoID, page: page, kind: preview) else {
            return nil
        }
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

    #if DEBUG
    func debugRemoveAll() {
        cache.removeAllObjects()
    }
    #endif

    func evict(photoID: UUID) {
        for kind in ThumbnailKind.allCases {
            cache.removeObject(forKey: cacheKey(photoID: photoID, kind: kind))
        }
    }

    private func cacheKey(photoID: UUID, kind: ThumbnailKind) -> NSString {
        "\(photoID.uuidString)-\(kind.rawValue)" as NSString
    }
}
