import Photos
import SwiftUI

/// 从照片图库导入后，询问是否从系统相册删除原图（用户要求：放进推し箱的私密照片不想再留在系统相册里）。
/// 只删确认已在推し箱里的那些（PhotoImporter.originalsToOffer）；删除前要照片库的读写权限（只在这时申请），
/// 系统还会弹自己的删除确认；删掉的先进系统「照片」的「最近删除」，30 天后彻底删除
enum OriginalDeletion {
    static let offerKey = "offerDeleteOriginals"

    /// 设置 › 隐私与安全 › 导入后询问是否删除原图（默认开）
    static var isOffered: Bool {
        UserDefaults.standard.object(forKey: offerKey) as? Bool ?? true
    }

    enum Outcome {
        case deleted(Int)
        /// 没有照片权限
        case denied
        /// 「部分照片」权限下拿不到这些照片
        case limited
        /// 用户在系统确认里取消，或照片已经不在了
        case nothing
    }

    @MainActor
    static func delete(localIdentifiers: [String]) async -> Outcome {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else { return .denied }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        guard assets.count > 0 else { return status == .limited ? .limited : .nothing }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            return .deleted(assets.count)
        } catch {
            return .nothing
        }
    }
}

extension View {
    /// 导入完成后弹「从系统相册删除这 N 项？」
    func offersOriginalDeletion(importer: PhotoImporter) -> some View {
        modifier(OriginalDeletionPrompt(importer: importer))
    }
}

private struct OriginalDeletionPrompt: ViewModifier {
    let importer: PhotoImporter
    @State private var notice: String?

    func body(content: Content) -> some View {
        content
            .alert("从系统相册删除这 \(importer.originalsToOffer.count) 项？", isPresented: Binding(
                get: { !importer.originalsToOffer.isEmpty },
                set: { if !$0 { importer.originalsToOffer = [] } }
            )) {
                Button("删除原图", role: .destructive) {
                    let identifiers = importer.originalsToOffer
                    importer.originalsToOffer = []
                    Task { await delete(identifiers) }
                }
                Button("保留", role: .cancel) {
                    importer.originalsToOffer = []
                }
            } message: {
                Text("它们已经安全导入\(AppInfo.name)。删除后会先移到系统「照片」的「最近删除」，30 天后彻底删除。")
            }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("好", role: .cancel) {}
            }
    }

    @MainActor
    private func delete(_ identifiers: [String]) async {
        switch await OriginalDeletion.delete(localIdentifiers: identifiers) {
        case .deleted:
            break
        case .denied:
            notice = "没有照片权限，无法删除原图。可以在系统「设置 › 隐私与安全性 › 照片」里允许\(AppInfo.name)访问，或在「照片」里手动删除。"
        case .limited:
            notice = "当前只允许访问部分照片，删不到这些原图。可以在系统「设置 › 隐私与安全性 › 照片」里改为「完全访问」，或在「照片」里手动删除。"
        case .nothing:
            break
        }
    }
}
