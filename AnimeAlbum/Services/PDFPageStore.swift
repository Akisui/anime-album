import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// PDF 的单页（DESIGN.md §8.3）：PDF 在查看器里按页当作一张张图片浏览。
/// - 矢量页（有文字 / 路径）保持矢量：不转位图，从原 PDF 按需渲染（查看器放大时分块重绘，任意倍数都清晰）
/// - 扫描页（整页只有一张图）转成无损图片：原图是 JPEG / JPEG 2000 时原样取出字节，
///   其他编码按图片原生分辨率渲染成 PNG
struct PDFPageInfo: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case vector
        case raster
    }

    var kind: Kind
    /// 扫描页提取出的图片文件名（pages/<uuid>/ 下）
    var file: String?
    /// 显示尺寸：矢量页为点（已按页面旋转），扫描页为像素 —— 只用于宽高比
    var width: Double
    var height: Double

    var aspectRatio: CGFloat {
        height > 0 ? CGFloat(width / height) : 1
    }
}

/// 页面清单与页面图片的读写。导入时生成清单（pages/<uuid>/manifest.json）和每页的预览图
/// （large-n.png / tiny-n.png）；早于此导入的 PDF 在第一次打开时补生成
final class PDFPageStore: @unchecked Sendable {
    static let shared = PDFPageStore()

    private let lock = NSLock()
    private var manifests: [UUID: [PDFPageInfo]] = [:]
    private var documents: [UUID: CGPDFDocument] = [:]
    /// 页面渲染 / 解码串行进行（CGPDFDocument 不保证并发安全，且大页面渲染占内存）
    private let renderQueue = DispatchQueue(label: "PDFPageStore.render", qos: .userInitiated)

    private func directory(photoID: UUID) -> URL {
        ImageStore.shared.url(forRelativePath: "pages/\(photoID.uuidString)")
    }

    private func manifestURL(photoID: UUID) -> URL {
        directory(photoID: photoID).appendingPathComponent("manifest.json")
    }

    private func pdfURL(photoID: UUID) -> URL? {
        ImageStore.shared.originalURL(photoID: photoID)
    }

    // MARK: - 清单

