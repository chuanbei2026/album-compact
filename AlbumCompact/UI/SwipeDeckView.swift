import SwiftUI

/// The triage deck.
///
/// Gesture language:
///   ↑ up      delete — mark it (nothing is removed from the library yet)
///   ← left    keep this time; it may come back in a future scan
///   → right   whitelist — never propose this photo again
///   ↓ down    step back and undo the last decision
///   tap       full-screen inspect
///
/// Design notes:
/// * Up is delete because it is the high-frequency action: the queue is built to
///   be mostly junk, so the cheapest, most repeatable motion should be the one
///   the user performs most. It also matches the vertical-feed muscle memory the
///   whole interaction borrows from.
/// * The vertical axis is the only destructive one. Both horizontal directions
///   keep the photo and differ only in permanence, so a left/right mix-up can
///   never cost a photo — the worst case is being asked again, or not being.
/// * Nothing here touches the library. Up-swipe only writes a row to the pending
///   tray, which is why the gesture can be fast and thoughtless — the safety net
///   is the review screen, not hesitation on each card.
/// * Every card states *why* it was surfaced. A triage UI that shows a photo with
///   no rationale forces the user to re-derive the decision themselves, which is
///   the slow part.
struct SwipeDeckView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let category: CleanupCategory

    @State private var drag: CGSize = .zero
    @State private var committing = false
    @State private var showDetail = false
    @State private var showRelabel = false
    @State private var scheduledAutoBack = false

    /// Roughly a thumb-flick, not a full drag. 110pt asked the user to haul each
    /// card most of the way across the screen; at 62pt with a low velocity gate a
    /// quick flick is enough, which is the whole point of a triage deck.
    private let commitDistance: CGFloat = 62
    private let commitVelocity: CGFloat = 170

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.deckFinished {
                SessionSummary(category: category) { dismiss() }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                // A vertical stack, not an overlay: the card gets exactly the
                // space between the chrome, so a bright photo can never end up
                // sitting underneath the buttons.
                VStack(spacing: 12) {
                    // The chrome sits above the deck in z-order as well as in
                    // layout. Without that, a tap near the top edge could reach
                    // the card's inspect gesture instead of the back button —
                    // which looked exactly like "the exit button shows the photo".
                    header.zIndex(2)
                    deck
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .zIndex(0)
                    footer.zIndex(2)
                }
                .padding(.horizontal, 16)
            }
        }
        .onAppear {
            let delay = DebugLaunch.autoBack
            guard delay > 0, !scheduledAutoBack else { return }
            scheduledAutoBack = true
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { dismiss() }
        }
        .preferredColorScheme(.dark)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $showDetail) {
            if let c = model.currentCard { AssetDetailView(snapshot: c.snapshot) }
        }
        .confirmationDialog("这张其实是…", isPresented: $showRelabel, titleVisibility: .visible) {
            ForEach(CleanupCategory.learnable) { cat in
                Button(cat.title) { model.relabelCurrent(to: cat) }
            }
        } message: {
            Text("纠正会立刻训练本机模型，之后同类照片的判断会更准。")
        }
        // iPad / Magic Keyboard: keyboard triage is far faster than swiping.
        .onKeyPress(.upArrow)    { commit(.delete);    return .handled }
        .onKeyPress(.leftArrow)  { commit(.keepOnce);  return .handled }
        .onKeyPress(.rightArrow) { commit(.whitelist); return .handled }
        .onKeyPress(.downArrow)  { model.undo();       return .handled }
        .onKeyPress(.space)      { showDetail.toggle(); return .handled }
        .onKeyPress(.escape)     { dismiss(); return .handled }
    }

    // MARK: card stack

    private var deck: some View {
        ZStack {
            // Two cards behind the top one give the stack depth and, more
            // importantly, let PhotoKit decode the next image before it's needed.
            ForEach(Array(upcoming.enumerated().reversed()), id: \.element.id) { offset, card in
                let isTop = offset == 0
                CardView(candidate: card,
                         drag: isTop ? drag : .zero,
                         isTop: isTop)
                    .padding(.horizontal, CGFloat(offset) * 8)
                    .scaleEffect(isTop ? 1 : 1 - CGFloat(offset) * 0.03)
                    .offset(y: isTop ? 0 : CGFloat(offset) * 12)
                    // Never opacity-0: a fully transparent card can be skipped by
                    // the render pass, so its image would not actually be decoded
                    // and ready when it becomes the top card.
                    .opacity(offset > 1 ? 0.01 : 1)
                    .allowsHitTesting(isTop)
                    .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .onTapGesture { if isTop { showDetail = true } }
                    .zIndex(Double(10 - offset))
            }
        }
        .offset(drag)
        .rotationEffect(.degrees(Double(drag.width / 26)), anchor: .bottom)
        .gesture(dragGesture)
        .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.82), value: drag)
    }

    private var upcoming: [Candidate] {
        Array(model.deck[safe: model.deckIndex..<(model.deckIndex + 3)])
    }

    // MARK: gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                guard !committing else { return }
                // Track the dominant axis 1:1 and damp the other only lightly.
                // Heavier damping made the card feel like it was resisting the
                // finger, which reads as "this needs more force".
                if abs(v.translation.width) > abs(v.translation.height) {
                    drag = CGSize(width: v.translation.width, height: v.translation.height * 0.55)
                } else {
                    drag = CGSize(width: v.translation.width * 0.55, height: v.translation.height)
                }
            }
            .onEnded { v in
                guard !committing else { return }
                let t = v.translation
                let p = v.predictedEndTranslation
                let horizontal = abs(t.width) > abs(t.height)

                func past(_ a: CGFloat, _ b: CGFloat) -> Bool {
                    a < -commitDistance || b < -commitVelocity
                }
                func pastPositive(_ a: CGFloat, _ b: CGFloat) -> Bool {
                    a > commitDistance || b > commitVelocity
                }

                if !horizontal && past(t.height, p.height) {
                    commit(.delete)                       // ↑
                } else if horizontal && pastPositive(t.width, p.width) {
                    commit(.whitelist)                    // →
                } else if horizontal && past(t.width, p.width) {
                    commit(.keepOnce)                     // ←
                } else if !horizontal && pastPositive(t.height, p.height) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { drag = .zero }
                    model.undo()                          // ↓
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { drag = .zero }
                }
            }
    }

    /// Fly the card off-screen, then advance. Splitting it this way keeps the
    /// index change invisible — the new top card is already rendered underneath.
    private func commit(_ decision: Decision) {
        guard model.currentCard != nil, !committing else { return }
        committing = true
        let target: CGSize
        switch decision {
        case .delete:    target = CGSize(width: 0, height: -900)
        case .whitelist: target = CGSize(width: 780, height: 40)
        case .keepOnce:  target = CGSize(width: -780, height: 40)
        }
        // Two frames matter here. The card must leave fast enough that the next
        // one is on screen almost immediately, and the index must advance *after*
        // the outgoing card is gone but without waiting for a slow animation —
        // 0.2 s of flight was long enough to read as a gap.
        withAnimation(.easeOut(duration: 0.13)) { drag = target }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            model.decide(decision)
            // No animation on the reset: animating `drag` back to zero would slide
            // the incoming card in from off-screen, which is the "long black
            // screen" — it is already in place, it just needs to be shown.
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { drag = .zero }
            committing = false
        }
    }

    // MARK: chrome

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")

                Spacer()

                VStack(spacing: 1) {
                    Text(category.title).font(.subheadline.weight(.semibold))
                    Text("\(min(model.deckIndex + 1, model.deck.count)) / \(model.deck.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text(ByteFormat.string(model.sessionMarkedBytes))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Palette.toss)
                        .contentTransition(.numericText())
                    Text("本轮已标记").font(.caption2).foregroundStyle(.secondary)
                }
            }

            ProgressView(value: Double(model.deckIndex),
                         total: Double(max(model.deck.count, 1)))
                .tint(Palette.accent)
                .scaleEffect(y: 0.6)
        }
        .padding(.top, 6)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            if let c = model.currentCard {
                ReasonStrip(candidate: c)
            }
            HStack(spacing: 10) {
                ActionButton(icon: "arrow.uturn.backward", tint: .orange,
                             label: "撤销", disabled: model.deckIndex == 0) { model.undo() }
                ActionButton(icon: "checkmark", tint: Palette.undo,
                             label: "这次留") { commit(.keepOnce) }
                ActionButton(icon: "trash.fill", tint: Palette.toss,
                             label: "删除", big: true) { commit(.delete) }
                ActionButton(icon: "lock.shield.fill", tint: Palette.keep,
                             label: "永久留") { commit(.whitelist) }
                ActionButton(icon: "tag", tint: .purple,
                             label: "改类别") { showRelabel = true }
            }
            Text("上滑删除 · 左滑这次保留 · 右滑永久保留 · 下滑撤销")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Card

