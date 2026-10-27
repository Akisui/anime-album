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
    /// 隐藏相簿：只隐藏相簿本身（相簿列表里不显示），不影响其中照片
    var isHidden: Bool = false

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

    /// 封面：指定的那张，否则排第一的那张（只扫一遍找最小，不整体排序 —— 相簿列表每张卡片都要取）。
    /// 不含隐藏照片时跳过隐藏的（隐藏照片不能出现在封面上）
    func coverPhoto(includingHidden: Bool) -> Photo? {
        let entries = entries ?? []
        if let coverPhotoID,
           let match = entries.lazy.compactMap(\.photo).first(where: { $0.id == coverPhotoID }),
           includingHidden || !match.isHidden {
            return match
        }
        return entries
            .compactMap { entry in entry.photo.map { (entry.sortIndex, $0) } }
            .filter { includingHidden || !$0.1.isHidden }
            .min { $0.0 < $1.0 }?.1
    }

    func photoCount(includingHidden: Bool) -> Int {
        let entries = entries ?? []
        guard !includingHidden else { return entries.count }
        return entries.lazy.filter { $0.photo?.isHidden == false }.count
    }
}
