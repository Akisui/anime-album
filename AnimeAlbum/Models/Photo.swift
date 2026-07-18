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

    @Relationship(deleteRule: .cascade, inverse: \AlbumEntry.photo)
    var entries: [AlbumEntry]?

    init() {}
}