private struct CardView: View {
    let candidate: Candidate
    let drag: CGSize
    let isTop: Bool

    var body: some View {
        ZStack {
            AssetImageView(id: candidate.snapshot.id, side: 460, contentMode: .fill)
                .background(Palette.raised)

            // Verdict overlay: appears proportionally to the drag so the user
            // always knows what will happen before they let go.
            if isTop {
                overlay
            }

            VStack {
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.75)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 110)
                    .overlay(alignment: .bottomLeading) {
                        MetadataStrip(snapshot: candidate.snapshot)
                            .padding(12)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }

    private var overlay: some View {
        // Each direction's badge grows with the drag, so the outcome is committed
        // to on screen before the finger lifts.
        let up    = min(1, max(0, -drag.height / 62))
        let down  = min(1, max(0,  drag.height / 62))
        let right = min(1, max(0,  drag.width  / 62))
        let left  = min(1, max(0, -drag.width  / 62))

        return ZStack {
            if up > 0.02 {
                verdict("删除", "trash.fill", Palette.toss, up)
            } else if right > 0.02 {
                verdict("永久保留", "lock.shield.fill", Palette.keep, right)
            } else if left > 0.02 {
                verdict("这次保留", "checkmark", Palette.undo, left)
            } else if down > 0.02 {
                verdict("撤销", "arrow.uturn.backward", .orange, down)
            }
        }
    }

    private func verdict(_ text: String, _ icon: String,
                         _ color: Color, _ amount: CGFloat) -> some View {
        ZStack {
            color.opacity(0.30 * amount)
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 54, weight: .bold))
                Text(text).font(.title2.weight(.heavy))
            }
            .foregroundStyle(.white)
            .padding(26)
            .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 22))
            .scaleEffect(0.7 + amount * 0.3)
            .opacity(Double(amount))
        }
    }
}

