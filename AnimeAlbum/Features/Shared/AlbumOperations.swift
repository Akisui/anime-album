import Foundation
import SwiftData

enum SortIndexing {
    /// 间隙排序步长（DESIGN.md §4.4）：追加 = max + gap，插入 = 相邻两项中点
    static let gap: Double = 1024
}

@MainActor
enum AlbumOperations {
    @discardableResult
    static func createAlbum(named name: String, in context: ModelContext) -> Album {
        var descriptor = FetchDescriptor<Album>(sortBy: [SortDescriptor(\.sortIndex, order: .reverse)])
        descriptor.fetchLimit = 1
        let maxIndex = (try? context.fetch(descriptor))?.first?.sortIndex ?? 0

        let album = Album()
        context.insert(album)
        album.name = name
        album.sortIndex = maxIndex + SortIndexing.gap
        return album
    }

    /// 追加到相簿末尾（已在相簿里的跳过），返回实际新加入的张数
    @discardableResult
    static func add(_ photos: [Photo], to album: Album, in context: ModelContext) -> Int {
        var existingIDs = Set(album.sortedPhotos.map(\.id))
        var index = album.sortedEntries.last?.sortIndex ?? 0
        var added = 0
        for photo in photos where existingIDs.insert(photo.id).inserted {
            added += 1
            index += SortIndexing.gap
            let entry = AlbumEntry()
            context.insert(entry)
            entry.album = album
            entry.photo = photo
            entry.addedAt = .now
            entry.sortIndex = index
        }
        return added
    }

    /// 拖拽排序（DESIGN.md §4.4）：toIndex 为移动后在相簿内的最终位置。
    /// 正常情况取相邻两项 sortIndex 的中点，只写一条记录；
    /// 浮点间隙耗尽（中点撞上邻居）时对该相簿全量重铺。
    static func move(photoID: UUID, toIndex: Int, in album: Album, context: ModelContext) {
        var entries = album.sortedEntries
        guard let fromIndex = entries.firstIndex(where: { $0.photo?.id == photoID }) else { return }
        let moved = entries.remove(at: fromIndex)
        let target = max(0, min(toIndex, entries.count))
        let previous = target > 0 ? entries[target - 1].sortIndex : nil
        let next = target < entries.count ? entries[target].sortIndex : nil

        let newIndex: Double
        switch (previous, next) {
        case let (p?, n?): newIndex = (p + n) / 2
        case let (p?, nil): newIndex = p + SortIndexing.gap
        case let (nil, n?): newIndex = n - SortIndexing.gap
        case (nil, nil): newIndex = SortIndexing.gap
        }

        let collides = (previous != nil && newIndex <= previous!) || (next != nil && newIndex >= next!)
        if collides {
            entries.insert(moved, at: target)
            for (position, entry) in entries.enumerated() {
                entry.sortIndex = Double(position + 1) * SortIndexing.gap
            }
        } else {
            moved.sortIndex = newIndex
        }
        // 立即落盘：自动保存有延迟，排完序马上被系统杀掉（或模拟器直接终止）会丢掉这次排序（实测）
        try? context.save()
    }

    static func remove(_ photo: Photo, from album: Album, in context: ModelContext) {
        for entry in album.entries ?? [] where entry.photo?.id == photo.id {
            context.delete(entry)
        }
        if album.coverPhotoID == photo.id {
            album.coverPhotoID = nil
        }
    }

    /// 从图库彻底删除：原图 + 缩略图 + 记录（级联清掉所有相簿关联）
    static func deletePhotos(_ photos: [Photo], in context: ModelContext, store: ImageStore = .shared) {
        for photo in photos {
            store.deleteFiles(relativePath: photo.fileRelativePath, photoID: photo.id)
            ThumbnailCache.shared.evict(photoID: photo.id)
            context.delete(photo)
        }
    }
}
