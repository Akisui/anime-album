import SwiftUI

/// 导入进度 / 结果提示（图库与相簿共用）：浮在照片之上的半透明卡片，轻投影与内容分层，从底部出现 / 收回
struct ImportStatusOverlay: View {
    let importer: PhotoImporter

    var body: some View {
        content
            .animation(.spring(response: 0.35, dampingFraction: 1), value: importer.isImporting)
            .animation(.spring(response: 0.35, dampingFraction: 1), value: importer.summary)
    }

    @ViewBuilder
    private var content: some View {
        if importer.isImporting {
            VStack(alignment: .leading, spacing: 8) {
                // PDF 拆页时显示页数进度：处理到第几页 / 共几页
                if let document = importer.documentProgress {
                    HStack {
                        Text(importer.total > 1 ? "正在处理 PDF（\(importer.completed + 1)/\(importer.total)）" : "正在处理 PDF")
                            .font(.footnote.weight(.semibold))
                        Spacer()
                        Text("第 \(min(document.page + 1, document.pageCount)) / \(document.pageCount) 页")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(document.page), total: Double(max(document.pageCount, 1)))
                } else {
                    HStack {
                        Text("正在导入")
                            .font(.footnote.weight(.semibold))
                        Spacer()
                        Text("\(importer.completed)/\(importer.total)")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(importer.completed), total: Double(max(importer.total, 1)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: 240)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let summary = importer.summary {
            Text(summary)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: summary) {
                    try? await Task.sleep(for: .seconds(2.5))
                    importer.summary = nil
                }
        }
    }
}