// MARK: - Reason strip

private struct ReasonStrip: View {
    @Environment(AppModel.self) private var model
    let candidate: Candidate

    private var appName: String? { model.appName(for: candidate.id) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if let app = appName {
                    Chip(text: app, icon: "app.badge.checkmark", tint: Palette.keep)
                }
                Chip(text: candidate.category.title,
                     icon: candidate.category.systemImage,
                     tint: Palette.accent)
                Chip(text: "把握 \(Int(candidate.confidence * 100))%",
                     icon: "gauge.medium")
            }
            if let first = candidate.reasons.first {
                Text(candidate.reasons.prefix(2).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .id(first)
            }
        }
    }
}

// MARK: - Buttons

private struct ActionButton: View {
    let icon: String
    let tint: Color
    let label: String
    var big = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: big ? 24 : 18, weight: .semibold))
                    .frame(width: big ? 62 : 48, height: big ? 62 : 48)
                    .background(tint.opacity(disabled ? 0.10 : 0.22), in: Circle())
                    .overlay { Circle().strokeBorder(tint.opacity(disabled ? 0.15 : 0.5), lineWidth: 1) }
                    .foregroundStyle(disabled ? tint.opacity(0.35) : tint)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - Session summary

private struct SessionSummary: View {
    @Environment(AppModel.self) private var model
    let category: CleanupCategory
    let done: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 60))
                .foregroundStyle(Palette.keep)

            Text("这一轮结束了")
                .font(.title2.weight(.semibold))

            HStack(spacing: 10) {
                StatTile(value: "\(model.deckMarkedCount)", label: "标记删除",
                         tint: Palette.toss, icon: "trash")
                StatTile(value: ByteFormat.string(model.sessionMarkedBytes),
                         label: "可释放", tint: Palette.accent, icon: "internaldrive")
                StatTile(value: "\(model.sessionKeptCount)", label: "这次保留",
                         tint: Palette.undo, icon: "checkmark")
                StatTile(value: "\(model.sessionWhitelistCount)", label: "加白名单",
                         tint: Palette.keep, icon: "lock.shield")
            }

            Text("标记的照片还没有被删除。回到首页打开「待删清单」核对后再执行。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(spacing: 10) {
                if model.counts(for: category).count > 0 {
                    Button {
                        model.startDeck(category: category)
                    } label: {
                        Label("再来一轮（还剩 \(model.counts(for: category).count) 项）",
                              systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Button("回首页", action: done)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
        }
        .padding(28)
    }
}
