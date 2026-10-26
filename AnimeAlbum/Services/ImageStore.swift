import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers

enum ThumbnailKind: String, Sendable, CaseIterable {
    /// 一行 15 张的最密档专用（格子 ~25pt）：若也用 small，一屏 400+ 张解码后近 1GB，远超缓存
    case tiny
    case small
    case large

    /// 短边目标：small 覆盖两列档网格格子（~213pt × 3x）；tiny 覆盖最密档（~25pt × 3x）留余量
    private static let smallShortEdge = 640
    private static let tinyShortEdge = 160

    /// 磁盘目录名。small 的尺寸规则改过（v2 按短边），换目录后旧缩略图在读取时按新规则重建
    var directoryName: String {
        switch self {
        case .tiny: "tiny"
        case .small: "small-v2"
        case .large: "large"
        }
    }

    /// 传给 kCGImageSourceThumbnailMaxPixelSize 的值（作用于长边）。
    /// - small：网格格子是正方形 aspectFill，屏幕上显示的是**短边**。若按长边限 512，
    ///   竖图短边只剩 ~290–340px，在 3x 屏 ~140pt（420px）的格子里被放大 1.3–2 倍而发糊。
    ///   改为保证短边 640px（不裁切，保持比例 —— 查看器过渡在大图未缓存时用它算几何），
    ///   长边最多为短边 4 倍，防超长图过大；原图更小时不放大。
    /// - large：查看器全屏 fit，按长边 2048。
    func maxPixelSize(width: Int, height: Int) -> Int {
        switch self {
        case .tiny:
            return Self.longEdge(forShortEdge: Self.tinyShortEdge, width: width, height: height)
        case .small:
            return Self.longEdge(forShortEdge: Self.smallShortEdge, width: width, height: height)
        case .large:
            return 2048
        }
    }

    /// 保证短边达到 target 时的长边像素（保持比例、不放大原图、长边最多为短边 4 倍）
    private static func longEdge(forShortEdge target: Int, width: Int, height: Int) -> Int {
        let short = min(width, height)
        let long = max(width, height)
        guard short > 0 else { return target * 2 }
        guard short > target else { return long }
        let scaled = Int((Double(target) * Double(long) / Double(short)).rounded(.up))
        return min(scaled, target * 4)
    }
}

struct StoredImage: Sendable {
    let relativePath: String
    let width: Int
    let height: Int
    /// PDF 的页数；图片为 nil
    var pageCount: Int?
}

enum ImageStoreError: Error {
    case unreadableImage
    case thumbnailFailed
}

/// 图片文件的落盘与读取。目录布局见 DESIGN.md §4.3：
/// originals/<uuid前2位>/<uuid>.<ext> + thumbnails/{small,large}/<uuid>.heic
final class ImageStore: Sendable {
    static let shared = try! ImageStore()

    private let baseURL: URL
    /// 缩略图编码互斥：同一时刻只编码一张（导入与按需重建可能同时发生）
    private let encodeLock = NSLock()
    /// 按需重建缩略图的专用串行队列（不在 Swift 协作线程池上）：HEVC 编码器内部要借协作池的
    /// 空闲线程完成工作，若在池线程上同步阻塞地编码、又把池占满，编码器会永久卡在
    /// semaphore_wait（实测按需重建全部卡死）。调用方用 continuation 挂起等待，不占池线程
    private let rebuildQueue = DispatchQueue(label: "ImageStore.thumbnailRebuild", qos: .userInitiated)
    /// tiny 的内存缩小解码必须**串行**：HEVC 解码器在大量并发解码时会在内部条件变量上互相等死
    /// （实测进最密档一屏几十张同时解码，65 个线程全部卡在 VCPHEVC 的 cond_wait，协作池或 GCD 并发队列都一样）
    private let decodeQueue = DispatchQueue(label: "ImageStore.thumbnailDecode", qos: .userInitiated)

