import SwiftUI

/// iPad triage.
///
/// On a phone, swiping is the fastest input you have. On an iPad — especially
/// with a keyboard or trackpad — it isn't: your eyes can take in twelve photos
/// at once and your finger can tap them faster than it can swipe them. So the
/// iPad gets a contact sheet where marking is a tap, plus the same swipe deck
/// one tap away for when it's held like a phone.
struct TriageGridView: View {
    @Environment(AppModel.self) private var model
    @Binding var route: Route?
    let category: CleanupCategory

    @State private var detail: AssetSnapshot?
    @State private var columns: Double = 4

    private var items: [Candidate] {
        model.candidates.filter { $0.category == category }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: gridMin), spacing: 10)],
                      spacing: 10) {
                ForEach(items) { c in
                    Cell(candidate: c,
                         marked: model.isMarked(c.id),
                         toggle: { toggle(c) },
                         inspect: { detail = c.snapshot })
                }
            }
            .padding(16)
        }
        .background(Palette.surface)
        .navigationTitle(category.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { route = .deck(category) } label: {
                    Label("滑动模式", systemImage: "rectangle.on.rectangle.angled")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    for c in items where !model.isMarked(c.id) { toggle(c) }
                } label: {
                    Label("全部标记", systemImage: "checklist")
                }
            }
            ToolbarItem(placement: .bottomBar) {
                HStack(spacing: 12) {
                    Image(systemName: "square.grid.3x3").font(.caption)
                    Slider(value: $columns, in: 2...8, step: 1).frame(width: 160)
                    Spacer()
                    Text("\(items.count) 项 · 已标记 \(items.filter { model.isMarked($0.id) }.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .sheet(item: $detail) { AssetDetailView(snapshot: $0) }
    }

    private var gridMin: CGFloat {
        // Larger slider value ⇒ more columns ⇒ smaller minimum cell.
        max(90, 700 / columns)
    }

    private func toggle(_ c: Candidate) {
        if model.isMarked(c.id) {
            Store.shared.unmark(c.id)
        } else {
            Store.shared.mark(c.snapshot, category: c.category)
            if let e = Store.shared.visionCache[c.id]?.embedding {
                Store.shared.learnDeletability(embedding: e, willDelete: true)
            }
        }
        model.refreshPending()
    }

    private struct Cell: View {
        let candidate: Candidate
        let marked: Bool
        let toggle: () -> Void
        let inspect: () -> Void

        var body: some View {
            // 3:4 rather than square: a phone screenshot squeezed into a square
            // shows only its middle, which is the least identifying part of it.
            AssetImageView(id: candidate.snapshot.id, side: 220)
                .aspectRatio(0.75, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(marked ? Palette.toss : .white.opacity(0.08),
                                      lineWidth: marked ? 3 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: marked ? "trash.circle.fill" : "circle.dashed")
                        .font(.title3)
                        .symbolRenderingMode(marked ? .palette : .monochrome)
                        .foregroundStyle(marked ? AnyShapeStyle(.white) : AnyShapeStyle(.white),
                                         marked ? AnyShapeStyle(Palette.toss)
                                                : AnyShapeStyle(Color.clear))
                        .shadow(color: .black.opacity(0.6), radius: 3)
                        .padding(7)
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 4) {
                        Text(ByteFormat.string(candidate.snapshot.byteSize))
                        Text("·")
                        Text("\(Int(candidate.confidence * 100))%")
                    }
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(6)
                }
                .opacity(marked ? 0.55 : 1)
                .onTapGesture(perform: toggle)
                .onLongPressGesture(perform: inspect)
                .contextMenu {
                    Button("查看原图", systemImage: "eye") { inspect() }
                    Button(marked ? "取消标记" : "标记删除",
                           systemImage: marked ? "arrow.uturn.backward" : "trash") { toggle() }
                }
        }
    }
}