    /// 拆页：分析每一页、提取扫描页图片、写清单。导入时调用（失败不影响导入，打开时会再补）
    @discardableResult
    func prepare(photoID: UUID, pdfData: Data? = nil) -> [PDFPageInfo] {
        let document: CGPDFDocument?
        if let pdfData, let provider = CGDataProvider(data: pdfData as CFData) {
            document = CGPDFDocument(provider)
        } else {
            document = pdfURL(photoID: photoID).flatMap { CGPDFDocument($0 as CFURL) }
        }
        guard let document, document.numberOfPages > 0 else { return [] }
        let directory = directory(photoID: photoID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var pages: [PDFPageInfo] = []
        for number in 1...document.numberOfPages {
            guard let page = document.page(at: number) else { continue }
            let size = Self.displaySize(of: page)
            var info = PDFPageInfo(kind: .vector, width: size.width, height: size.height)
            if let raster = Self.extractRaster(page: page, index: number - 1, into: directory) {
                info = raster
            }
            pages.append(info)
        }
        if let data = try? JSONEncoder().encode(pages) {
            try? data.write(to: manifestURL(photoID: photoID), options: .atomic)
        }
        lock.withLock {
            manifests[photoID] = pages
            if documents[photoID] == nil {
                documents[photoID] = document
            }
        }
        // 导入时就把每页的预览图做好：查看时只解码，不在翻页时现场渲染（现场渲染会卡）
        for index in pages.indices {
            makePreview(photoID: photoID, page: index, kind: .large)
            makePreview(photoID: photoID, page: index, kind: .tiny)
        }
        return pages
    }

    /// 页面清单（同步；内存缓存 → 磁盘 → 现场补生成）
    func pages(photoID: UUID) -> [PDFPageInfo] {
        if let cached = lock.withLock({ manifests[photoID] }) {
            return cached
        }
        if let data = try? Data(contentsOf: manifestURL(photoID: photoID)),
           let pages = try? JSONDecoder().decode([PDFPageInfo].self, from: data), !pages.isEmpty {
            lock.withLock { manifests[photoID] = pages }
            return pages
        }
        return prepare(photoID: photoID)
    }

    func deleteFiles(photoID: UUID) {
        try? FileManager.default.removeItem(at: directory(photoID: photoID))
        lock.withLock {
            manifests[photoID] = nil
            documents[photoID] = nil
        }
    }

    // MARK: - 渲染

    /// 预览图规格：large 给查看器（长边 2048，放大后矢量页分块重绘、扫描页换原图），tiny 给胶片条
    enum PreviewKind: String {
        case large
        case tiny

        var maxPixel: Int {
            switch self {
            case .large: 2048
            case .tiny: 240
            }
        }
    }

    private func previewURL(photoID: UUID, page: Int, kind: PreviewKind) -> URL {
        directory(photoID: photoID).appendingPathComponent("\(kind.rawValue)-\(page + 1).png")
    }

    /// 页面预览图：导入时就生成好（PNG，无损），这里只解码；缺了（早先导入的 PDF）现场生成并补存
    func previewImage(photoID: UUID, page: Int, kind: PreviewKind) async -> UIImage? {
        await withCheckedContinuation { continuation in
            renderQueue.async {
                continuation.resume(returning: self.loadOrMakePreview(photoID: photoID, page: page, kind: kind))
            }
        }
    }

    /// 扫描页的原图（放大查看用，无损）；长边超过 8192 时缩到 8192
    func fullImage(photoID: UUID, page: Int) async -> UIImage? {
        await withCheckedContinuation { continuation in
            renderQueue.async {
                let pages = self.pages(photoID: photoID)
                guard pages.indices.contains(page), pages[page].kind == .raster, let file = pages[page].file else {
                    continuation.resume(returning: nil)
                    return
                }
                let url = self.directory(photoID: photoID).appendingPathComponent(file)
                continuation.resume(returning: Self.decode(url: url, maxPixel: 8192))
            }
        }
    }

    private func loadOrMakePreview(photoID: UUID, page: Int, kind: PreviewKind) -> UIImage? {
        let url = previewURL(photoID: photoID, page: page, kind: kind)
        if let image = Self.decode(url: url, maxPixel: nil) {
            return image
        }
        return makePreview(photoID: photoID, page: page, kind: kind)
    }

    @discardableResult
    private func makePreview(photoID: UUID, page index: Int, kind: PreviewKind) -> UIImage? {
        let pages = pages(photoID: photoID)
        guard pages.indices.contains(index) else { return nil }
        let info = pages[index]
        let image: UIImage?
        if info.kind == .raster, let file = info.file {
            image = Self.decode(url: directory(photoID: photoID).appendingPathComponent(file), maxPixel: kind.maxPixel)
        } else if let page = cgPage(photoID: photoID, index: index) {
            let size = Self.displaySize(of: page)
            image = Self.render(page: page, scale: CGFloat(kind.maxPixel) / max(size.width, size.height))
        } else {
            image = nil
        }
        if let data = image?.pngData() {
            try? data.write(to: previewURL(photoID: photoID, page: index, kind: kind), options: .atomic)
        }
        return image
    }

    private static func decode(url: URL, maxPixel: Int?) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixel {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel
        } else if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            options[kCGImageSourceThumbnailMaxPixelSize] = max(width, height, 1)
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }

    /// 矢量页的 CGPDFPage（查看器放大时分块重绘用）
    func cgPage(photoID: UUID, index: Int) -> CGPDFPage? {
        let document: CGPDFDocument? = lock.withLock {
            if let cached = documents[photoID] {
                return cached
            }
            let opened = pdfURL(photoID: photoID).flatMap { CGPDFDocument($0 as CFURL) }
            documents[photoID] = opened
            return opened
        }
        return document?.page(at: index + 1)
    }

