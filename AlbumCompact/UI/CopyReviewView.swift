import SwiftUI

/// Reviewing **exact** duplicates — one row per group, everything pre-ticked.
///
/// Only pixel-identical groups appear here. That is the one case with no
/// decision in it: the extras are the same file stored again, so they arrive
/// already checked and the user's job is to glance down the list and untick
/// anything they want to keep. Versions that *differ* — a resized copy, a
/// re-compressed one — are a real choice and go to the picker instead, where
/// they can be seen at full size.
///
/// The evidence is stated in plain language. An earlier version printed the
/// content hash and the dHash/pHash distances; that is how the app decided, not
/// something the user needs to read.
struct CopyReviewView: View {
    @Environment(AppModel.self) private var model
    @State private var detail: AssetSnapshot?
    @State private var confirmAll = false

    /// Exact matches only.
    private var groups: [DuplicateGroup] { model.identicalGroups }
    /// Groups the user has unticked stay on screen but are excluded from the sweep.
    @State private var unticked: Set<String> = []

    private var ticked: [DuplicateGroup] { groups.filter { !unticked.contains($0.id) } }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                explainer
                if groups.isEmpty {
                    ContentUnavailableView("没有完全一致的重复", systemImage: "checkmark.seal",
                                           description: Text("同一张图存两遍的情况已经处理完了。"))
                        .padding(.top, 40)
                } else {
                    ForEach(groups) { g in
                        GroupRow(group: g,
                                 isTicked: !unticked.contains(g.id),
                                 toggle: {
                                     if unticked.contains(g.id) { unticked.remove(g.id) }
                                     else { unticked.insert(g.id) }
                                     Haptics.tap(.light)
                                 },
                                 inspect: { detail = $0 })
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .background(Palette.surface)
        .navigationTitle("完全一致的重复")
        .safeAreaInset(edge: .bottom) {
            if !groups.isEmpty { bottomBar }
        }
        .sheet(item: $detail) { AssetDetailView(snapshot: $0) }
        .alert("清理已勾选的 \(ticked.count) 组？", isPresented: $confirmAll) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) {
                for g in ticked { model.markGroup(g) }
            }
        } message: {
            Text("""
            每组留下一张，其余 \
            \(ticked.reduce(0) { $0 + model.discardable(for: $1).count }) 张标记删除。
            标记后不会立刻删除，你还会在待删清单里看到它们。
            """)
        }
    }

    private var explainer: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.keep)
            Text("""
            这里每一组都是**同一张图存了多份** —— 像素、尺寸、文件大小全都一样，\
            删掉多余的不会丢任何东西，所以已经替你勾好了。
            不想动的可以取消勾选。分辨率或画质**有差别**的那些不在这里，\
            它们需要你看大图来挑。
            """)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Palette.keep.opacity(0.09))
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            Button { confirmAll = true } label: {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("清理已勾选的 \(ticked.count) 组 · 释放 \(ByteFormat.string(ticked.reduce(0) { $0 + model.reclaimable(for: $1) }))")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(ticked.isEmpty)
            Text("点缩略图看大图。取消勾选就不会动这一组。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.ultraThinMaterial)
    }
}

// MARK: - One group, one row

private struct GroupRow: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroup
    let isTicked: Bool
    let toggle: () -> Void
    let inspect: (AssetSnapshot) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggle) {
                Image(systemName: isTicked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isTicked ? Palette.keep : .secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 7) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(group.members.enumerated()), id: \.element.id) { i, m in
                            AssetImageView(id: m.id, side: 180)
                                .frame(width: 62, height: 62)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(i == 0 ? Palette.keep : .clear, lineWidth: 2.5)
                                }
                                .overlay(alignment: .bottomLeading) {
                                    // Say which one stays, in words, rather than
                                    // leaving a star to be decoded.
                                    if i == 0 {
                                        Text("留这张")
                                            .font(.system(size: 8, weight: .bold))
                                            .padding(.horizontal, 4).padding(.vertical, 1.5)
                                            .background(Palette.keep, in: Capsule())
                                            .foregroundStyle(.white)
                                            .padding(3)
                                    }
                                }
                                .opacity(i == 0 ? 1 : 0.5)
                                // Tapping opens it full-screen. There is nothing to
                                // choose in an exact group, so a tap should show
                                // the photo rather than reshuffle the selection.
                                .onTapGesture { inspect(m) }
                        }
                    }
                }
                ForEach(model.differenceSummary(for: group), id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .trailing, spacing: 5) {
                Text("+\(ByteFormat.string(model.reclaimable(for: group)))")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.keep)
                Button {
                    // "I want to keep all of these" — takes the group off the list
                    // permanently instead of leaving it to be re-proposed.
                    model.skipGroup(group)
                } label: {
                    Text("都留着")
                        .font(.caption2)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.white.opacity(0.08), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .opacity(isTicked ? 1 : 0.5)
    }
}
