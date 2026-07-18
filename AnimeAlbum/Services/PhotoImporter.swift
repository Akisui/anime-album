import Foundation
import PhotosUI
import SwiftData
import SwiftUI

/// 导入管线（DESIGN.md §5.1）：读取数据 → 算 hash → 查重 → 落盘 + 缩略图 → 入库。
/// hash 与落盘在全局并发执行器上进行；模型插入回到主线程。
@MainActor
@Observable
final class PhotoImporter {
    private(set) var isImporting = false
    private(set) var completed = 0
    private(set) var total = 0
    var summary: String?

    func importPickerItems(_ items: [PhotosPickerItem], context: ModelContext) async {
        await runImport(count: items.count, context: context) { index in
            guard let data = try await items[index].loadTransferable(type: Data.self) else { return nil }
            return (data, nil)
        }
    }

    func importFiles(at urls: [URL], context: ModelContext) async {
        await runImport(count: urls.count, context: context) { index in
            let url = urls[index]
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            return (try Data(contentsOf: url), url.lastPathComponent)
        }
    }

    private func runImport(
        count: Int,
        context: ModelContext,
        payload: (Int) async throws -> (data: Data, filename: String?)?
    ) async {
        guard count > 0, !isImporting else { return }
        isImporting = true
        total = count
        completed = 0

        var imported = 0
        var duplicates = 0
        var failed = 0
        var knownHashes = Set(((try? context.fetch(FetchDescriptor<Photo>())) ?? []).map(\.contentHash))

        for index in 0..<count {
            defer { completed += 1 }
            do {
                guard let (data, filename) = try await payload(index) else {
                    failed += 1
                    continue
                }
                let hash = await Self.contentHash(of: data)
                guard !knownHashes.contains(hash) else {
                    duplicates += 1
                    continue
                }
                let photoID = UUID()
                let stored = try await Self.storeOffMain(data: data, photoID: photoID)

                let photo = Photo()
                photo.id = photoID
                photo.contentHash = hash
                photo.fileRelativePath = stored.relativePath
                photo.width = stored.width
                photo.height = stored.height
                photo.originalFilename = filename
                context.insert(photo)
                knownHashes.insert(hash)
                imported += 1
            } catch {
                failed += 1
            }
        }

        try? context.save()
        isImporting = false

        var parts = ["已导入 \(imported) 张"]
        if duplicates > 0 { parts.append("跳过重复 \(duplicates) 张") }
        if failed > 0 { parts.append("失败 \(failed) 张") }
        summary = parts.joined(separator: "，")
    }

    // nonisolated async：在全局并发执行器上运行，避免主线程做哈希/编码
    private nonisolated static func contentHash(of data: Data) async -> String {
        ImageStore.contentHash(of: data)
    }

    private nonisolated static func storeOffMain(data: Data, photoID: UUID) async throws -> StoredImage {
        try ImageStore.shared.store(data: data, photoID: photoID)
    }
}
