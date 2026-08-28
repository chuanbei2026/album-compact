import SwiftUI

/// The embedding map: every screenshot as a point, positioned by PCA of its
/// 768-dimensional FeaturePrint vector, coloured by the app it was labelled as.
///
/// This is a diagnostic, not decoration. It answers questions the list cannot:
/// is this app actually one tight cluster or three separate screens? are two
/// labels sitting on top of each other (so one of them is wrong)? is there a
/// dense unlabeled blob worth naming next?
struct EmbeddingMapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var points: [MapPoint] = []
    @State private var building = true
    @State private var selected: MapPoint?

    struct MapPoint: Identifiable, Hashable {
        var id: String
        var x: Double
        var y: Double
        var app: String?
    }

    /// Projection is O(n · dim) per power iteration, so cap the sample. A scatter
    /// with 8000 overlapping dots is unreadable anyway.
    private let sampleCap = 600

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.surface.ignoresSafeArea()
                if building {
                    ProgressView("正在投影…").tint(Palette.accent)
                } else if points.count < 3 {
                    ContentUnavailableView(
                        "样本太少", systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("至少需要 3 张带向量的截图。模拟器上取不到向量。"))
                } else {
                    VStack(spacing: 12) {
                        scatter
                        legend
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Embedding 分布")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { build() }
    }

    /// Data-space bounds, computed once rather than inside the view builder.
    private var bounds: (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let xs = points.map(\.x), ys = points.map(\.y)
        return (xs.min() ?? 0, xs.max() ?? 1, ys.min() ?? 0, ys.max() ?? 1)
    }

    private func place(_ p: MapPoint, in size: CGSize) -> CGPoint {
        let b = bounds
        let pad: CGFloat = 22
        let w = max(size.width - pad * 2, 1)
        let h = max(size.height - pad * 2, 1)
        let nx = (b.maxX - b.minX) < 1e-6 ? 0.5 : (p.x - b.minX) / (b.maxX - b.minX)
        let ny = (b.maxY - b.minY) < 1e-6 ? 0.5 : (p.y - b.minY) / (b.maxY - b.minY)
        return CGPoint(x: pad + CGFloat(nx) * w, y: pad + CGFloat(1 - ny) * h)
    }

    private var scatter: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Palette.raised)

                Canvas { ctx, size in
                    for p in points {
                        let c = place(p, in: size)
                        let r: CGFloat = p.id == selected?.id ? 7 : 4.5
                        // A surface-coloured ring keeps overlapping dots readable.
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r - 1.5, y: c.y - r - 1.5,
                                                        width: (r + 1.5) * 2,
                                                        height: (r + 1.5) * 2)),
                                 with: .color(Palette.raised))
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r,
                                                        width: r * 2, height: r * 2)),
                                 with: .color(colorFor(p.app)))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    selected = points.min {
                        hypot(place($0, in: geo.size).x - location.x,
                              place($0, in: geo.size).y - location.y)
                            < hypot(place($1, in: geo.size).x - location.x,
                                    place($1, in: geo.size).y - location.y)
                    }
                }

                if let s = selected {
                    let c = place(s, in: geo.size)
                    VStack(spacing: 4) {
                        AssetImageView(id: s.id, side: 200)
                            .frame(width: 60, height: 78)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(s.app ?? "未命名")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .position(x: min(max(c.x, 46), geo.size.width - 46),
                              y: max(c.y - 66, 54))
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(appNames, id: \.self) { name in
                    HStack(spacing: 5) {
                        Circle().fill(colorFor(name)).frame(width: 9, height: 9)
                        Text(name).font(.caption)
                    }
                }
                HStack(spacing: 5) {
                    Circle().fill(colorFor(nil)).frame(width: 9, height: 9)
                    Text("未命名").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var appNames: [String] {
        Array(Set(points.compactMap(\.app))).sorted()
    }

    /// Colour follows the app's position in a stable, sorted name list — never
    /// the order points happen to arrive in, so a label keeps its colour between
    /// sessions.
    private func colorFor(_ app: String?) -> Color {
        guard let app, let i = appNames.firstIndex(of: app) else {
            return Color.white.opacity(0.22)
        }
        return Self.palette[i % Self.palette.count]
    }

    /// The same validated dark-surface categorical ramp the history charts use.
    private static let palette: [Color] = [
        Color(red: 0.224, green: 0.529, blue: 0.898),
        Color(red: 0.851, green: 0.349, blue: 0.149),
        Color(red: 0.098, green: 0.620, blue: 0.439),
        Color(red: 0.788, green: 0.522, blue: 0.000),
        Color(red: 0.835, green: 0.318, blue: 0.506),
        Color(red: 0.000, green: 0.514, blue: 0.000),
        Color(red: 0.565, green: 0.522, blue: 0.914),
        Color(red: 0.902, green: 0.404, blue: 0.404)
    ]

    private func build() {
        let vision = Store.shared.visionCache
        var ids: [String] = []
        var vecs: [[Float]] = []
        for s in model.snapshots where DuplicateFinder.isScreenLike(s) {
            guard let e = vision[s.id]?.embedding,
                  e.revision == VisionAnalyzer.featurePrintRevision else { continue }
            ids.append(s.id)
            vecs.append(e.values)
            if ids.count >= sampleCap { break }
        }
        guard vecs.count >= 3 else { building = false; return }
        let projected = EmbeddingProjection.pca2D(vecs)
        points = zip(ids, projected).map { id, p in
            MapPoint(id: id, x: Double(p.x), y: Double(p.y), app: model.appName(for: id))
        }
        building = false
    }
}
