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
    var sortedEntries: [AlbumEntry] {
        (entries ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    var sortedPhotos: [Photo] {
        sortedEntries.compactMap(\.photo)
    }

    var coverPhoto: Photo? {
        if let coverPhotoID, let match = sortedPhotos.first(where: { $0.id == coverPhotoID }) {
            return match
        }
        return sortedPhotos.first
    }

    var photoCount: Int {
        entries?.count ?? 0
    }
}
