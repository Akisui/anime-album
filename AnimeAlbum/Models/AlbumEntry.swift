import Foundation
import SwiftData

// 相簿 ↔ 照片 的多对多中间表；sortIndex 采用间隙排序（DESIGN.md §4.4），
// 单次拖动只写一条记录，CloudKit 同步友好。
@Model
final class AlbumEntry {
    var addedAt: Date = Date()
    var sortIndex: Double = 0
    var album: Album?
    var photo: Photo?

    init() {}
}
