import Foundation
import SwiftData

// CloudKit 兼容约束（DESIGN.md §4.2）：所有属性带默认值、关系可选、无 unique 约束。
@Model
final class Photo {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var originalFilename: String?
    var contentHash: String = ""
    var width: Int = 0
    var height: Int = 0
    var fileRelativePath: String = ""
    /// 媒体类型：image / pdf / video / gif（动图）/ live（实况照片）。用字符串存而非枚举，CloudKit 与轻量迁移都友好
    var mediaType: String = Photo.MediaType.image.rawValue
    /// PDF 的页数（图片为 0）
    var pageCount: Int = 0
    /// 编辑（裁剪 / 复原）次数：变化时网格、封面、查看器重新加载缩略图
    var editRevision: Int = 0
    /// 视频时长（秒）；实况照片为配套视频的时长；其余为 0
    var duration: Double = 0
    /// 实况照片配套视频的相对路径（与原图同目录）；其余为 nil
    var pairedVideoRelativePath: String?

    @Relationship(deleteRule: .cascade, inverse: \AlbumEntry.photo)
    var entries: [AlbumEntry]?

    init() {}
}

extension Photo {
    enum MediaType: String {
        case image
        case pdf
        case video
        /// 动图（GIF 等多帧图）
        case gif
        /// 实况照片：静态原图 + 配套短视频
        case live
    }

    var kind: MediaType {
        MediaType(rawValue: mediaType) ?? .image
    }

    var isPDF: Bool {
        mediaType == MediaType.pdf.rawValue
    }

    var isVideo: Bool {
        mediaType == MediaType.video.rawValue
    }
}
