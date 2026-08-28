import SwiftUI

/// Duplicates get their own screen instead of the swipe deck, because the
/// decision here isn't "keep or toss" — it's "which one of these N is the
/// keeper". A group needs to be seen side by side.
struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @State private var tierFilter: DuplicateTier?
    @State private var detail: AssetSnapshot?

    /// Copies only. Moment groups get their own screen — putting them in this
    /// list was the mistake: a 108pt thumbnail is far too small to choose between
    /// two nearly identical shots, which is the entire task there.
    private var groups: [DuplicateGroup] {
        guard let t = tierFilter else { return model.copyGroups }
        return model.copyGroups.filter { $0.tier == t }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                filterBar

                if groups.isEmpty {
                    ContentUnavailableView("没有重复副本",
                                           systemImage: "checkmark.seal",
                                           description: Text("同一张图存两遍的情况已经处理完了。"))
                        .padding(.top, 40)
                }

                ForEach(groups) { group in
                    GroupCard(group: group) { detail = $0 }
                }
            }
            .padding(16)
        }
        .background(Palette.surface)
        .navigationTitle("重复副本")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.markAllOneTapGroups()
                } label: {
                    Label("一键标记安全组", systemImage: "wand.and.stars")
                }
                .disabled(model.oneTapGroups.isEmpty)
            }
        }
        .sheet(item: $detail) { AssetDetailView(snapshot: $0) }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill(nil, "全部 \(model.copyGroups.count)")
                ForEach([DuplicateTier.identical, .copy], id: \.rawValue) { t in
                    let n = model.copyGroups.filter { $0.tier == t }.count
                    if n > 0 { pill(t, "\(t.title) \(n)") }
                }
            }
        }
    }

    private func pill(_ tier: DuplicateTier?, _ label: String) -> some View {
        Button { tierFilter = tier } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(tierFilter == tier ? Palette.accent : Palette.raised,
                            in: Capsule())
                .foregroundStyle(tierFilter == tier ? .white : .secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct GroupCard: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroup
    let inspect: (AssetSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Palette.keep)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.tier.title) · \(group.members.count) 张")
                        .font(.subheadline.weight(.semibold))
                    Text(group.tier.blurb)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("+\(ByteFormat.string(model.reclaimable(for: group)))")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(Palette.keep)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(group.members) { m in
                        thumb(m)
                    }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                Text("保留：\(keeperReason)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Button {
                    model.markGroup(group)
                } label: {
                    Label("标记其余 \(model.discardable(for: group).count) 张",
                          systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.toss)

                Button {
                    model.skipGroup(group)
                } label: {
                    Label("全部保留", systemImage: "hand.raised")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var keeperReason: String {
        model.keeper(for: group) == group.keeperID
            ? group.keeperReason
            : "你手动指定的这一张"
    }

    private func thumb(_ m: AssetSnapshot) -> some View {
        let isKeeper = model.keeper(for: group) == m.id
        return VStack(spacing: 5) {
            AssetImageView(id: m.id, side: 130)
                .frame(width: 108, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isKeeper ? Palette.keep : .clear, lineWidth: 3)
                }
                .overlay(alignment: .topLeading) {
                    if isKeeper {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .padding(5)
                            .background(Palette.keep, in: Circle())
                            .foregroundStyle(.white)
                            .padding(5)
                    }
                }
                .onTapGesture { model.setKeeper(m.id, for: group) }
                .onLongPressGesture { inspect(m) }

            Text(ByteFormat.string(m.byteSize))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isKeeper ? Palette.keep : Color.secondary)
        }
    }
}
