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

    func evict(photoID: UUID) {
        for kind in ThumbnailKind.allCases {
            cache.removeObject(forKey: cacheKey(photoID: photoID, kind: kind))
        }
    }

    private func cacheKey(photoID: UUID, kind: ThumbnailKind) -> NSString {
        "\(photoID.uuidString)-\(kind.rawValue)" as NSString
    }
}