    /// 页面按显示方向（已旋转）、白底渲染；scale：每点多少像素
    static func render(page: CGPDFPage, scale: CGFloat, interpolate: Bool = true) -> UIImage? {
        let size = displaySize(of: page)
        let pixelSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard pixelSize.width >= 1, pixelSize.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pixelSize))
            let cgContext = context.cgContext
            if !interpolate {
                cgContext.interpolationQuality = .none
            }
            draw(page: page, in: cgContext, size: pixelSize)
        }
    }

    /// 把页面画进 UIKit 坐标系（原点左上）的 size 区域（与页面同宽高比），按页面旋转摆正
    static func draw(page: CGPDFPage, in context: CGContext, size: CGSize) {
        let display = displaySize(of: page)
        guard display.width > 0, display.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: size.width / display.width, y: -size.height / display.height)
        // 目标矩形取显示尺寸本身：只做旋转 + 平移、不缩放（getDrawingTransform 不会放大超过 1 倍）
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: display),
                                                     rotate: 0, preserveAspectRatio: true))
        context.clip(to: page.getBoxRect(.cropBox))
        context.drawPDFPage(page)
        context.restoreGState()
    }

    /// 页面显示尺寸（点）：cropBox 按 /Rotate 旋转后
    static func displaySize(of page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let rotated = abs(page.rotationAngle) % 180 == 90
        return rotated ? CGSize(width: box.height, height: box.width) : box.size
    }

    // MARK: - 扫描页识别与提取

    /// 整页只有一张铺满的图片、没有文字和矢量绘制 → 扫描页，提取为无损图片
    private static func extractRaster(page: CGPDFPage, index: Int, into directory: URL) -> PDFPageInfo? {
        let scan = PageContentScan(page: page)
        guard scan.paintsVector == false, scan.showsText == false, scan.images.count == 1,
              let placed = scan.images.first
        else {
            return nil
        }
        let box = page.getBoxRect(.cropBox)
        let covered = placed.rect.intersection(box)
        guard !covered.isNull, covered.width * covered.height >= box.width * box.height * 0.98 else { return nil }

        let dictionary = CGPDFStreamGetDictionary(placed.stream)
        var width: CGPDFInteger = 0
        var height: CGPDFInteger = 0
        guard let dictionary,
              CGPDFDictionaryGetInteger(dictionary, "Width", &width),
              CGPDFDictionaryGetInteger(dictionary, "Height", &height),
              width > 0, height > 0
        else {
            return nil
        }

        // 原样取出 JPEG / JPEG 2000 字节（与 PDF 里的数据逐字节相同）：页面未旋转、图片正放、
        // 无遮罩 / 解码数组、颜色空间是 RGB 或灰度（CMYK JPEG 在 PDF 外常被反色）
        var format = CGPDFDataFormat.raw
        if page.rotationAngle % 360 == 0, placed.isUpright,
           !hasKey(dictionary, "SMask"), !hasKey(dictionary, "Mask"), !hasKey(dictionary, "Decode"),
           isRGBOrGray(dictionary),
           let data = CGPDFStreamCopyData(placed.stream, &format) as Data?,
           format == .jpegEncoded || format == .JPEG2000 {
            let file = "\(index + 1).\(format == .jpegEncoded ? "jpg" : "jp2")"
            let url = directory.appendingPathComponent(file)
            if (try? data.write(to: url, options: .atomic)) != nil,
               let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
                return PDFPageInfo(kind: .raster, file: file, width: Double(width), height: Double(height))
            }
            try? FileManager.default.removeItem(at: url)
        }

        // 其他编码：按图片原生分辨率（图片像素宽 / 页面上的宽）渲染整页成 PNG，不插值
        let pixelsPerPoint = CGFloat(placed.isQuarterTurned ? height : width) / max(placed.rect.width, 1)
        let display = displaySize(of: page)
        let longest = max(display.width, display.height) * pixelsPerPoint
        let scale = longest > 8192 ? pixelsPerPoint * 8192 / longest : pixelsPerPoint
        guard let image = render(page: page, scale: scale, interpolate: false), let png = image.pngData() else {
            return nil
        }
        let file = "\(index + 1).png"
        guard (try? png.write(to: directory.appendingPathComponent(file), options: .atomic)) != nil else { return nil }
        return PDFPageInfo(kind: .raster, file: file,
                           width: Double(image.size.width), height: Double(image.size.height))
    }

    private static func hasKey(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Bool {
        var object: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dictionary, key, &object)
    }

    private static func isRGBOrGray(_ dictionary: CGPDFDictionaryRef) -> Bool {
        var name: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dictionary, "ColorSpace", &name), let name {
            return ["DeviceRGB", "DeviceGray", "CalRGB", "CalGray"].contains(String(cString: name))
        }
        // [/ICCBased stream]：按通道数判断（3 = RGB，1 = 灰度）
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "ColorSpace", &array), let array {
            var family: UnsafePointer<CChar>?
            var stream: CGPDFStreamRef?
            if CGPDFArrayGetName(array, 0, &family), let family, String(cString: family) == "ICCBased",
               CGPDFArrayGetStream(array, 1, &stream), let stream, let profile = CGPDFStreamGetDictionary(stream) {
                var channels: CGPDFInteger = 0
                return CGPDFDictionaryGetInteger(profile, "N", &channels) && (channels == 3 || channels == 1)
            }
        }
        return false
    }
}

