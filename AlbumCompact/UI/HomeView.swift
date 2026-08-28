import SwiftUI

/// Home.
///
/// This screen accumulated one card per feature until it was eight stacked boxes
/// — every one of them competing for the same attention, none of them telling
/// you what to do first. It is now three regions:
///
///   1. one summary line      — how big, how much is recoverable
///   2. one primary action    — the safe sweep, when there is one
///   3. one list of work      — every remaining job as an identical row
///
/// Consistent rows beat individual cards here: the jobs differ in *kind*, not in
/// importance, and a row list lets you compare their sizes at a glance, which is
/// how you actually decide what to do next.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Binding var route: Route?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                summary
                if model.stage.isRunning {
                    ScanBanner(stage: model.stage) { model.cancelScan() }
                }
                if !model.identicalGroups.isEmpty { sweepButton }
                workList
            }
            .padding(16)
            .padding(.bottom, model.pendingCount > 0 ? 8 : 0)
        }
        .background(Palette.surface)
        .navigationTitle("相册瘦身")
        .safeAreaInset(edge: .bottom) {
            if model.pendingCount > 0 { pendingBar }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.stage.isRunning)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { route = .settings } label: { Image(systemName: "gearshape") }
            }
        }
    }

    // MARK: 1 · summary

    private var summary: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("可回收").font(.caption).foregroundStyle(.secondary)
                    Text(ByteFormat.string(potentialSavings))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.keep)
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.6).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("相册共 \(model.libraryCount) 张")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(ByteFormat.string(model.libraryBytes))
                        .font(.callout.weight(.medium).monospacedDigit())
                }
            }
            Divider().overlay(Color.white.opacity(0.07))
            Button { route = .history } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.caption).foregroundStyle(Palette.accent)
                    Text("累计已释放 \(ByteFormat.string(model.lifetimeBytes))")
                        .font(.subheadline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var potentialSavings: Int64 {
        model.duplicateReclaimable
            + model.candidates.filter { !model.isMarked($0.id) }
                              .reduce(0) { $0 + $1.snapshot.byteSize }
    }

    // MARK: 2 · the one safe action

    private var sweepButton: some View {
        Button {
            // Leads to the evidence list rather than acting immediately: this is
            // the only place the app offers to delete without the user having
            // looked, so it has to show its work first.
            route = .duplicates
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                VStack(alignment: .leading, spacing: 1) {
                    Text("清理 \(model.identicalGroups.count) 组完全一致的重复")
                        .fontWeight(.semibold)
                    Text("同一张图存了多份，已替你勾好，过一眼即可")
                        .font(.caption2).opacity(0.85)
                }
                Spacer()
                Text(ByteFormat.string(model.identicalReclaimable))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    // MARK: 3 · everything else, as identical rows

    private var workList: some View {
        VStack(spacing: 0) {
            let rows = jobs
            // The emptiness that matters is "nothing to clean", not "no rows":
            // the App-sorting row is always present, so keying off rows.isEmpty
            // would leave a clean library staring at two-thirds of blank screen.
            if !rows.contains(where: { $0.isCleanup }) {
                emptyState
                if !rows.isEmpty {
                    Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 60)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, job in
                Button { route = job.route } label: { JobRow(job: job) }
                    .buttonStyle(.plain)
                if i < rows.count - 1 {
                    Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 60)
                }
            }
        }
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private struct Job: Identifiable {
        var id: String
        var icon: String
        var title: String
        var subtitle: String
        var value: String?
        var accent: Color
        var badge: String?
        var route: Route
        /// False for the always-present utility rows (App sorting, the teaching
        /// nudge) so they cannot disguise an otherwise-clean library as busy.
        var isCleanup: Bool = true
    }

    private var jobs: [Job] {
        var out: [Job] = []

        if !model.identicalGroups.isEmpty {
            out.append(Job(id: "identical", icon: "square.on.square", title: String(localized: "完全一致的重复"),
                           subtitle: String(localized: "\(model.identicalGroups.count) 组 · 同一张存了多份"),
                           value: ByteFormat.string(model.identicalReclaimable),
                           accent: Palette.keep, badge: String(localized: "已勾选"), route: .duplicates))
        }
        if !model.variantGroups.isEmpty {
            out.append(Job(id: "variants", icon: "square.stack.3d.up",
                           title: String(localized: "同一张的不同版本"),
                           subtitle: String(localized: "\(model.variantGroups.count) 组 · 分辨率/画质有差别，需要挑"),
                           value: ByteFormat.string(model.variantReclaimable),
                           accent: Palette.accent, badge: nil, route: .variants))
        }
        if !model.momentGroups.isEmpty {
            out.append(Job(id: "moments", icon: "square.stack.3d.down.right",
                           title: String(localized: "同一时刻多张"),
                           subtitle: String(localized: "\(model.momentGroups.count) 组 · 需要你挑一张"),
                           value: ByteFormat.string(model.momentReclaimable),
                           accent: Palette.accent, badge: nil, route: .moments))
        }
        for cat in model.activeCategories where cat != .duplicate {
            let c = model.counts(for: cat)
            out.append(Job(id: cat.rawValue, icon: cat.systemImage, title: cat.title,
                           subtitle: String(localized: "\(c.count) 项"),
                           value: ByteFormat.string(c.bytes),
                           accent: Palette.accent,
                           badge: cat == .chatScreenshot || cat == .gameScreenshot
                                  ? String(localized: "高收益") : nil,
                           route: .deck(cat)))
        }
        // Categories with no hand-written rule only exist once the head has been
        // taught. Saying so beats letting them silently never appear.
        let untaught = CleanupCategory.learnable.filter {
            OnlineClassifier.headOnly.contains($0) && model.counts(for: $0).count == 0
        }
        if !untaught.isEmpty, !model.appClusters.isEmpty {
            out.append(Job(id: "teach", icon: "sparkles", title: String(localized: "还没教过的类别"),
                           subtitle: untaught.map(\.title).joined(separator: "、")
                                     + String(localized: " —— 命名一簇截图就会出现"),
                           value: nil, accent: Palette.accent,
                           badge: nil, route: .appLabels, isCleanup: false))
        }
        out.append(Job(id: "apps", icon: "square.grid.3x3.square", title: String(localized: "按 App 归类"),
                       subtitle: model.appClusters.isEmpty
                           ? (model.appLabels.isEmpty ? String(localized: "命名一次，管几百张")
                                                      : String(localized: "已认识 \(model.appLabels.count) 个 App"))
                           : String(localized: "\(model.appClusters.count) 团待命名"),
                       value: nil, accent: Palette.accent,
                       badge: model.appClusters.isEmpty ? nil : "\(model.appClusters.count)",
                       route: .appLabels, isCleanup: false))
        return out
    }

    private struct JobRow: View {
        let job: Job
        var body: some View {
            HStack(spacing: 13) {
                Image(systemName: job.icon)
                    .font(.body)
                    .frame(width: 34, height: 34)
                    .background(job.accent.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .foregroundStyle(job.accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(job.title).font(.body.weight(.medium))
                        if let b = job.badge {
                            Text(b)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(job.accent.opacity(0.22), in: Capsule())
                                .foregroundStyle(job.accent)
                        }
                    }
                    Text(job.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if let v = job.value {
                    Text(v)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.stage.isRunning ? "hourglass" : "sparkles")
                .font(.title).foregroundStyle(.tertiary)
            Text(model.stage.isRunning
                 ? "正在识别，结果会边扫边出现"
                 : "没有找到可清理的东西。相册已经很干净了。")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(28)
    }

    // MARK: pending, pinned to the bottom

    private var pendingBar: some View {
        Button { route = .review } label: {
            HStack(spacing: 12) {
                Image(systemName: "trash.circle.fill")
                    .font(.title3).foregroundStyle(Palette.toss)
                VStack(alignment: .leading, spacing: 1) {
                    Text("待删清单 · \(model.pendingCount) 项")
                        .font(.subheadline.weight(.semibold))
                    Text("还没有真正删除")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(ByteFormat.string(model.pendingBytes))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.toss)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
        }
    }
}
