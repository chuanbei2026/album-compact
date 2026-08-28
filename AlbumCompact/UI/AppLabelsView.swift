import SwiftUI

/// Naming apps, and setting a policy per app.
///
/// The user never tags photos one by one. Screenshots from one app sit at cosine
/// 0.95–0.999 of each other, so they arrive already clustered and the user names
/// the *cluster* — one action covering hundreds of photos.
///
/// Naming is not the point on its own. The point is the policy it unlocks:
/// "微信截图默认删除，支付宝账单默认保留" is a rule the user can state once and have
/// applied forever, which no generic category can express.
struct AppLabelsView: View {
    @Environment(AppModel.self) private var model
    @State private var naming: AppCluster?
    @State private var draftName = ""
    @State private var draftCategory: CleanupCategory = .screenshot
    @State private var showMap = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                explainer

                if !model.appClusters.isEmpty { pending }
                if !model.appLabels.isEmpty { known }

                if model.appClusters.isEmpty && model.appLabels.isEmpty { empty }
            }
            .padding(16)
        }
        .background(Palette.surface)
        .navigationTitle("按 App 归类")
        .toolbar {
            if !model.appLabels.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showMap = true } label: {
                        Label("分布图", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
            }
        }
        .sheet(isPresented: $showMap) { EmbeddingMapView() }
        .sheet(item: $naming) { cluster in
            namingSheet(cluster)
        }
    }

    private var explainer: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Palette.accent)
            Text("""
            同一个 App 的截图长得几乎一样，所以它们会自己抱成一团。\
            你只需要给每一团**命名一次**，几百张就都归好类了 —— 不用一张张标。
            命名同时会训练分类器：手写规则在 22 张测试图上只能做到 14 张对，\
            标注过之后是 22 张全对。
            """)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Palette.accent.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: unnamed clusters

    private var pending: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("待命名 · \(model.appClusters.count) 团").font(.headline)
            ForEach(model.appClusters) { c in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(c.memberIDs.count) 张 · \(ByteFormat.string(c.bytes))")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        // Cohesion is the loosest member's similarity to the
                        // centroid — it says how confident the grouping is, which
                        // the user deserves to see before naming it.
                        Text(String(format: "内聚 %.2f", c.cohesion))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(c.cohesion > 0.95 ? Palette.keep : .secondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(c.memberIDs.prefix(8), id: \.self) { id in
                                AssetImageView(id: id, side: 200)
                                    .frame(width: 64, height: 82)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            if c.memberIDs.count > 8 {
                                Text("+\(c.memberIDs.count - 8)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(width: 44, height: 82)
                            }
                        }
                    }
                    Button {
                        draftName = c.suggestedName ?? ""
                        draftCategory = .screenshot
                        naming = c
                    } label: {
                        Label(c.suggestedName.map { "看起来像「\($0)」，确认？" } ?? "给这一团命名",
                              systemImage: "tag")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(14)
                .background(Palette.raised,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    // MARK: named apps

    private var known: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("已命名 · \(model.appLabels.count) 个 App").font(.headline)
            ForEach(model.appLabels) { label in
                AppLabelRow(label: label)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.3x3.square")
                .font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("还没有可归类的截图").font(.headline)
            Text("""
            扫描完成后，截图会按外观自动分团出现在这里。
            注意：分团依赖 Vision 的向量，模拟器上取不到，只有真机能用。
            """)
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 50)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: naming sheet

    private func namingSheet(_ cluster: AppCluster) -> some View {
        NavigationStack {
            Form {
                Section("这一团是哪个 App？") {
                    TextField("例如 微信、原神、支付宝", text: $draftName)
                        .textInputAutocapitalization(.never)
                    if !model.appLabels.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(model.appLabels) { l in
                                    Button(l.name) { draftName = l.name }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                Section {
                    Picker("类别", selection: $draftCategory) {
                        ForEach(CleanupCategory.learnable) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("这个 App 的截图算哪一类")
                } footer: {
                    Text("""
                    这一项会用这一团里的**每一张**去训练本机的分类器 —— \
                    一次命名等于几百个样本。之后同类截图不用再靠手写规则猜。
                    「地图截图」「网页 / 社交截图」没有可靠的手写规则，\
                    只有这样标注过才会出现。
                    """)
                }
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(cluster.memberIDs.prefix(10), id: \.self) { id in
                                AssetImageView(id: id, side: 200)
                                    .frame(width: 60, height: 78)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                } header: {
                    Text("这一团包含 \(cluster.memberIDs.count) 张")
                }
            }
            .navigationTitle("命名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { naming = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        model.nameCluster(cluster, as: draftName, category: draftCategory)
                        naming = nil
                    }
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - One named app

private struct AppLabelRow: View {
    @Environment(AppModel.self) private var model
    let label: AppLabel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: label.category?.systemImage ?? "app.dashed")
                    .foregroundStyle(Palette.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label.name).font(.body.weight(.medium))
                    Text("\(label.sampleCount) 张 · \(label.centroids.count) 种界面"
                         + (label.category.map { " · \($0.title)" } ?? ""))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if expanded {
                VStack(spacing: 0) {
                    Toggle("默认排在前面（多半是垃圾）", isOn: Binding(
                        get: { label.preferDelete },
                        set: { var l = label; l.preferDelete = $0; if $0 { l.preferKeep = false }
                               Store.shared.updateLabel(l); model.refreshAppClusters() }))
                    Divider().overlay(Color.white.opacity(0.06))
                    Toggle("永远不要问我（一律保留）", isOn: Binding(
                        get: { label.preferKeep },
                        set: { var l = label; l.preferKeep = $0; if $0 { l.preferDelete = false }
                               Store.shared.updateLabel(l); model.refreshAppClusters() }))
                    Divider().overlay(Color.white.opacity(0.06))
                    Button("删除这个标签", role: .destructive) {
                        Store.shared.deleteLabel(label.id)
                        model.refreshAppClusters()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                }
                .font(.subheadline)
            }
        }
        .padding(14)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