/// 扫描一页的内容流：记录图片绘制（及其在页面上的位置）、是否有文字和矢量绘制
private final class PageContentScan {
    struct PlacedImage {
        let stream: CGPDFStreamRef
        let rect: CGRect
        /// 图片正放（无旋转 / 翻转）
        let isUpright: Bool
        /// 图片转了 90°（像素宽对应页面上的高）
        let isQuarterTurned: Bool
    }

    private(set) var images: [PlacedImage] = []
    private(set) var paintsVector = false
    private(set) var showsText = false

    private var ctm = CGAffineTransform.identity
    private var stack: [CGAffineTransform] = []
    private let xObjects: CGPDFDictionaryRef?

    init(page: CGPDFPage) {
        xObjects = Self.xObjectDictionary(of: page)
        guard let table = CGPDFOperatorTableCreate() else { return }
        func set(_ names: [String], _ callback: CGPDFOperatorCallback) {
            for name in names {
                CGPDFOperatorTableSetCallback(table, name, callback)
            }
        }
        set(["q"]) { _, info in
            let scan = PageContentScan.from(info)
            scan.stack.append(scan.ctm)
        }
        set(["Q"]) { _, info in
            let scan = PageContentScan.from(info)
            if let last = scan.stack.popLast() { scan.ctm = last }
        }
        set(["cm"]) { scanner, info in
            var values = [CGPDFReal](repeating: 0, count: 6)
            for index in (0..<6).reversed() {
                guard CGPDFScannerPopNumber(scanner, &values[index]) else { return }
            }
            let matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3],
                                           tx: values[4], ty: values[5])
            let scan = PageContentScan.from(info)
            scan.ctm = matrix.concatenating(scan.ctm)
        }
        set(["Do"]) { scanner, info in
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            PageContentScan.from(info).drawXObject(named: name)
        }
        set(["f", "F", "f*", "S", "s", "B", "B*", "b", "b*", "sh", "BI"]) { _, info in
            PageContentScan.from(info).paintsVector = true
        }
        set(["Tj", "TJ", "'", "\""]) { _, info in
            PageContentScan.from(info).showsText = true
        }
        let content = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
        CGPDFOperatorTableRelease(table)
    }

    private static func from(_ info: UnsafeMutableRawPointer?) -> PageContentScan {
        Unmanaged<PageContentScan>.fromOpaque(info!).takeUnretainedValue()
    }

    private func drawXObject(named name: UnsafePointer<CChar>) {
        var stream: CGPDFStreamRef?
        guard let xObjects, CGPDFDictionaryGetStream(xObjects, name, &stream), let stream,
              let dictionary = CGPDFStreamGetDictionary(stream)
        else {
            paintsVector = true
            return
        }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
              String(cString: subtype) == "Image"
        else {
            // 表单 XObject 等：当作矢量内容（保守）
            paintsVector = true
            return
        }
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm)
        let upright = abs(ctm.b) < 0.001 && abs(ctm.c) < 0.001 && ctm.a > 0 && ctm.d > 0
        let quarter = abs(ctm.a) < 0.001 && abs(ctm.d) < 0.001
        images.append(PlacedImage(stream: stream, rect: rect, isUpright: upright, isQuarterTurned: quarter))
    }

    /// 页面的 /Resources /XObject（Resources 可继承自父节点）
    private static func xObjectDictionary(of page: CGPDFPage) -> CGPDFDictionaryRef? {
        var node = page.dictionary
        while let current = node {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources), let resources {
                var xObjects: CGPDFDictionaryRef?
                return CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects) ? xObjects : nil
            }
            var parent: CGPDFDictionaryRef?
            node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
        }
        return nil
    }
}
