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
    /// 媒体类型（DESIGN.md §8.3 V3：PDF）：image / pdf。用字符串存而非枚举，CloudKit 与轻量迁移都友好
    var mediaType: String = Photo.MediaType.image.rawValue
    /// PDF 的页数（图片为 0）
    var pageCount: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \AlbumEntry.photo)
    var entries: [AlbumEntry]?

    init() {}
}

extension Photo {
    enum MediaType: String {
        case image
        case pdf
    }

    var isPDF: Bool {
        mediaType == MediaType.pdf.rawValue
    }
}
