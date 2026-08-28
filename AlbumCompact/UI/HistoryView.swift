import SwiftUI
import Charts

// MARK: - Categorical colour

extension CleanupCategory {
    /// A fixed colour slot per category — assigned by identity, never by rank, so
    /// a category keeps its colour no matter how the bars happen to sort. Drawn
    /// from a palette validated for this dark chart surface (#242424): all eight
    /// slots clear the lightness band, the chroma floor, 3:1 contrast, and a
    /// worst-adjacent colour-vision-deficiency separation of ΔE 8.4.
    var chartColor: Color {
        switch self {
        case .duplicate:       return Color(red: 0.224, green: 0.529, blue: 0.898) // #3987e5
        case .chatScreenshot:  return Color(red: 0.851, green: 0.349, blue: 0.149) // #d95926
        case .gameScreenshot:  return Color(red: 0.098, green: 0.620, blue: 0.439) // #199e70
        case .screenshot:      return Color(red: 0.788, green: 0.522, blue: 0.000) // #c98500
        case .webShot:         return Color(red: 0.835, green: 0.318, blue: 0.506) // #d55181
        // Map screenshots take the next fixed slot in the validated ramp; colours
        // are assigned by identity, never by rank, so nothing above shifts.
        case .mapScreenshot:   return Color(red: 0.000, green: 0.514, blue: 0.000) // #008300
        case .documentShot:    return Color(red: 0.565, green: 0.522, blue: 0.914) // #9085e9
        case .blurry:          return Color(red: 0.788, green: 0.522, blue: 0.000).opacity(0.7)
        case .systemScreenshot: return Color(red: 0.902, green: 0.404, blue: 0.404) // #e66767
        case .other:           return Color.white.opacity(0.30)
        case .screenRecording,
             .largeVideo:      return Color(red: 0.224, green: 0.529, blue: 0.898).opacity(0.55)
        }
    }
}

// MARK: - History dashboard

