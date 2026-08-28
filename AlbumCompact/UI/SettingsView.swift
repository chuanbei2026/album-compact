import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var resetConfirm = false

    var body: some View {
        Form {
            Section {
                Picker("缓冲期", selection: Binding(
                    get: { model.settings.grace },
                    set: { var s = model.settings; s.grace = $0; model.settings = s })) {
                    ForEach(GracePeriod.allCases) { Text($0.title).tag($0) }
                }
                Toggle("待删期间从相册隐藏", isOn: bind(\.hideWhilePending))
                Toggle("同时放进「待删」相簿", isOn: bind(\.stageInAlbum))
            } header: {
                Text("删除节奏")
            } footer: {
                Text("""
                标记 → 缓冲期 → 你确认执行 → 进入系统「最近删除」再放 30 天。
                注意：第三方 App 不能在后台自己执行删除，所以缓冲期到点是一条提醒，不是自动动手。
                """)
            }

            Section {
                Toggle("跳过收藏的照片", isOn: bind(\.rules.skipFavorites))
                Toggle("跳过带定位的照片", isOn: bind(\.rules.skipWithLocation))
                Toggle("跳过 Live Photo", isOn: bind(\.rules.skipLivePhotos))
                Toggle("跳过编辑过的照片", isOn: bind(\.rules.skipEdited))
                Toggle("跳过单据 / 票据 / 证件", isOn: bind(\.rules.skipDocuments))
                Stepper(value: Binding(
                    get: { model.settings.rules.skipRecentDays },
                    set: { var s = model.settings; s.rules.skipRecentDays = $0; model.settings = s }),
                        in: 0...30) {
                    Text("跳过最近 \(model.settings.rules.skipRecentDays) 天内拍的")
                }
            } header: {
                Text("保护规则")
            } footer: {
                Text("这些照片永远不会出现在待清理队列里。改动后需要重新扫描才生效。")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("同一时刻的时间窗")
                        Spacer()
                        Text(strictnessLabel).foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { model.settings.similarityStrictness },
                        set: { var s = model.settings; s.similarityStrictness = $0; model.settings = s }),
                           in: 0...1)
                }
                Toggle("把视频也纳入去重", isOn: bind(\.includeVideos))
            } header: {
                Text("「同一时刻」的时间窗")
            } footer: {
                Text("""
                滑块只决定「几秒内算同一时刻」—— 这是个真正的判断题。当前约 \(Int(momentWindowSeconds)) 秒。

                副本判定不可调，因为它由实测决定：真正的同一张图副本的 pHash 汉明距离 ≤ 1，放宽只会制造误判、多抓不到一张真副本。
                截图永远只能进「完全一致」这一档 —— 两张不同的收据在缩略图尺度上距离为 0，无法区分，所以不参与副本和连拍。
                """)
            }

            Section {
                Toggle("启用本机学习", isOn: bind(\.enableLearning))
                LabeledContent("学习状态", value: model.learningSummary)
                Stepper(value: Binding(
                    get: { model.settings.deckBatchSize },
                    set: { var s = model.settings; s.deckBatchSize = $0; model.settings = s }),
                        in: 20...200, step: 10) {
                    Text("每轮 \(model.settings.deckBatchSize) 张")
                }
                Button("清空学习数据", role: .destructive) { resetConfirm = true }
            } header: {
                Text("本机模型")
            } footer: {
                Text("""
                分类用的是 Apple Vision 的 FeaturePrint（768 维，跑在神经引擎上）作为固定骨干，\
                上面挂一个几千参数的线性头，用你每一次滑动当训练样本。
                没有任何模型下载、没有联网、没有数据离开这台设备。
                """)
            }

            #if DEBUG
            // Diagnostics, not a product feature: shown while developing, absent
            // from release builds — which also keeps 23 interpolated log strings
            // out of the localisation surface.
            Section("扫描日志") {
                if model.logs.isEmpty {
                    Text("还没有日志").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            #endif

            Section("累计成果") {
                LabeledContent("已释放", value: ByteFormat.string(Store.shared.lifetimeDeletedBytes))
                LabeledContent("已删除", value: "\(Store.shared.lifetimeDeletedCount) 项")
            }
        }
        .navigationTitle("设置")
        .alert("清空学习数据？", isPresented: $resetConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { Store.shared.resetClassifier() }
        } message: {
            Text("分类头和可删性模型都会归零，回到出厂的规则判断。照片不受影响。")
        }
    }

    /// Mirrors the mapping in `ScanEngine`: 8 s at strict … 60 s at loose.
    private var momentWindowSeconds: Double {
        5 + (1 - model.settings.similarityStrictness) * 35
    }

    private var strictnessLabel: String {
        String(localized: "\(Int(momentWindowSeconds)) 秒内")
    }

    private func bind(_ key: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: key] },
                set: { var s = model.settings; s[keyPath: key] = $0; model.settings = s })
    }
}
