import SwiftUI

/// 查看器里的一页：一张图片，或 PDF 的一页（PDF 在查看器里按页当作图片浏览，DESIGN.md §8.3）。
/// 打开时从 Photo 抄下要用的值 —— 查看器里删除照片后，被删的 Photo 不能再访问
struct ViewerItem: Identifiable, Hashable {
    let photoID: UUID
    /// PDF 的页（从 0 起）；图片为 nil
    let page: Int?
    /// PDF 总页数（图片为 0）
    let pageCount: Int
    /// 宽 / 高
    let aspectRatio: CGFloat
    /// 矢量页：查看器放大时分块矢量重绘
    let isVectorPage: Bool
    /// 编辑（裁剪）次数：变了就是新的一页，查看器重新加载
    let revision: Int

    /// 轻量标识（不要拼字符串）：翻页器 / 胶片条每次刷新都要把所有页的 id 算一遍并比较，
    /// 拼字符串在几千张的图库里每次刷新多花几毫秒，翻页时一卡一卡（实测）
    struct ID: Hashable {
        let photoID: UUID
        let page: Int
        let revision: Int
    }

    var id: ID {
        ID(photoID: photoID, page: page ?? -1, revision: revision)
    }

    /// PDF 页按顺序展开；图片一张一项
    @MainActor
    static func items(for photos: [Photo]) -> [ViewerItem] {
        photos.flatMap { items(for: $0) }
    }

    @MainActor
    static func items(for photo: Photo) -> [ViewerItem] {
        let photoAspect = photo.height > 0 ? CGFloat(photo.width) / CGFloat(photo.height) : 1
        guard photo.isPDF else {
            return [ViewerItem(photoID: photo.id, page: nil, pageCount: 0, aspectRatio: photoAspect,
                               isVectorPage: false, revision: photo.editRevision)]
        }
        let pages = PDFPageStore.shared.pages(photoID: photo.id)
        guard !pages.isEmpty else {
            return [ViewerItem(photoID: photo.id, page: 0, pageCount: 1, aspectRatio: photoAspect,
                               isVectorPage: true, revision: photo.editRevision)]
        }
        return pages.enumerated().map { index, info in
            ViewerItem(photoID: photo.id, page: index, pageCount: pages.count, aspectRatio: info.aspectRatio,
                       isVectorPage: info.kind == .vector, revision: photo.editRevision)
        }
    }

    // MARK: 图片

    /// 内存缓存里已有的图（同步，过渡动画用）。PDF 首页退回整份 PDF 的缩略图（就是首页渲染的）
    func cachedImage(_ kind: ThumbnailKind) -> UIImage? {
        let cache = ThumbnailCache.shared
        guard let page else {
            return cache.cachedImage(for: photoID, kind: kind)
        }
        if let image = cache.cachedPageImage(photoID: photoID, page: page, kind: kind) {
            return image
        }
        return page == 0 ? cache.cachedImage(for: photoID, kind: kind) : nil
    }

    func image(_ kind: ThumbnailKind) async -> UIImage? {
        guard let page else {
            return await ThumbnailCache.shared.image(for: photoID, kind: kind)
        }
        return await ThumbnailCache.shared.pageImage(photoID: photoID, page: page, kind: kind)
    }
}
