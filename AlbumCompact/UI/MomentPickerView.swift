import SwiftUI

/// The "look at these properly and choose" screen.
///
/// This is deliberately not a list row with 108pt thumbnails. Choosing between
/// four nearly identical shots of the same subject *is* the task here, and it
/// needs enough pixels to see which one has open eyes and which one is soft —
/// so the layout gives the whole group one screen at a time: a large preview of
/// the current pick, and a filmstrip of every frame under it.
///
/// Selection is **multi-choice**, not a single keeper. Two similar shots are
/// often both worth keeping, and a UI that only lets you crown one of them
/// forces a decision the user did not want to make.
///
/// Shared by two kinds of group: shots of the same moment, and differing
/// versions of one shot. Both need the same thing — look at them large, then
/// choose — so they get the same screen with different wording.
struct MomentPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var groupIndex = 0
    @State private var zoomed: AssetSnapshot?

    /// Which pile this screen is working through.
    enum Mode { case moment, variant }
    var mode: Mode = .moment

    private var groups: [DuplicateGroup] {
        mode == .moment ? model.momentGroups : model.variantGroups
    }
    private var titleText: String {
        mode == .moment ? String(localized: "同一时刻多张")
                        : String(localized: "同一张的不同版本")
    }
    private var promptText: String {
        mode == .moment ? String(localized: "这一组是同一个场景的多张，挑出你要留的")
                        : String(localized: "这一组是同一张照片的不同版本，挑出你要留的")
    }
    private var group: DuplicateGroup? {
        groupIndex >= 0 && groupIndex < groups.count ? groups[groupIndex] : nil
    }

    var body: some View {
        Group {
            if let group {
                content(group)
            } else {
                ContentUnavailableView(
                    "没有需要挑选的组",
                    systemImage: "checkmark.seal",
                    description: Text("这一类都处理完了。"))
            }
        }
        .background(Palette.surface)
        .navigationTitle(titleText)
        .sheet(item: $zoomed) { AssetDetailView(snapshot: $0) }
    }

    private func content(_ group: DuplicateGroup) -> some View {
        let keeper = model.keeper(for: group)
        let discard = model.discardable(for: group)
        let keptCount = model.kept(in: group).count
        return VStack(spacing: 0) {
            header(group)

            // Big preview of the current pick.
            ZStack(alignment: .bottomLeading) {
                AssetImageView(id: keeper, side: 700, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let s = group.members.first(where: { $0.id == keeper }) {
                            zoomed = s
                        }
                    }
                HStack(spacing: 6) {
                    Chip(text: "已选 \(keptCount) 张保留", icon: "checkmark.circle.fill",
                         tint: Palette.keep)
                    Chip(text: "点图放大", icon: "arrow.up.left.and.arrow.down.right")
                }
                .padding(14)
            }

            filmstrip(group, keeper: keeper)
            actions(group, discard: discard)
        }
    }

    // MARK: chrome

    private func header(_ group: DuplicateGroup) -> some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        groupIndex = max(0, groupIndex - 1)
                    }
                } label: {
                    Image(systemName: "chevron.left").frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(groupIndex == 0)
                .opacity(groupIndex == 0 ? 0.35 : 1)

                Spacer()
                VStack(spacing: 1) {
                    Text("第 \(groupIndex + 1) / \(groups.count) 组")
                        .font(.subheadline.weight(.semibold))
                        Text("\(group.members.count) 张 · \(group.members[0].creationDate.formatted(.dateTime.month().day().hour().minute()))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()

                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        groupIndex = min(groups.count - 1, groupIndex + 1)
                    }
                } label: {
                    Image(systemName: "chevron.right").frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(groupIndex >= groups.count - 1)
                .opacity(groupIndex >= groups.count - 1 ? 0.35 : 1)
            }
            ProgressView(value: Double(groupIndex + 1), total: Double(max(groups.count, 1)))
                .tint(Palette.accent)
                .scaleEffect(y: 0.6)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func filmstrip(_ group: DuplicateGroup, keeper: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(group.members) { m in
                    let isKeeper = model.isKept(m.id, in: group)
                    VStack(spacing: 5) {
                        AssetImageView(id: m.id, side: 240)
                            .frame(width: 92, height: 118)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(isKeeper ? Palette.keep : .white.opacity(0.10),
                                                  lineWidth: isKeeper ? 3 : 1)
                            }
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: isKeeper
                                      ? "checkmark.circle.fill" : "trash.circle.fill")
                                    .font(.body)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white,
                                                     isKeeper ? Palette.keep : Palette.toss)
                                    .padding(4)
                            }
                            .opacity(isKeeper ? 1 : 0.5)
                        // Quality hints, so the choice is informed rather than
                        // a coin flip between two thumbnails.
                        VStack(spacing: 1) {
                            ForEach(model.qualityBadges(for: m, in: group), id: \.self) { b in
                                Text(b)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(Palette.keep)
                            }
                            Text(ByteFormat.string(m.byteSize))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.toggleKeep(m.id, in: group) }
                    .onLongPressGesture { zoomed = m }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Palette.raised)
    }

    private func actions(_ group: DuplicateGroup, discard: [AssetSnapshot]) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    model.markGroup(group)
                    clampIndex()
                } label: {
                    Label(discard.isEmpty ? "没有要删的" : "删掉未选中的 \(discard.count) 张",
                          systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.toss)
                .controlSize(.large)
                .disabled(discard.isEmpty)

                Button {
                    // Keep every one of them and take the group off the list for
                    // good — "I want both of these" needs to be sayable.
                    model.skipGroup(group)
                    clampIndex()
                } label: {
                    Label("都留着", systemImage: "hand.raised")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            VStack(spacing: 2) {
                ForEach(model.differenceSummary(for: group), id: \.self) { line in
                    Text(line).font(.caption2).foregroundStyle(.secondary)
                }
                Text("可释放 \(ByteFormat.string(model.reclaimable(for: group)))，标记后不会立刻删除")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .multilineTextAlignment(.center)
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    /// Groups disappear from the list as they are handled, so the cursor has to
    /// stay inside the shrinking array rather than running off the end.
    private func clampIndex() {
        groupIndex = min(groupIndex, max(0, groups.count - 1))
    }
}
