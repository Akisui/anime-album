import SwiftUI

/// 第一次打开 App：欢迎（功能介绍）→ 隐私与条款（勾选同意后才能开始用）。
/// 条款版本变了（AppInfo.termsVersion）时老用户直接从第二页开始重新确认
struct OnboardingView: View {
    /// 以前同意过旧版条款：跳过欢迎页
    let reconfirming: Bool
    let onAccept: () -> Void

    @State private var step = 0
    @State private var agreed = false
    @State private var showingDocument: LegalDocument?
    @State private var showingDeclineNote = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            if step == 0 && !reconfirming {
                welcomePage
                    .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
            } else {
                privacyPage
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            }
        }
        .sheet(item: $showingDocument) { document in
            NavigationStack {
                LegalDocumentView(document: document)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showingDocument = nil }
                        }
                    }
            }
        }
        .alert("需要你的同意", isPresented: $showingDeclineNote) {
            Button("好", role: .cancel) {}
        } message: {
            Text("同意《用户协议》和《隐私政策》后才能使用\(AppInfo.name)。你的内容只保存在你的设备和你自己的 iCloud 中。")
        }
    }

    // MARK: 欢迎

    private var welcomePage: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        Image("BrandIcon")
                            .resizable()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                        Text("欢迎使用\(AppInfo.name)")
                            .font(.largeTitle.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text("照片、视频和 PDF，收进只属于你的匣子。")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 56)

                    VStack(alignment: .leading, spacing: 22) {
                        FeatureRow(systemImage: "photo.on.rectangle.angled", color: .blue,
                                   title: "照片、视频、PDF",
                                   detail: "实况照片、动图、视频播放、PDF 逐页翻看，都放在一个地方。")
                        FeatureRow(systemImage: "rectangle.stack.fill", color: .orange,
                                   title: "相簿整理",
                                   detail: "长按拖动排序，双指捏合切换列数，整理起来顺手。")
                        FeatureRow(systemImage: "eye.slash.fill", color: .purple,
                                   title: "隐藏与面容 ID",
                                   detail: "把不想被随手看到的照片和相簿藏起来，需要时再验证查看。")
                        FeatureRow(systemImage: "icloud.fill", color: .cyan,
                                   title: "iCloud 同步（可选）",
                                   detail: "在你自己的设备之间同步，数据只在你的 iCloud 里。")
                    }
                    .frame(maxWidth: 460)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity)
            }
            primaryButton("继续") {
                withAnimation(.easeInOut(duration: 0.35)) { step = 1 }
            }
        }
    }

    // MARK: 隐私与条款

    private var privacyPage: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 26) {
                    VStack(spacing: 14) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 84, height: 84)
                            .background(Color.blue.gradient, in: Circle())
                        Text(reconfirming ? "条款有更新" : "你的隐私")
                            .font(.largeTitle.weight(.bold))
                        Text(reconfirming
                             ? "我们更新了《用户协议》和《隐私政策》，请阅读后确认。"
                             : "\(AppInfo.name)是一个只在你设备上运行的相册。")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 56)

                    VStack(alignment: .leading, spacing: 22) {
                        FeatureRow(systemImage: "person.crop.circle.badge.xmark", color: .green,
                                   title: "不收集任何信息",
                                   detail: "没有账号、没有广告，也没有第三方统计。")
                        FeatureRow(systemImage: "photo.badge.checkmark", color: .blue,
                                   title: "只读你选中的照片",
                                   detail: "通过系统选择器导入，不会访问你的整个照片图库。")
                        FeatureRow(systemImage: "lock.iphone", color: .indigo,
                                   title: "内容只属于你",
                                   detail: "只保存在你的设备和你自己的 iCloud 中，开发者无法访问。")
                    }
                    .frame(maxWidth: 460)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity)
            }

            VStack(spacing: 14) {
                agreementRow
                primaryButton("同意并开始使用", enabled: agreed) {
                    onAccept()
                }
                Button("不同意") {
                    showingDeclineNote = true
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)
        }
    }

    /// 勾选框 + 「我已阅读并同意《用户协议》和《隐私政策》」（书名号部分可点开全文）
    private var agreementRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { agreed.toggle() }
            } label: {
                Image(systemName: agreed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(agreed ? Color.accentColor : .secondary)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(agreed ? "已同意" : "未同意")
            Text(agreementText)
                .font(.subheadline)
                .environment(\.openURL, OpenURLAction { url in
                    showingDocument = LegalDocument(rawValue: url.host() ?? "")
                    return .handled
                })
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) { agreed.toggle() }
                }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: 520)
    }

    private var agreementText: AttributedString {
        var text = AttributedString("我已阅读并同意")
        var terms = AttributedString("《用户协议》")
        terms.link = URL(string: "legal://\(LegalDocument.terms.rawValue)")
        var and = AttributedString("和")
        and.foregroundColor = .secondary
        var privacy = AttributedString("《隐私政策》")
        privacy.link = URL(string: "legal://\(LegalDocument.privacy.rawValue)")
        text.foregroundColor = .secondary
        text.append(terms)
        text.append(and)
        text.append(privacy)
        return text
    }

    private func primaryButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: 460)
                .frame(height: 50)
        }
        .prominentButtonStyle()
        .buttonBorderShape(.capsule)
        .disabled(!enabled)
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }
}

private struct FeatureRow: View {
    let systemImage: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
