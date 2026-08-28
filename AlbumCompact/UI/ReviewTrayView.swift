import SwiftUI

/// The safety net. Nothing in this app touches the library until the user
/// presses the button on this screen.
struct ReviewTrayView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var working = false
    @State private var detail: AssetSnapshot?
    @State private var scopeAllPending = true

    private var items: [PendingItem] {
        scopeAllPending ? model.pendingItems : model.duePendingItems
    }

    private var scopedBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summary

                if model.pendingCount == 0 {
                    ContentUnavailableView("清单是空的",
                                           systemImage: "tray",
                                           description: Text("去首页滑几张，或者一键处理重复照片。"))
                        .padding(.top, 40)
                } else {
                    grid
                }
            }
            .padding(16)
        }
        .background(Palette.surface)
        .navigationTitle("待删清单")
        .toolbar {
            if model.pendingCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("全部恢复", role: .destructive) { model.restoreAll() }
                        .tint(Palette.undo)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.pendingCount > 0 { executeBar }
        }
        .sheet(item: $detail) { AssetDetailView(snapshot: $0) }
        .alert("确认执行删除？", isPresented: $confirming) {
            Button("取消", role: .cancel) {}
            Button("删除 \(items.count) 项", role: .destructive) {
                Task {
                    working = true
                    await model.execute(ids: items.map(\.id))
                    working = false
                }
            }
        } message: {
            Text("""
            这会把 \(items.count) 项移入系统「最近删除」，释放 \(ByteFormat.string(scopedBytes))。
            iOS 会再弹一次系统确认框。照片在「最近删除」里还能保留 30 天，之后才真正释放空间。
            """)
        }
        .alert("结果", isPresented: .init(
            get: { model.lastDeletionMessage != nil },
            set: { if !$0 { model.lastDeletionMessage = nil } })) {
            Button("好") { model.lastDeletionMessage = nil }
        } message: {
            Text(model.lastDeletionMessage ?? "")
        }
    }

    private var summary: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatTile(value: "\(model.pendingCount)", label: "已标记",
                         tint: Palette.toss, icon: "trash")
                StatTile(value: ByteFormat.string(model.pendingBytes),
                         label: "可释放", tint: Palette.keep, icon: "internaldrive")
                StatTile(value: "\(model.duePendingItems.count)", label: "已到期",
                         tint: Palette.accent, icon: "clock.badge.checkmark")
            }

            if model.settings.grace != .immediate {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(Palette.accent)
                    Text("""
                    你设置了「\(model.settings.grace.title)」的缓冲期。App 无法在后台自己动手删除，\
                    到期时会给你一条提醒，回来一键执行即可。
                    """)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Palette.accent.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Picker("范围", selection: $scopeAllPending) {
                    Text("全部 \(model.pendingCount)").tag(true)
                    Text("仅已到期 \(model.duePendingItems.count)").tag(false)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
            ForEach(items) { item in
                let snap = model.snapshot(for: item.id)
                ZStack(alignment: .topTrailing) {
                    AssetImageView(id: item.id, side: 130)
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onTapGesture { if let snap { detail = snap } }

                    Button {
                        model.restore(item.id)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.caption2.weight(.bold))
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(ByteFormat.string(item.bytes))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(5)
                }
            }
        }
    }

    private var executeBar: some View {
        VStack(spacing: 8) {
            Button {
                confirming = true
            } label: {
                HStack {
                    if working { ProgressView().tint(.white) }
                    else { Image(systemName: "trash.fill") }
                    Text(working
                         ? "执行中…"
                         : "执行删除 · \(items.count) 项 · \(ByteFormat.string(scopedBytes))")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.toss)
            .controlSize(.large)
            .disabled(items.isEmpty || working)

            Text("删除后仍可在系统「照片 → 最近删除」里找回 30 天")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }
}
