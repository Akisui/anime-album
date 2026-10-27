import CryptoKit
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
    /// 从照片图库导入后，可以从系统相册删除原图的那些项（系统照片库的本地标识；只含确认已在拾匣里的 —— 新导入成功或本来就有）。
    /// 非空时页面弹「从系统相册删除这 N 项？」（见 OriginalDeletionPrompt）
    var originalsToOffer: [String] = []

    /// 一次导入的结果：photos 为这批选择对应的照片（新导入的 + 图库中已有的重复项，按选择顺序、去重），
    /// 供「相簿里直接导入」把它们加入相簿
    struct ImportResult {
        var photos: [Photo] = []
        var imported = 0
        var duplicates = 0
        var failed = 0
        /// 确认已在拾匣里的那些项的序号（新导入成功的 + 本来就有的重复项）；失败的不在里面
        var safeIndices: [Int] = []
    }

    /// 一项待导入的内容：图片 / PDF 的数据、视频文件（临时文件，导入后删除）、实况照片（静态图数据 + 配套视频）
    enum Payload {
        case data(Data, filename: String?)
        case video(URL, filename: String?)
        case livePhoto(photo: Data, video: URL, filename: String?)
    }

    @discardableResult
    func importPickerItems(_ items: [PhotosPickerItem], context: ModelContext) async -> ImportResult {
        let result = await runImport(count: items.count, context: context) { index in
            let item = items[index]
            let types = item.supportedContentTypes
            // 实况照片：静态图 + 配套视频都存下来（只取 Data 的话只拿到静态图）
            if types.contains(where: { $0.conforms(to: .livePhoto) }),
               let live = try? await item.loadTransferable(type: PHLivePhoto.self),
               let (photo, video) = try? await Self.exportResources(of: live) {
                return .livePhoto(photo: photo, video: video, filename: nil)
            }
            // 视频：按文件接收（不整个读进内存）
            if types.contains(where: { $0.conforms(to: .movie) }),
               let movie = try await item.loadTransferable(type: MovieFile.self) {
                return .video(movie.url, filename: nil)
            }
            guard let data = try await item.loadTransferable(type: Data.self) else { return nil }
            return .data(data, filename: nil)
        }
        // 只提供删除确认已在拾匣里的那些（导入失败的绝不删）
        if OriginalDeletion.isOffered {
            originalsToOffer = result.safeIndices.compactMap { items[$0].itemIdentifier }
        }
        return result
    }

    @discardableResult
    func importFiles(at urls: [URL], context: ModelContext) async -> ImportResult {
        await runImport(count: urls.count, context: context) { index in
            let url = urls[index]
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            if ImageStore.isVideoFile(url) {
                return .video(try Self.temporaryCopy(of: url), filename: url.lastPathComponent)
            }
            return .data(try Data(contentsOf: url), filename: url.lastPathComponent)
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
            if type.conforms(to: .movie) {
                return .video(try await Self.loadFile(from: provider, type: type), filename: provider.suggestedName)
            }
            return .data(try await Self.loadData(from: provider, type: type), filename: provider.suggestedName)
        }
    }

    /// 可导入的内容类型（拖入、文件导入共用）
    static let importableTypes: [UTType] = [.image, .pdf, .movie]

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

    /// 拖入的视频：系统给的临时文件在回调结束后就删，先拷一份
    private static func loadFile(from provider: NSItemProvider, type: UTType) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                continuation.resume(with: Result { try temporaryCopy(of: url) })
            }
        }
    }

    nonisolated static func temporaryCopy(of url: URL) throws -> URL {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString).\(url.pathExtension)")
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    /// 实况照片拆成静态图数据 + 配套视频文件
    private static func exportResources(of live: PHLivePhoto) async throws -> (Data, URL) {
        let resources = PHAssetResource.assetResources(for: live)
        guard let still = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }),
              let motion = resources.first(where: { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo })
        else {
            throw CocoaError(.fileReadUnknown)
        }
        let directory = FileManager.default.temporaryDirectory
        let stillURL = directory.appendingPathComponent("live-\(UUID().uuidString).\(still.originalFilename.split(separator: ".").last ?? "heic")")
        let videoURL = directory.appendingPathComponent("live-\(UUID().uuidString).mov")
        try await PHAssetResourceManager.default().writeData(for: still, toFile: stillURL, options: nil)
        try await PHAssetResourceManager.default().writeData(for: motion, toFile: videoURL, options: nil)
        defer { try? FileManager.default.removeItem(at: stillURL) }
        return (try Data(contentsOf: stillURL), videoURL)
    }

    private func runImport(
        count: Int,
        context: ModelContext,
        payload: (Int) async throws -> Payload?
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
                guard let item = try await payload(index) else {
                    result.failed += 1
                    continue
                }
                // 视频 / 实况照片的临时文件导入后删掉
                var temporaryFile: URL?
                defer {
                    if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
                }
                let hash: String
                let filename: String?
                switch item {
                case .data(let data, let name):
                    hash = await Self.contentHash(of: data)
                    filename = name
                case .video(let url, let name):
                    temporaryFile = url
                    hash = await Self.contentHash(ofFileAt: url)
                    filename = name
                case .livePhoto(let photo, let video, let name):
                    temporaryFile = video
                    hash = await Self.contentHash(of: photo)
                    filename = name
                }
                if let existing = photosByHash[hash] {
                    result.duplicates += 1
                    result.safeIndices.append(index)
                    appendResult(existing)
                    continue
                }
                let photoID = UUID()
                processingID = photoID
                let stored: StoredImage
                switch item {
                case .data(let data, _):
                    stored = try await Self.storeOffMain(data: data, photoID: photoID) { [weak self] page, count in
                        Task { @MainActor in
                            // 回调是异步送回来的：可能晚于这张处理完，只认正在处理的这一份
                            guard let self, self.processingID == photoID else { return }
                            self.documentProgress = (page, count)
                        }
                    }
                case .video(let url, _):
                    stored = try await ImageStore.shared.storeVideo(fileAt: url, photoID: photoID)
                case .livePhoto(let photo, let video, _):
                    stored = try await ImageStore.shared.storeLivePhoto(photoData: photo, videoAt: video, photoID: photoID)
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
                photo.mediaType = stored.mediaType.rawValue
                photo.duration = stored.duration
                photo.pairedVideoRelativePath = stored.pairedVideoRelativePath
                if let pageCount = stored.pageCount {
                    photo.mediaType = Photo.MediaType.pdf.rawValue
                    photo.pageCount = pageCount
                }
                context.insert(photo)
                photosByHash[hash] = photo
                appendResult(photo)
                result.imported += 1
                result.safeIndices.append(index)
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

    /// 大文件（视频）分块算哈希，不整个读进内存
    private nonisolated static func contentHash(ofFileAt url: URL) async -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return UUID().uuidString }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func storeOffMain(
        data: Data, photoID: UUID, pdfProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> StoredImage {
        try ImageStore.shared.store(data: data, photoID: photoID, pdfProgress: pdfProgress)
    }
}

/// 照片选择器里的视频按文件接收（Data 会把整段视频读进内存）
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            Self(url: try PhotoImporter.temporaryCopy(of: received.file))
        }
    }
}
