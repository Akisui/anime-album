import Foundation
import SwiftData

@Model
final class Album {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    var sortIndex: Double = 0
    // 存 ID 而非关系，避免与 AlbumEntry 的反向关系纠缠；为 nil 时封面取排序第一张
    var coverPhotoID: UUID?

    @Relationship(deleteRule: .cascade, inverse: \AlbumEntry.album)
    var entries: [AlbumEntry]?

    init() {}
}

extension Album {
    /// 按 sortIndex 排序。先一次性读出排序值再排：直接在比较里读 entry.sortIndex 的话，每次比较都要经 SwiftData
    /// 取两次属性，1500 张的相簿排一次 100ms+（采样实测）
    var sortedEntries: [AlbumEntry] {
        (entries ?? []).map { ($0.sortIndex, $0) }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    var sortedPhotos: [Photo] {
        sortedEntries.compactMap(\.photo)
    }

    /// 封面：指定的那张，否则排第一的那张（只扫一遍找最小，不整体排序 —— 相簿列表每张卡片都要取）
    var coverPhoto: Photo? {
        let entries = entries ?? []
        if let coverPhotoID, let match = entries.lazy.compactMap(\.photo).first(where: { $0.id == coverPhotoID }) {
            return match
        }
        return entries.map { ($0.sortIndex, $0) }.min { $0.0 < $1.0 }?.1.photo
    }

    var photoCount: Int {
        entries?.count ?? 0
    }
}
