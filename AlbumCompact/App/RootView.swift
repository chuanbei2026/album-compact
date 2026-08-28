import SwiftUI

enum Route: Hashable {
    case duplicates
    case moments
    case variants
    case appLabels
    case review
    case history
    case settings
    case deck(CleanupCategory)
    case grid(CleanupCategory)
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            switch model.auth {
            case .undetermined: PermissionGate(state: .undetermined)
            case .denied:       PermissionGate(state: .denied)
            case .limited, .authorized:
                if sizeClass == .compact { CompactShell() } else { RegularShell() }
            }
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
    }
}

// MARK: - iPhone: a single stack, deck goes full screen

private struct CompactShell: View {
    @Environment(AppModel.self) private var model
    @State private var path: [Route] = []
    /// Fire the debug auto-route exactly once. Without this latch it re-triggers
    /// every time the scan appends candidates, which silently re-pushes the deck
    /// the instant the user taps back — indistinguishable from a broken back button.
    @State private var didAutoRoute = false

    /// Resolve a `-demoRoute` launch argument into a real route. Category routes
    /// wait until the scan has actually produced something to show.
    private func demoRoute() -> Route? {
        switch DebugLaunch.route {
        case "duplicates": return model.identicalGroups.isEmpty ? nil : .duplicates
        case "variants":   return model.variantGroups.isEmpty ? nil : .variants
        case "moments":    return model.momentGroups.isEmpty ? nil : .moments
        case "apps":       return .appLabels
        case "review":     return model.pendingCount == 0 ? nil : .review
        case "settings":   return .settings
        case "history":    return .history
        case "deck":
            guard let c = model.activeCategories.first(where: { $0 != .duplicate })
            else { return nil }
            return .deck(c)
        default: return nil
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(route: Binding(
                get: { path.last },
                set: { if let r = $0 { path.append(r) } }))
                .onChange(of: model.candidates.count, initial: true) { _, _ in
                    guard !didAutoRoute, path.isEmpty, let r = demoRoute() else { return }
                    didAutoRoute = true
                    path.append(r)
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .duplicates:    CopyReviewView()
                    case .moments:       MomentPickerView(mode: .moment)
                    case .variants:      MomentPickerView(mode: .variant)
                    case .appLabels:     AppLabelsView()
                    case .review:        ReviewTrayView()
                    case .history:       HistoryView()
                    case .settings:      SettingsView()
                    case .deck(let c):   DeckLauncher(category: c)
                    case .grid(let c):   DeckLauncher(category: c)
                    }
                }
        }
    }
}

// MARK: - iPad: sidebar + detail, grid-first

private struct RegularShell: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Route? = nil
    @State private var didAutoRoute = false

    @ViewBuilder private var overviewLinks: some View {
        let pendingSuffix = model.pendingCount > 0 ? " (\(model.pendingCount))" : ""
        NavigationLink(value: Route.review) {
            Label("待删清单" + pendingSuffix, systemImage: "trash")
        }
        NavigationLink(value: Route.duplicates) {
            Label("完全一致 (\(model.identicalGroups.count))", systemImage: "square.on.square")
        }
        NavigationLink(value: Route.variants) {
            Label("同一张的不同版本 (\(model.variantGroups.count))",
                  systemImage: "square.stack.3d.up")
        }
        NavigationLink(value: Route.moments) {
            Label("同一时刻多张 (\(model.momentGroups.count))", systemImage: "square.stack.3d.down.right")
        }
        NavigationLink(value: Route.appLabels) {
            Label("按 App 归类", systemImage: "square.grid.3x3.square")
        }
        NavigationLink(value: Route.history) {
            Label("清理记录", systemImage: "chart.line.uptrend.xyaxis")
        }
    }

    @ViewBuilder private var categoryLinks: some View {
        ForEach(model.activeCategories.filter { $0 != .duplicate }) { cat in
            let n = model.counts(for: cat).count
            NavigationLink(value: Route.grid(cat)) {
                Label("\(cat.title) (\(n))", systemImage: cat.systemImage)
            }
        }
    }

    @ViewBuilder private var settingsLink: some View {
        NavigationLink(value: Route.settings) {
            Label("设置", systemImage: "gearshape")
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("总览") { overviewLinks }
                Section("逐张过一遍") { categoryLinks }
                Section { settingsLink }
            }
            .navigationTitle("相册减负")
            .toolbar {
                ToolbarItem {
                    Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(model.stage.isRunning)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.stage.isRunning {
                    ScanBanner(stage: model.stage) { model.cancelScan() }
                        .padding(12)
                }
            }
        } detail: {
            NavigationStack {
                switch selection {
                case .duplicates:   CopyReviewView()
                case .moments:      MomentPickerView(mode: .moment)
                case .variants:     MomentPickerView(mode: .variant)
                case .appLabels:    AppLabelsView()
                case .review:       ReviewTrayView()
                case .history:      HistoryView()
                case .settings:     SettingsView()
                case .deck(let c):  DeckLauncher(category: c)
                case .grid(let c):
                    TriageGridView(route: Binding(
                        get: { selection },
                        set: { selection = $0 }), category: c)
                case nil:
                    IPadOverview()
                }
            }
        }
        .onChange(of: model.candidates.count, initial: true) { _, _ in
            guard !didAutoRoute, selection == nil, let r = demoSelection() else { return }
            didAutoRoute = true
            selection = r
        }
    }

    /// See `DebugLaunch` — lets a screen be opened straight from the CLI.
    private func demoSelection() -> Route? {
        switch DebugLaunch.route {
        case "duplicates": return model.identicalGroups.isEmpty ? nil : .duplicates
        case "variants":   return model.variantGroups.isEmpty ? nil : .variants
        case "moments":    return model.momentGroups.isEmpty ? nil : .moments
        case "apps":       return .appLabels
        case "review":     return model.pendingCount == 0 ? nil : .review
        case "settings":   return .settings
        case "history":    return .history
        case "grid", "deck":
            guard let c = model.activeCategories.first(where: { $0 != .duplicate })
            else { return nil }
            return DebugLaunch.route == "deck" ? .deck(c) : .grid(c)
        default: return nil
        }
    }
}