    init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        baseURL = support.appendingPathComponent("PhotoLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: originalsURL, withIntermediateDirectories: true)
        for kind in ThumbnailKind.allCases {
            try FileManager.default.createDirectory(at: thumbnailsURL(kind), withIntermediateDirectories: true)
        }
        // v1 的 small（按长边 512，竖图发糊）已由 small-v2 取代，清掉旧目录
        try? FileManager.default.removeItem(at: baseURL.appendingPathComponent("thumbnails/small", isDirectory: true))
        // 缩略图可随时重建，不进备份
        var thumbnailsRoot = baseURL.appendingPathComponent("thumbnails", isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? thumbnailsRoot.setResourceValues(values)
    }

    // MARK: - 路径

    private var originalsURL: URL {
        baseURL.appendingPathComponent("originals", isDirectory: true)
    }

    private func thumbnailsURL(_ kind: ThumbnailKind) -> URL {
        baseURL.appendingPathComponent("thumbnails/\(kind.directoryName)", isDirectory: true)
    }

    func url(forRelativePath path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    private func thumbnailURL(photoID: UUID, kind: ThumbnailKind) -> URL {
        thumbnailsURL(kind).appendingPathComponent("\(photoID.uuidString).heic")
    }

    // MARK: - 写入

    static func contentHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// pdfProgress：PDF 拆页进度（已处理页数, 总页数），在当前线程回调
    func store(data: Data, photoID: UUID, pdfProgress: (@Sendable (Int, Int) -> Void)? = nil) throws -> StoredImage {
        if Self.isPDF(data) {
            return try storePDF(data: data, photoID: photoID, progress: pdfProgress)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else {
            throw ImageStoreError.unreadableImage
        }

        let ext = Self.fileExtension(for: source)
        let bucket = String(photoID.uuidString.prefix(2)).lowercased()
        let relativePath = "originals/\(bucket)/\(photoID.uuidString).\(ext)"
        let destination = url(forRelativePath: relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)

        let (width, height) = Self.pixelSize(of: source)
        do {
            for kind in ThumbnailKind.allCases {
                try writeThumbnail(from: source, photoID: photoID, kind: kind, width: width, height: height)
            }
        } catch {
            deleteFiles(relativePath: relativePath, photoID: photoID)
            throw error
        }

        return StoredImage(relativePath: relativePath, width: width, height: height)
    }

    /// PDF（DESIGN.md §8.3）：原文件落盘，缩略图由首页渲染（白底），之后与图片走同一套缩略图管线
    private func storePDF(data: Data, photoID: UUID, progress: (@Sendable (Int, Int) -> Void)?) throws -> StoredImage {
        guard let document = PDFDocument(data: data), document.pageCount > 0,
              let source = Self.firstPageImageSource(of: document)
        else {
            throw ImageStoreError.unreadableImage
        }
        let bucket = String(photoID.uuidString.prefix(2)).lowercased()
        let relativePath = "originals/\(bucket)/\(photoID.uuidString).pdf"
        let destination = url(forRelativePath: relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)

        // 拆页（矢量页保持矢量、扫描页转无损图片），查看器按页浏览
        PDFPageStore.shared.prepare(photoID: photoID, pdfData: data, progress: progress)
        // 网格缩略图用处理后的首页做：与查看器里的第 1 页是同一张图（扫描页裁掉了白边）。
        // 用整页渲染的话，打开时过渡图带白边、小一圈，大图换上后突然变大（用户反馈）
        let coverURL = PDFPageStore.shared.firstPagePreviewURL(photoID: photoID)
        let cover = coverURL.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) } ?? source
        let (width, height) = Self.pixelSize(of: cover)
        do {
            for kind in ThumbnailKind.allCases {
                try writeThumbnail(from: cover, photoID: photoID, kind: kind, width: width, height: height)
            }
        } catch {
            deleteFiles(relativePath: relativePath, photoID: photoID)
            throw error
        }
        if coverURL != nil {
            PDFPageStore.shared.markCoverBuilt(photoID: photoID)
        }
        return StoredImage(relativePath: relativePath, width: width, height: height, pageCount: document.pageCount)
    }

    static func isPDF(_ data: Data) -> Bool {
        data.prefix(5).elementsEqual("%PDF-".utf8)
    }

    /// PDF 首页按长边 2048px 渲染成位图（白底），包成 CGImageSource 供缩略图管线使用
    private static func firstPageImageSource(of document: PDFDocument) -> CGImageSource? {
        guard let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = 2048 / max(bounds.width, bounds.height)
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cgContext = context.cgContext
            // PDF 坐标系原点在左下：翻转后按比例绘制
            cgContext.translateBy(x: 0, y: size.height)
            cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: cgContext)
        }
        guard let png = image.pngData() else { return nil }
        return CGImageSourceCreateWithData(png as CFData, nil)
    }

    private func writeThumbnail(
        from source: CGImageSource, photoID: UUID, kind: ThumbnailKind, width: Int, height: Int
    ) throws {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: kind.maxPixelSize(width: width, height: height),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageStoreError.thumbnailFailed
        }
        let url = thumbnailURL(photoID: photoID, kind: kind)
        // HEIC 优先；无 HEIC 编码器的环境（如部分模拟器）退回 JPEG。
        // 文件名固定 .heic，解码按内容识别，不受影响。
        if !Self.write(cgImage, to: url, type: .heic, quality: 0.75),
           !Self.write(cgImage, to: url, type: .jpeg, quality: 0.82) {
            throw ImageStoreError.thumbnailFailed
        }
    }

    /// 先写临时文件再原子替换：缩略图可能在读取时被并发重建（同一张照片的多个格子同时加载），
    /// 不能让两个写入者交错写同一个文件
    private static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double) -> Bool {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        guard let destination = CGImageDestinationCreateWithURL(
            temporary as CFURL, type.identifier as CFString, 1, nil)
        else {
            return false
        }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        do {
            // replaceItemAt 要求目标已存在；首次生成用 move（并发时后到者 move 失败，
            // 落到 catch 里按「目标已由别人写好」处理）
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    // MARK: - 读取

    /// 缩略图缺失（尺寸规则升级换了目录、或被清理）时，在专用队列上从原图按当前规则重建
    func ensureThumbnail(photoID: UUID, kind: ThumbnailKind) async {
        guard !FileManager.default.fileExists(atPath: thumbnailURL(photoID: photoID, kind: kind).path) else { return }
        // tiny 缺失时不编码补盘：读取时直接从 small 内存缩小（见 loadThumbnail），只需确保 small 在
        if kind == .tiny {
            await ensureThumbnail(photoID: photoID, kind: .small)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            rebuildQueue.async {
                self.rebuildThumbnail(photoID: photoID, kind: kind)
                continuation.resume()
            }
        }
    }

    /// 同步读取（不重建；缺失返回 nil）。网格走 ThumbnailCache 的异步路径，会先 ensureThumbnail
    func loadThumbnail(photoID: UUID, kind: ThumbnailKind) -> UIImage? {
        let url = thumbnailURL(photoID: photoID, kind: kind)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        #if targetEnvironment(simulator)
        // 模拟器上 preparingForDisplay 对 HEIC 会返回空白位图，跳过预解码
        return image
        #else
        return image.preparingForDisplay() ?? image
        #endif
    }

    /// tiny 缩略图（异步）：有文件直接读；没有文件的照片（导入早于 tiny 档出现）从 small 文件按 tiny 尺寸
    /// 缩小解码，只进内存不写盘 —— 写盘要串行编码 HEIC，首次进入最密档时几百张排队，格子长时间空白（实测）
    func loadTinyThumbnail(photoID: UUID) async -> UIImage? {
        if FileManager.default.fileExists(atPath: thumbnailURL(photoID: photoID, kind: .tiny).path) {
            return loadThumbnail(photoID: photoID, kind: .tiny)
        }
        await ensureThumbnail(photoID: photoID, kind: .small)
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            decodeQueue.async {
                continuation.resume(returning: self.downsampledTinyThumbnail(photoID: photoID))
            }
        }
    }

    private func downsampledTinyThumbnail(photoID: UUID) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(thumbnailURL(photoID: photoID, kind: .small) as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else {
            return nil
        }
        let (width, height) = Self.pixelSize(of: source)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: ThumbnailKind.tiny.maxPixelSize(width: width, height: height),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// 原图文件（originals/<桶>/<uuid>.<扩展名>）
    func originalURL(photoID: UUID) -> URL? {
        let bucket = originalsURL.appendingPathComponent(
            String(photoID.uuidString.prefix(2)).lowercased(), isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(atPath: bucket.path))?
            .first(where: { $0.hasPrefix(photoID.uuidString) })
            .map { bucket.appendingPathComponent($0) }
    }

    private func rebuildThumbnail(photoID: UUID, kind: ThumbnailKind) {
        guard let fileURL = originalURL(photoID: photoID) else { return }
        let imageSource: CGImageSource? = fileURL.pathExtension.lowercased() == "pdf"
            ? PDFPageStore.shared.firstPagePreviewURL(photoID: photoID)
                .flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
                ?? PDFDocument(url: fileURL).flatMap(Self.firstPageImageSource(of:))
            : CGImageSourceCreateWithURL(fileURL as CFURL, nil)
        guard let source = imageSource, CGImageSourceGetCount(source) > 0 else {
            return
        }
        let (width, height) = Self.pixelSize(of: source)
        // 同一张照片可能被多个格子同时请求：串行队列里排到时若已重建好就不再重复编码
        guard !FileManager.default.fileExists(atPath: thumbnailURL(photoID: photoID, kind: kind).path) else { return }
        try? writeThumbnail(from: source, photoID: photoID, kind: kind, width: width, height: height)
    }

    /// 早先导入的 PDF：缩略图改用处理后的首页重建，返回新尺寸
    func rebuildPDFThumbnails(photoID: UUID) -> (width: Int, height: Int)? {
        guard let url = PDFPageStore.shared.firstPagePreviewURL(photoID: photoID),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else {
            return nil
        }
        let (width, height) = Self.pixelSize(of: source)
        for kind in ThumbnailKind.allCases {
            try? FileManager.default.removeItem(at: thumbnailURL(photoID: photoID, kind: kind))
            try? writeThumbnail(from: source, photoID: photoID, kind: kind, width: width, height: height)
        }
        return (width, height)
    }

    // MARK: - 编辑（裁剪）

    /// 第一次裁剪时原图移到 unedited/<桶>/<uuid>.<扩展名> 备份（可复原；查重仍按原图哈希），
    /// 同名 .json 记着当前裁剪框（相对未编辑原图、归一化）—— 再次编辑时从原图和这个框开始
    private func uneditedDirectory(photoID: UUID) -> URL {
        baseURL.appendingPathComponent("unedited/\(String(photoID.uuidString.prefix(2)).lowercased())", isDirectory: true)
    }

    private func uneditedOriginalURL(photoID: UUID) -> URL? {
        let directory = uneditedDirectory(photoID: photoID)
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .first { $0.hasPrefix(photoID.uuidString) && !$0.hasSuffix(".json") }
            .map { directory.appendingPathComponent($0) }
    }

    private func cropRecordURL(photoID: UUID) -> URL {
        uneditedDirectory(photoID: photoID).appendingPathComponent("\(photoID.uuidString).json")
    }

    struct EditingBase: @unchecked Sendable {
        /// 未编辑的原图（显示用，长边 ≤ 2048）
        let image: UIImage
        /// 当前裁剪框（归一化，相对 image）；未裁剪时为整张
        let crop: CGRect
    }

    /// 编辑器的起点：未编辑原图（没编辑过就是当前原图）+ 当前裁剪框
    func editingBase(photoID: UUID) -> EditingBase? {
        guard let url = uneditedOriginalURL(photoID: photoID) ?? originalURL(photoID: photoID),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = Self.orientedImage(from: source, maxPixel: 2048)
        else {
            return nil
        }
        var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        if uneditedOriginalURL(photoID: photoID) != nil,
           let data = try? Data(contentsOf: cropRecordURL(photoID: photoID)),
           let values = try? JSONDecoder().decode([Double].self, from: data), values.count == 4 {
            crop = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        return EditingBase(image: UIImage(cgImage: image), crop: crop)
    }

    /// 按归一化裁剪框（相对未编辑原图）生成新的原图并重建缩略图；框为整张时复原。
    /// 返回新的原图信息（尺寸、扩展名可能变）
    func applyCrop(photoID: UUID, crop: CGRect) throws -> StoredImage {
        let fileManager = FileManager.default
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let isFull = abs(crop.minX) < 0.001 && abs(crop.minY) < 0.001
            && abs(crop.width - 1) < 0.001 && abs(crop.height - 1) < 0.001
        let bucket = String(photoID.uuidString.prefix(2)).lowercased()

        // 复原：备份移回原位
        if isFull {
            guard let backup = uneditedOriginalURL(photoID: photoID) else {
                throw ImageStoreError.unreadableImage
            }
            if let current = originalURL(photoID: photoID) {
                try? fileManager.removeItem(at: current)
            }
            let relativePath = "originals/\(bucket)/\(backup.lastPathComponent)"
            try fileManager.moveItem(at: backup, to: url(forRelativePath: relativePath))
            try? fileManager.removeItem(at: cropRecordURL(photoID: photoID))
            return try rebuildAllThumbnails(photoID: photoID, relativePath: relativePath)
        }

        // 第一次编辑：先把原图移去备份
        if uneditedOriginalURL(photoID: photoID) == nil {
            guard let current = originalURL(photoID: photoID) else { throw ImageStoreError.unreadableImage }
            try fileManager.createDirectory(at: uneditedDirectory(photoID: photoID), withIntermediateDirectories: true)
            try fileManager.moveItem(at: current, to: uneditedDirectory(photoID: photoID)
                .appendingPathComponent(current.lastPathComponent))
        }
        guard let backup = uneditedOriginalURL(photoID: photoID),
              let source = CGImageSourceCreateWithURL(backup as CFURL, nil),
              let oriented = Self.orientedImage(from: source, maxPixel: nil)
        else {
            throw ImageStoreError.unreadableImage
        }
        let bounds = CGRect(x: 0, y: 0, width: oriented.width, height: oriented.height)
        let clamped = crop.intersection(full)
        let pixelRect = CGRect(x: clamped.minX * bounds.width, y: clamped.minY * bounds.height,
                               width: clamped.width * bounds.width, height: clamped.height * bounds.height).integral
            .intersection(bounds)
        guard let cropped = oriented.cropping(to: pixelRect) else { throw ImageStoreError.unreadableImage }

        // 尽量保持原格式（JPEG / PNG / HEIC…），编码不了的退回 PNG（无损）
        let sourceType = CGImageSourceGetType(source).flatMap { UTType($0 as String) } ?? .png
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = nil
        properties[kCGImagePropertyPixelHeight] = nil
        properties[kCGImageDestinationLossyCompressionQuality] = 0.95
        if let current = originalURL(photoID: photoID) {
            try? fileManager.removeItem(at: current)
        }
        var written: String?
        for type in [sourceType, .png] {
            let ext = type.preferredFilenameExtension ?? "png"
            let relativePath = "originals/\(bucket)/\(photoID.uuidString).\(ext)"
            let destinationURL = url(forRelativePath: relativePath)
            guard let destination = CGImageDestinationCreateWithURL(
                destinationURL as CFURL, type.identifier as CFString, 1, nil)
            else {
                continue
            }
            CGImageDestinationAddImage(destination, cropped, properties as CFDictionary)
            if CGImageDestinationFinalize(destination) {
                written = relativePath
                break
            }
            try? fileManager.removeItem(at: destinationURL)
        }
        guard let relativePath = written else { throw ImageStoreError.thumbnailFailed }
        let record = [clamped.minX, clamped.minY, clamped.width, clamped.height].map(Double.init)
        try? JSONEncoder().encode(record).write(to: cropRecordURL(photoID: photoID), options: .atomic)
        return try rebuildAllThumbnails(photoID: photoID, relativePath: relativePath)
    }

    private func rebuildAllThumbnails(photoID: UUID, relativePath: String) throws -> StoredImage {
        guard let source = CGImageSourceCreateWithURL(url(forRelativePath: relativePath) as CFURL, nil) else {
            throw ImageStoreError.unreadableImage
        }
        let (width, height) = Self.pixelSize(of: source)
        for kind in ThumbnailKind.allCases {
            try? FileManager.default.removeItem(at: thumbnailURL(photoID: photoID, kind: kind))
            try writeThumbnail(from: source, photoID: photoID, kind: kind, width: width, height: height)
        }
        return StoredImage(relativePath: relativePath, width: width, height: height)
    }

    /// 按 EXIF 方向摆正后的位图；maxPixel 为 nil 时原尺寸
    private static func orientedImage(from source: CGImageSource, maxPixel: Int?) -> CGImage? {
        let (width, height) = pixelSize(of: source)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel.map { min($0, max(width, height)) } ?? max(width, height),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - 删除

    func deleteFiles(relativePath: String, photoID: UUID) {
        try? FileManager.default.removeItem(at: url(forRelativePath: relativePath))
        for kind in ThumbnailKind.allCases {
            try? FileManager.default.removeItem(at: thumbnailURL(photoID: photoID, kind: kind))
        }
        PDFPageStore.shared.deleteFiles(photoID: photoID)
        // 裁剪前的原图备份
        if let backup = uneditedOriginalURL(photoID: photoID) {
            try? FileManager.default.removeItem(at: backup)
        }
        try? FileManager.default.removeItem(at: cropRecordURL(photoID: photoID))
    }

    // MARK: - 私有

    private static func fileExtension(for source: CGImageSource) -> String {
        guard let typeIdentifier = CGImageSourceGetType(source),
              let type = UTType(typeIdentifier as String),
              let ext = type.preferredFilenameExtension
        else {
            return "img"
        }
        return ext
    }

    private static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (0, 0)
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        // EXIF 方向 5-8 表示图像需旋转 90°，宽高互换
        return orientation >= 5 ? (height, width) : (width, height)
    }
}