/// What the user actually wants to know, in order:
///   1. how much have I freed in total            → a hero number, not a chart
///   2. is the library actually getting smaller   → one time series
///   3. where did the space come from             → sorted bars
///   4. when did I do it                          → a log
///
/// Freed-bytes and library-size are both byte counts but an order of magnitude
/// apart, so they are deliberately *not* plotted together — a second y-axis would
/// flatten one of them into a straight line. The library-size series carries the
/// chart; the freed amount is the hero number, and each cleanup is marked on the
/// line where it happened.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var scrubDate: Date?
    @State private var range: DayRange = .ninety

    enum DayRange: String, CaseIterable, Identifiable {
        case thirty, ninety, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .thirty: return String(localized: "30 天")
            case .ninety: return String(localized: "90 天")
            case .all:    return String(localized: "全部")
            }
        }
        var days: Int? {
            switch self {
            case .thirty: return 30
            case .ninety: return 90
            case .all:    return nil
            }
        }
    }
    @State private var selectedCategory: String?
    @State private var confirmClear = false

    private var snapshots: [LibrarySnapshot] { model.librarySnapshots }
    private var events: [DeletionEvent] { model.history }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if events.isEmpty && snapshots.count < 2 {
                    emptyState
                } else {
                    hero
                    if snapshots.count >= 2 { librarySizeChart }
                    if !events.isEmpty { dailyChart }
                    if !model.freedByCategory.isEmpty { categoryChart }
                    if !events.isEmpty { log }
                }
            }
            .padding(16)
        }
        .background(Palette.surface)
        .navigationTitle("清理记录")
        .toolbar {
            if !events.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空记录", role: .destructive) { confirmClear = true }
                        .tint(Palette.toss)
                }
            }
        }
        .alert("清空清理记录？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { Store.shared.clearHistory() }
        } message: {
            Text("只会清掉这里的统计和趋势,已经删除的照片不会回来,相册也不受影响。")
        }
    }

    // MARK: hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("累计已释放")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(ByteFormat.string(model.lifetimeBytes))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.keep)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            HStack(spacing: 12) {
                miniStat("\(model.lifetimeCount)", "删除张数")
                miniStat("\(events.count)", "清理次数")
                miniStat(events.isEmpty ? "—"
                         : ByteFormat.string(model.lifetimeBytes / Int64(max(events.count, 1))),
                         "平均每次")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// `l` is a LocalizedStringKey for the same reason StatTile's is: as a
    /// String these three labels reached Text(variable) and stayed Chinese.
    private func miniStat(_ v: String, _ l: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: chart 1 — library size over time

    private var librarySizeChart: some View {
        let scrubbed = scrubDate.flatMap { d in
            snapshots.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("相册总占用").font(.headline)
                    if let c = model.librarySizeChange {
                        let delta = c.to - c.from
                        Text(delta <= 0
                             ? "比最早一次记录少了 \(ByteFormat.string(-delta))"
                             : "比最早一次记录多了 \(ByteFormat.string(delta)) — 新照片进得比清得快")
                            .font(.caption)
                            .foregroundStyle(delta <= 0 ? Palette.keep : .secondary)
                    }
                }
                Spacer()
                if let s = scrubbed {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(ByteFormat.string(s.bytes))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                        Text(s.date.formatted(.dateTime.month().day()))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            Chart {
                ForEach(snapshots) { s in
                    LineMark(x: .value("日期", s.date), y: .value("占用", s.bytes))
                        .foregroundStyle(Palette.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
                // Each cleanup marked where it happened — cause beside effect, on
                // one axis and one unit. A surface-coloured ring keeps overlapping
                // markers readable against the line.
                ForEach(events) { e in
                    PointMark(x: .value("日期", e.date),
                              y: .value("占用", bytesNear(e.date)))
                        .symbolSize(56)
                        .foregroundStyle(Palette.toss)
                }
                if let s = scrubbed {
                    RuleMark(x: .value("日期", s.date))
                        .foregroundStyle(Color.white.opacity(0.26))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    PointMark(x: .value("日期", s.date), y: .value("占用", s.bytes))
                        .symbolSize(130)
                        .foregroundStyle(Palette.accent)
                }
            }
            // The question this chart answers is "is it going down", not "how big
            // is it" — so a line on a padded domain, never an area fill on a
            // truncated one. An area implies magnitude measured from zero.
            .chartYScale(domain: yDomain)
            .chartXSelection(value: $scrubDate)
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                    AxisValueLabel {
                        if let b = v.as(Double.self) { Text(ByteFormat.string(Int64(b))) }
                    }
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.05))
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
            }
            .frame(height: 190)

            HStack(spacing: 14) {
                legendDot(Palette.accent, "相册总占用")
                legendDot(Palette.toss, "执行了一次清理")
            }
        }
        .padding(16)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Pad the range so the trend fills the plot without the line touching an edge.
    private var yDomain: ClosedRange<Double> {
        let vals = snapshots.map { Double($0.bytes) }
        guard let lo = vals.min(), let hi = vals.max(), hi > lo else {
            return 0...(max(vals.first ?? 1, 1) * 1.2)
        }
        let pad = (hi - lo) * 0.35
        return max(0, lo - pad)...(hi + pad * 0.5)
    }

    /// The library reading closest to an event, so its marker sits on the line.
    private func bytesNear(_ d: Date) -> Int64 {
        snapshots.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }?
            .bytes ?? 0
    }

    private func legendDot(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: chart 2 — how much was freed on each day

    /// Freed bytes aggregated per calendar day. Sparse by nature — most days have
    /// no cleanup — and the gaps are the point: they show cadence, which a
    /// cumulative total hides completely.
    private struct DayTotal: Identifiable {
        var id: Date { day }
        var day: Date
        var bytes: Int64
        var count: Int
    }

    private func dailyTotals(_ limitDays: Int?) -> [DayTotal] {
        let cal = Calendar.current
        var buckets: [Date: (Int64, Int)] = [:]
        let cutoff = limitDays.map {
            cal.startOfDay(for: Date()).addingTimeInterval(-Double($0) * 86_400)
        }
        for e in events {
            let day = cal.startOfDay(for: e.date)
            if let cutoff, day < cutoff { continue }
            var cur = buckets[day] ?? (0, 0)
            cur.0 += e.bytes
            cur.1 += e.count
            buckets[day] = cur
        }
        return buckets.map { DayTotal(day: $0.key, bytes: $0.value.0, count: $0.value.1) }
            .sorted { $0.day < $1.day }
    }

    private var dailyChart: some View {
        let rows = dailyTotals(range.days)
        let busiest = rows.max { $0.bytes < $1.bytes }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("每天释放了多少").font(.headline)
                    Text(rows.isEmpty
                         ? "这段时间没有执行过清理"
                         : "\(rows.count) 天有清理动作"
                           + (busiest.map { " · 最多的一天 \(ByteFormat.string($0.bytes))" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Filters in one row above the chart.
            Picker("范围", selection: $range) {
                ForEach(DayRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if rows.isEmpty {
                Text("换一个时间范围试试")
                    .font(.footnote).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 34)
            } else {
                Chart(rows) { r in
                    BarMark(
                        x: .value("日期", r.day, unit: .day),
                        y: .value("释放", r.bytes),
                        width: .fixed(barWidth(rows.count))
                    )
                    .foregroundStyle(Palette.keep)
                    .cornerRadius(3)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { v in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                        AxisValueLabel {
                            if let b = v.as(Double.self) { Text(ByteFormat.string(Int64(b))) }
                        }
                        .font(.caption2).foregroundStyle(Color.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.05))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .font(.caption2).foregroundStyle(Color.secondary)
                    }
                }
                .frame(height: 150)
            }
        }
        .padding(16)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Keep bars thin, and thinner still as the range widens, so a 90-day view
    /// does not turn a handful of cleanups into fat isolated blocks.
    private func barWidth(_ n: Int) -> CGFloat {
        n <= 8 ? 18 : (n <= 20 ? 11 : 6)
    }

    // MARK: chart 3 — where the space came from

    private var categoryChart: some View {
        let rows = model.freedByCategory
        let total = max(rows.reduce(Int64(0)) { $0 + $1.bytes }, 1)
        let maxBytes = Double(rows.first?.bytes ?? 1)

        return VStack(alignment: .leading, spacing: 14) {
            Text("空间是从哪来的").font(.headline)

            // Built from layout primitives rather than a charting library: for a
            // handful of sorted rows the geometry is trivial, every label is
            // placed deliberately instead of negotiated with an axis, and the
            // chart and its table become one thing instead of two views of the
            // same numbers.
            VStack(spacing: 13) {
                ForEach(rows, id: \.category) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Image(systemName: row.category.systemImage)
                                .font(.caption2)
                                .foregroundStyle(row.category.chartColor)
                                .frame(width: 14)
                            Text(row.category.title)
                                .font(.subheadline)
                            Spacer(minLength: 8)
                            Text(ByteFormat.string(row.bytes))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                        }
                        HStack(spacing: 10) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.white.opacity(0.07))
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(row.category.chartColor)
                                        .frame(width: max(6, geo.size.width
                                                          * CGFloat(Double(row.bytes) / maxBytes)))
                                }
                            }
                            .frame(height: 10)

                            Text("\(row.count) 张")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 58, alignment: .trailing)
                            Text("\(Int(Double(row.bytes) / Double(total) * 100))%")
                                .font(.caption.weight(.medium).monospacedDigit())
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: log

    private var log: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("每次清理").font(.headline)
            VStack(spacing: 0) {
                ForEach(events.reversed()) { e in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.date.formatted(.dateTime.year().month().day()))
                                .font(.subheadline.weight(.medium))
                            HStack(spacing: 6) {
                                Text("\(e.count) 张")
                                if let t = e.topCategory {
                                    Text("·")
                                    HStack(spacing: 3) {
                                        Circle().fill(t.chartColor).frame(width: 6, height: 6)
                                        Text("主要是\(t.title)")
                                    }
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteFormat.string(e.bytes))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Palette.keep)
                    }
                    .padding(.vertical, 9)
                    if e.id != events.first?.id {
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                }
            }
        }
        .padding(16)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: empty

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("还没有清理记录").font(.headline)
            Text("""
            执行第一次删除之后,这里会显示相册占用的变化趋势、\
            空间主要来自哪些类目,以及每一次清理的明细。
            相册占用每天最多记录一次。
            """)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 20)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
