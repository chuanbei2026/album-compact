import SwiftUI
import Photos

// MARK: - Palette

enum Palette {
    static let keep    = Color(red: 0.20, green: 0.78, blue: 0.55)
    static let toss    = Color(red: 0.95, green: 0.32, blue: 0.36)
    static let undo    = Color(red: 0.42, green: 0.62, blue: 0.98)
    static let accent  = Color(red: 0.32, green: 0.56, blue: 0.86)
    static let surface = Color(white: 0.09)
    static let raised  = Color(white: 0.14)
}

// MARK: - Asset image

/// Loads a PhotoKit asset by identifier and keeps it out of the view's identity,
/// so the swipe deck can recycle cards without re-decoding.
struct AssetImageView: View {
    let id: String
    var side: CGFloat = 420
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        // `aspectRatio(.fill)` reports a size LARGER than the proposal, and a
        // plain `.frame()` on an ancestor does not clip — so the image would
        // spill out over whatever sits next to it. Pinning it to the measured
        // box and clipping there is what actually contains it.
        GeometryReader { geo in
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Palette.raised)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .overlay {
                        ProgressView().controlSize(.small).tint(.secondary)
                    }
            }
        }
        .task(id: id) {
            // Take the cached frame synchronously so an already-loaded photo
            // appears in the same frame it is asked for — the deck depends on
            // this to swap cards without a blank beat.
            if let hit = ThumbnailProvider.shared.cached(id, side: side) {
                image = hit
            }
            // Then let the stream sharpen it in place. Note we do NOT clear
            // `image` first: dropping to the placeholder between a degraded and
            // a sharp frame is what reads as a flash.
            for await frame in ThumbnailProvider.shared.imageStream(for: id, side: side) {
                image = frame
            }
        }
    }
}

// MARK: - Chips & tiles

struct Chip: View {
    let text: String
    var icon: String?
    var tint: Color = .white.opacity(0.85)

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.caption2) }
            Text(text).font(.caption).fontWeight(.medium)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var tint: Color = .primary
    var icon: String?
    /// Set when the tile leads somewhere. A tile that is tappable has to *look*
    /// tappable, so this also draws the chevron.
    var isLink: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.caption).foregroundStyle(tint)
                }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isLink {
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            if isLink {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tint.opacity(0.28), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct CategoryRow: View {
    let category: CleanupCategory
    let count: Int
    let bytes: Int64
    var badge: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: category.systemImage)
                .font(.title3)
                .frame(width: 40, height: 40)
                .background(Palette.accent.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .foregroundStyle(Palette.accent)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(category.title).font(.body.weight(.medium))
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Palette.keep.opacity(0.22), in: Capsule())
                            .foregroundStyle(Palette.keep)
                    }
                }
                Text("\(count) 项 · 约 \(ByteFormat.string(bytes))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Progress banner

struct ScanBanner: View {
    let stage: ScanStage
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(stage.label).font(.subheadline.weight(.medium))
                    if let eta = stage.etaText {
                        Text("还需\(eta) · 可以先去滑已经找出来的")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let f = stage.fraction {
                    Text("\(Int(f * 100))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button("停止", action: onCancel)
                    .font(.caption).buttonStyle(.plain)
                    .foregroundStyle(Palette.toss)
            }
            ProgressView(value: stage.fraction ?? 0.02)
                .tint(Palette.accent)
        }
        .padding(14)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Zoomable detail

struct AssetDetailView: View {
    let snapshot: AssetSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AssetImageView(id: snapshot.id, side: 1100, contentMode: .fit)
                .scaleEffect(scale)
                .gesture(MagnifyGesture()
                    .onChanged { scale = max(1, min(5, $0.magnification)) }
                    .onEnded { _ in withAnimation(.spring) { scale = 1 } })
                .onTapGesture(count: 2) {
                    withAnimation(.spring) { scale = scale > 1 ? 1 : 2.5 }
                }

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                MetadataStrip(snapshot: snapshot)
            }
            .padding()
        }
        .preferredColorScheme(.dark)
    }
}

struct MetadataStrip: View {
    let snapshot: AssetSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Chip(text: snapshot.creationDate.formatted(date: .abbreviated, time: .shortened),
                 icon: "calendar")
            Chip(text: ByteFormat.string(snapshot.byteSize), icon: "internaldrive")
            Chip(text: "\(snapshot.pixelWidth)×\(snapshot.pixelHeight)", icon: "aspectratio")
            if snapshot.isFavorite { Chip(text: "收藏", icon: "heart.fill", tint: .pink) }
        }
        .padding(.horizontal, 4)
    }
}