private struct IPadOverview: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack(spacing: 12) {
                    StatTile(value: "\(model.libraryCount)", label: "相册总数", icon: "photo.stack")
                    StatTile(value: ByteFormat.string(model.libraryBytes),
                             label: "估算占用", icon: "internaldrive")
                    StatTile(value: ByteFormat.string(model.duplicateReclaimable),
                             label: "重复可回收", tint: Palette.keep, icon: "square.on.square")
                    StatTile(value: ByteFormat.string(model.pendingBytes),
                             label: "已标记", tint: Palette.toss, icon: "trash")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("从左边选一个门类开始。")
                        .font(.headline)
                    Text("""
                    iPad 上默认是网格模式 —— 一眼看十几张，点一下就标记，比逐张滑动快得多。\
                    需要专注逐张判断时，右上角切到「滑动模式」，方向键 ↑ 保留 / ← 删除 / → 撤销，\
                    空格看原图。
                    """)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(Palette.raised,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(20)
        }
        .background(Palette.surface)
        .navigationTitle("总览")
    }
}

// MARK: - Deck launcher

/// Owns the "start a session on this category" side effect so `SwipeDeckView`
/// stays a pure view of `AppModel`'s deck state.
private struct DeckLauncher: View {
    @Environment(AppModel.self) private var model
    let category: CleanupCategory

    private func runDemoSwipesIfRequested() {
        let n = DebugLaunch.swipes
        guard n > 0 else { return }
        // Cycle through all three outcomes so a smoke run exercises every branch
        // of the decision handler, not just the destructive one.
        let cycle: [Decision] = [.delete, .delete, .keepOnce, .delete, .whitelist]
        for k in 0..<n {
            let d: Decision = cycle[k % cycle.count]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 + Double(k) * 0.5) {
                model.decide(d)
            }
        }
    }

    var body: some View {
        SwipeDeckView(category: category)
            .onAppear {
                if model.deckCategory != category || model.deck.isEmpty {
                    model.startDeck(category: category)
                }
                runDemoSwipesIfRequested()
            }
            .onDisappear {
                Store.shared.flushClassifier()
                model.scheduleReminder()
            }
    }
}

// MARK: - Permission gate

private struct PermissionGate: View {
    @Environment(AppModel.self) private var model
    let state: LibraryAuthState

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.badge.checkmark")
                .font(.system(size: 58))
                .foregroundStyle(Palette.accent)

            Text("相册减负").font(.largeTitle.weight(.bold))

            Text("""
            找出重复照片、聊天截图、游戏截图这些占地方又没用的东西，\
            用最少的动作清掉它们。

            全部计算都在这台设备上完成 —— pHash 指纹和 Apple Vision 的\
            神经引擎推理，没有任何数据离开你的手机。
            """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            if state == .denied {
                VStack(spacing: 12) {
                    Text("相册权限被拒绝了。")
                        .font(.subheadline).foregroundStyle(Palette.toss)
                    Button("打开系统设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Button {
                    Task { await model.requestAccess() }
                } label: {
                    Text("允许访问相册").frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface)
    }
}
