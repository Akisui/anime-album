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
    /// 正在拆页的 PDF：已处理页数 / 总页数（导入进度显示「第 x / n 页」）
    private(set) var documentProgress: (page: Int, pageCount: Int)?
    @ObservationIgnored private var processingID: UUID?
    var summary: String?

    /// 一次导入的结果：photos 为这批选择对应的照片（新导入的 + 图库中已有的重复项，按选择顺序、去重），
    /// 供「相簿里直接导入」把它们加入相簿
    struct ImportResult {
        var photos: [Photo] = []
        var imported = 0
        var duplicates = 0
        var failed = 0
    }

    @discardableResult
    func importPickerItems(_ items: [PhotosPickerItem], context: ModelContext) async -> ImportResult {
        await runImport(count: items.count, context: context) { index in
            guard let data = try await items[index].loadTransferable(type: Data.self) else { return nil }
            return (data, nil)
        }
    }

    @discardableResult
    func importFiles(at urls: [URL], context: ModelContext) async -> ImportResult {
        await runImport(count: urls.count, context: context) { index in
            let url = urls[index]
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            return (try Data(contentsOf: url), url.lastPathComponent)
        }
    }

    /// 拖入导入（iPad 分屏 / 台前调度从其他 App 拖进来，DESIGN.md §5.1 入口 2）
    @discardableResult
    func importItemProviders(_ providers: [NSItemProvider], context: ModelContext) async -> ImportResult {
        await runImport(count: providers.count, context: context) { index in
            let provider = providers[index]
            guard let type = provider.registeredContentTypes.first(where: { Self.isImportable($0) }) else {
                return nil
            }
            return (try await Self.loadData(from: provider, type: type), provider.suggestedName)
        }
    }

    /// 可导入的内容类型（拖入、文件导入共用）
    static let importableTypes: [UTType] = [.image, .pdf]

    private static func isImportable(_ type: UTType) -> Bool {
        importableTypes.contains { type.conforms(to: $0) }
    }

    private static func loadData(from provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    private func runImport(
        count: Int,
        context: ModelContext,
        payload: (Int) async throws -> (data: Data, filename: String?)?
    ) async -> ImportResult {
        guard count > 0, !isImporting else { return ImportResult() }
        isImporting = true
        total = count
        completed = 0

        var result = ImportResult()
        var resultIDs = Set<UUID>()
        // 去重靠内容哈希（DESIGN.md §5.1）：命中已有照片时不重复导入，但仍把已有的那张算进结果
        var photosByHash = Dictionary(
            ((try? context.fetch(FetchDescriptor<Photo>())) ?? []).map { ($0.contentHash, $0) },
            uniquingKeysWith: { first, _ in first })
        func appendResult(_ photo: Photo) {
            if resultIDs.insert(photo.id).inserted {
                result.photos.append(photo)
            }
        }

        for index in 0..<count {
            defer { completed += 1 }
            do {
                guard let (data, filename) = try await payload(index) else {
                    result.failed += 1
                    continue
                }
                let hash = await Self.contentHash(of: data)
                if let existing = photosByHash[hash] {
                    result.duplicates += 1
                    appendResult(existing)
                    continue
                }
                let photoID = UUID()
                processingID = photoID
                let stored = try await Self.storeOffMain(data: data, photoID: photoID) { [weak self] page, count in
                    Task { @MainActor in
                        // 回调是异步送回来的：可能晚于这张处理完，只认正在处理的这一份
                        guard let self, self.processingID == photoID else { return }
                        self.documentProgress = (page, count)
                    }
                }
                processingID = nil
                documentProgress = nil

                let photo = Photo()
                photo.id = photoID
                photo.contentHash = hash
                photo.fileRelativePath = stored.relativePath
                photo.width = stored.width
                photo.height = stored.height
                photo.originalFilename = filename
                if let pageCount = stored.pageCount {
                    photo.mediaType = Photo.MediaType.pdf.rawValue
                    photo.pageCount = pageCount
                }
                context.insert(photo)
                photosByHash[hash] = photo
                appendResult(photo)
                result.imported += 1
            } catch {
                result.failed += 1
            }
        }

        try? context.save()
        isImporting = false

        var parts = ["已导入 \(result.imported) 张"]
        if result.duplicates > 0 { parts.append("跳过重复 \(result.duplicates) 张") }
        if result.failed > 0 { parts.append("失败 \(result.failed) 张") }
        summary = parts.joined(separator: "，")
        return result
    }

    // nonisolated async：在全局并发执行器上运行，避免主线程做哈希/编码
    private nonisolated static func contentHash(of data: Data) async -> String {
        ImageStore.contentHash(of: data)
    }

    private nonisolated static func storeOffMain(
        data: Data, photoID: UUID, pdfProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> StoredImage {
        try ImageStore.shared.store(data: data, photoID: photoID, pdfProgress: pdfProgress)
    }
}
