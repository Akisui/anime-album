import CryptoKit
import Foundation
import ImageIO
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

    func store(data: Data, photoID: UUID) throws -> StoredImage {
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

    private func rebuildThumbnail(photoID: UUID, kind: ThumbnailKind) {
        let bucket = originalsURL.appendingPathComponent(
            String(photoID.uuidString.prefix(2)).lowercased(), isDirectory: true)
        guard let filename = (try? FileManager.default.contentsOfDirectory(atPath: bucket.path))?
                .first(where: { $0.hasPrefix(photoID.uuidString) }),
              let source = CGImageSourceCreateWithURL(bucket.appendingPathComponent(filename) as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else {
            return
        }
        let (width, height) = Self.pixelSize(of: source)
        // 同一张照片可能被多个格子同时请求：串行队列里排到时若已重建好就不再重复编码
        guard !FileManager.default.fileExists(atPath: thumbnailURL(photoID: photoID, kind: kind).path) else { return }
        try? writeThumbnail(from: source, photoID: photoID, kind: kind, width: width, height: height)
    }

    // MARK: - 删除

    func deleteFiles(relativePath: String, photoID: UUID) {
        try? FileManager.default.removeItem(at: url(forRelativePath: relativePath))
        for kind in ThumbnailKind.allCases {
            try? FileManager.default.removeItem(at: thumbnailURL(photoID: photoID, kind: kind))
        }
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
