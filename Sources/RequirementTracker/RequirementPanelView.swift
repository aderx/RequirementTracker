import AppKit
import RequirementCore
import SwiftUI

enum RequirementPanelMetrics {
    static let width: CGFloat = 310
    static let height: CGFloat = 560

    static func height(isCalendarVisible: Bool) -> CGFloat {
        height
    }
}

struct RequirementPanelView: View {
    @EnvironmentObject private var store: RequirementStore
    @EnvironmentObject private var settingsStore: RequirementSettingsStore
    @EnvironmentObject private var scriptLauncher: GhosttyScriptLauncher
    var onOpenOverview: (() -> Void)?
    var onShowAbout: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onCalendarVisibilityChange: ((Bool) -> Void)?

    @State private var statusFilter: RequirementStatusFilter = .incomplete
    @State private var isAdding = false
    @State private var bulkInput = ""
    @State private var expandedIDs: [RequirementStatusFilter: Requirement.ID] = [:]
    @State private var showsCalendar = false
    @State private var displayMonth = Date()
    @State private var isDateFilterHovering = false
    @State private var isAddButtonHovering = false
    @State private var searchText = ""
    @State private var isSearchExpanded = false
    @State private var bottomOverlayHeight: CGFloat = 0
    @State private var modernTopOverlayHeight: CGFloat = 0
    @State private var isModernTopActionsExpanded = false
    @FocusState private var isSearchFocused: Bool
    @Namespace private var modernGlassNamespace

    private var visibleRequirements: [Requirement] {
        var filtered = RequirementQuery.filteredAndSorted(
            store.requirements,
            statusFilter: statusFilter,
            dateFilter: dateFilter,
            sortRules: settingsStore.tabSortRules(for: statusFilter)
        )

        if let selectedDay {
            filtered = filtered.filter {
                Calendar.current.isDate($0.activityDate, inSameDayAs: selectedDay)
            }
        }

        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            return filtered
        }

        return filtered.filter {
            $0.jiraKey.localizedCaseInsensitiveContains(keyword)
        }
    }

    private var panelHeight: CGFloat {
        RequirementPanelMetrics.height(isCalendarVisible: showsCalendar)
    }

    private var panelStyle: RequirementPanelStyle {
        settingsStore.panelStyle
    }

    var body: some View {
        let items = visibleRequirements

        return ZStack {
            Color.clear
                .ignoresSafeArea()

            if panelStyle == .modern {
                modernPanelContent(items)
            } else {
                legacyPanelContent(items)
            }
        }
        .frame(width: RequirementPanelMetrics.width, height: panelHeight)
        .onAppear {
            onCalendarVisibilityChange?(showsCalendar)
        }
        .onChange(of: showsCalendar) { isVisible in
            onCalendarVisibilityChange?(isVisible)
        }
        .onPreferenceChange(BottomOverlayHeightPreferenceKey.self) { height in
            guard abs(bottomOverlayHeight - height) > 0.5 else {
                return
            }
            bottomOverlayHeight = height
        }
        .onPreferenceChange(ModernTopOverlayHeightPreferenceKey.self) { height in
            guard abs(modernTopOverlayHeight - height) > 0.5 else {
                return
            }
            modernTopOverlayHeight = height
        }
        .onChange(of: panelStyle) { style in
            withAnimation(.snappy(duration: 0.18)) {
                showsCalendar = false
                isSearchExpanded = !searchText.isEmpty
                isModernTopActionsExpanded = false

                if style != .standard {
                    isAdding = false
                    bulkInput = ""
                }
            }
        }
        // 弹窗关闭后自动清空搜索，下次打开回到完整列表。
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.willCloseNotification)) { _ in
            searchText = ""
            isSearchExpanded = false
            isSearchFocused = false
            isModernTopActionsExpanded = false
            showsCalendar = false
        }
    }

    private func legacyPanelContent(_ items: [Requirement]) -> some View {
        VStack(spacing: 0) {
            if panelStyle == .standard {
                header(items)
            }

            if panelStyle == .standard, isAdding {
                addPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            legacyPanelFilterArea

            ZStack(alignment: .bottom) {
                contentList(
                    items,
                    bottomInset: max(bottomOverlayHeight + 12, 12),
                    topInset: panelStyle == .minimal ? 10 : 4,
                    coveredBottomHeight: panelStyle == .standard ? bottomOverlayHeight : 0
                )

                measuredBottomOverlay
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func modernPanelContent(_ items: [Requirement]) -> some View {
        ZStack(alignment: .bottom) {
            contentList(
                items,
                bottomInset: max(bottomOverlayHeight + 12, 12),
                topInset: max(modernTopOverlayHeight + 10, 10)
            )

            measuredBottomOverlay
        }
        .overlay(alignment: .top) {
            modernTopOverlay(items)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ModernTopOverlayHeightPreferenceKey.self,
                            value: geometry.size.height
                        )
                    }
                }
        }
    }

    private var measuredBottomOverlay: some View {
        bottomOverlay
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: BottomOverlayHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            }
    }

    private func header(_ items: [Requirement]) -> some View {
        HStack(spacing: 5) {
            Text("需求记录")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)

            Text("\(items.count) 项")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.black.opacity(0.38))
                .padding(.leading, 2)

            Spacer()

            if isAdding {
                HStack(spacing: 0) {
                    Button("取消") {
                        cancelAdding()
                    }
                    .buttonStyle(HeaderSegmentButtonStyle())
                    .pointingHandCursor()

                    Button("添加") {
                        commitAdding()
                    }
                    .buttonStyle(HeaderSegmentButtonStyle(isProminent: true))
                    .disabled(bulkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .pointingHandCursor()
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.13), lineWidth: 0.5)
                )
            } else {
                if !scriptMenuContents.isEmpty {
                    NativeIconMenuButton(
                        kind: .symbol("terminal"),
                        contents: scriptMenuContents,
                        size: CGSize(width: 22, height: 22),
                        tintAlpha: 0.78,
                        help: "启动脚本"
                    )
                    .frame(width: 22, height: 22)
                }

                if !quickLinkMenuContents.isEmpty {
                    NativeIconMenuButton(
                        kind: .symbol("link"),
                        contents: quickLinkMenuContents,
                        size: CGSize(width: 22, height: 22),
                        tintAlpha: 0.78,
                        help: "快速打开链接"
                    )
                    .frame(width: 22, height: 22)
                }

                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        isAdding = true
                        showsCalendar = false
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11.5, weight: .semibold))
                        .frame(width: 22)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HeaderAddButtonStyle(isHovered: isAddButtonHovering))
                .help("添加需求")
                .onHover { isAddButtonHovering = $0 }
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var filterBar: some View {
        StatusSegmentBar(selection: $statusFilter)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var legacyPanelFilterArea: some View {
        if panelStyle == .standard {
            filterBar
            GlassDivider()
        }
    }

    @ViewBuilder
    private func modernTopOverlay(_ items: [Requirement]) -> some View {
        if #available(macOS 26.0, *) {
            nativeModernTopOverlay(items)
        } else {
            fallbackModernTopOverlay(items)
        }
    }

    @available(macOS 26.0, *)
    private func nativeModernTopOverlay(_ items: [Requirement]) -> some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 6) {
                modernTitleCluster(items)
                    .glassEffect(.regular, in: Capsule())
                    .glassEffectID("modern-title", in: modernGlassNamespace)

                Spacer(minLength: 6)

                modernTopContentCluster
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .glassEffectID("modern-top-content", in: modernGlassNamespace)

                modernTopToggleButton
                    .glassEffect(.regular.interactive(), in: Circle())
                    .glassEffectID("modern-top-toggle", in: modernGlassNamespace)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
    }

    private func fallbackModernTopOverlay(_ items: [Requirement]) -> some View {
        HStack(spacing: 6) {
            modernTitleCluster(items)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.52), lineWidth: 0.6)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)

            Spacer(minLength: 6)

            modernTopContentCluster
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.52), lineWidth: 0.6)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)

            modernTopToggleButton
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.52), lineWidth: 0.6)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
    }

    private func modernTitleCluster(_ items: [Requirement]) -> some View {
        HStack(spacing: 5) {
            Text("需求记录")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)

            Text("\(items.count) 项")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.black.opacity(0.38))
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .fixedSize()
    }

    private var modernTopContentCluster: some View {
        HStack(spacing: 0) {
            if isModernTopActionsExpanded {
                if !scriptMenuContents.isEmpty {
                    NativeIconMenuButton(
                        kind: .symbol("terminal"),
                        contents: scriptMenuContents,
                        size: CGSize(width: 28, height: 28),
                        tintAlpha: 0.70,
                        help: "启动脚本",
                        hoverShape: .circle
                    )
                    .frame(width: 28, height: 28)
                }

                if !quickLinkMenuContents.isEmpty {
                    NativeIconMenuButton(
                        kind: .symbol("link"),
                        contents: quickLinkMenuContents,
                        size: CGSize(width: 28, height: 28),
                        tintAlpha: 0.70,
                        help: "快速打开链接",
                        hoverShape: .circle
                    )
                    .frame(width: 28, height: 28)
                }
            } else {
                ForEach(RequirementStatusFilter.allCases) { filter in
                    modernStatusIconButton(filter)
                }
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 32)
        .fixedSize()
        .animation(.snappy(duration: 0.20), value: isModernTopActionsExpanded)
    }

    private func modernStatusIconButton(_ filter: RequirementStatusFilter) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.16)) {
                statusFilter = filter
            }
        } label: {
            Image(systemName: filter.compactSystemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    statusFilter == filter
                        ? DesignColor.doing
                        : Color.black.opacity(0.50)
                )
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(FloatingIconButtonStyle(diameter: 24))
        .help(filter.title)
        .accessibilityLabel(filter.title)
        .accessibilityAddTraits(statusFilter == filter ? .isSelected : [])
        .pointingHandCursor()
    }

    private var modernTopToggleButton: some View {
        Button {
            guard hasModernTopActions else {
                return
            }

            withAnimation(.snappy(duration: 0.20)) {
                isModernTopActionsExpanded.toggle()
            }
        } label: {
            Image(systemName: isModernTopActionsExpanded ? "xmark" : "ellipsis")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(
                    isModernTopActionsExpanded
                        ? DesignColor.doing
                        : Color.black.opacity(0.62)
                )
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(FloatingIconButtonStyle(diameter: 28))
        .disabled(!hasModernTopActions)
        .opacity(hasModernTopActions ? 1 : 0.45)
        .help(isModernTopActionsExpanded ? "关闭操作" : "更多操作")
        .pointingHandCursor(hasModernTopActions)
    }

    private var hasModernTopActions: Bool {
        !scriptMenuContents.isEmpty || !quickLinkMenuContents.isEmpty
    }

    private var addPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlainTextEditor(text: $bulkInput)
                .frame(height: 60)
                .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.13), lineWidth: 0.5)
                )
                .overlay {
                    if bulkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack {
                            HStack {
                                Text("粘贴 Jira 地址或 ZSTAC-123456，一行一个")
                                    .foregroundStyle(.tertiary)
                                    .font(.system(size: 12))
                                Spacer()
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                    }
                }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .padding(.top, 0)
    }

    private func contentList(
        _ items: [Requirement],
        bottomInset: CGFloat,
        topInset: CGFloat = 4,
        coveredBottomHeight: CGFloat = 0
    ) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                if items.isEmpty {
                    EmptyStateView()
                        .padding(.top, 80)
                } else {
                    ForEach(items) { requirement in
                        RequirementRowView(
                            requirement: requirement,
                            isExpanded: expandedIDs[statusFilter] == requirement.id,
                            onToggleExpanded: {
                                withAnimation(.snappy(duration: 0.18)) {
                                    if expandedIDs[statusFilter] == requirement.id {
                                        expandedIDs[statusFilter] = nil
                                    } else {
                                        expandedIDs[statusFilter] = requirement.id
                                    }
                                }
                            }
                        )
                        .environmentObject(store)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .move(edge: .bottom)
                                    .combined(with: .scale(scale: 0.02, anchor: .top))
                                    .combined(with: .opacity)
                            )
                        )
                    }
                }
            }
            .padding(.horizontal, 8)
            // 现代模式的顶部控件覆盖在列表之上，按实测高度留出起始空间；
            // 其余样式继续使用原来的紧凑顶部间距。
            .padding(.top, topInset)
            // 底部控件覆盖在列表之上，按其实测高度增加滚动尾部空间，
            // 让最后一张卡片可以完整滚到控件上方。
            .padding(.bottom, bottomInset)
            .animation(.snappy(duration: 0.22), value: items.map(\.id))
        }
        .scrollIndicators(.never)
        .background(ScrollIndicatorHider())
        // 默认模式的底部控件与列表共用弹窗背景；遮掉控件覆盖范围内的卡片，
        // 避免为了挡住滚动内容而再叠一层颜色不同的材质。
        .mask {
            VStack(spacing: 0) {
                Color.white
                Color.clear.frame(height: coveredBottomHeight)
            }
        }
        // 每个状态 tab 是一棵独立的列表视图：切换 tab 时整体替换，
        // 不与上一个 tab 的列表做 diff 动画，避免卡片“乱跳”。
        .id(statusFilter)
    }

    @ViewBuilder
    private var bottomOverlay: some View {
        switch panelStyle {
        case .standard:
            standardBottomOverlay
        case .minimal:
            minimalBottomOverlay
        case .modern:
            modernBottomOverlay
        }
    }

    private var standardBottomOverlay: some View {
        VStack(spacing: 0) {
            attachedCalendarPanel
            standardFooter
        }
        .frame(maxWidth: .infinity)
    }

    private var minimalBottomOverlay: some View {
        VStack(spacing: 0) {
            minimalFloatingCalendarPanel
            minimalFooter
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var minimalFloatingCalendarPanel: some View {
        if showsCalendar {
            calendarPanel
                .background(minimalBarBackground(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.6)
                )
                .shadow(color: Color.black.opacity(0.10), radius: 8, y: 3)
                .padding(.horizontal, 10)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    @ViewBuilder
    private var attachedCalendarPanel: some View {
        if showsCalendar {
            calendarPanel
                .overlay(alignment: .top) {
                    GlassDivider()
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var standardFooter: some View {
        VStack(spacing: 0) {
            GlassDivider()

            HStack(spacing: 5) {
                dateFilterButton(
                    maximumWidth: 68,
                    controlHeight: 20,
                    fontSize: 10
                )

                inlineSearchField(
                    width: 78,
                    controlHeight: 20,
                    fontSize: 10
                )

                Spacer(minLength: 5)

                settingsMenu(size: CGSize(width: 20, height: 20))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    private var minimalFooter: some View {
        VStack(spacing: 6) {
            if isSearchExpanded {
                minimalSearchFilterBar
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            minimalMainBar
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var minimalMainBar: some View {
        HStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(RequirementStatusFilter.allCases) { filter in
                    Button {
                        withAnimation(.snappy(duration: 0.16)) {
                            statusFilter = filter
                        }
                    } label: {
                        Image(systemName: filter.compactSystemImage)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(
                                statusFilter == filter
                                    ? DesignColor.doing
                                    : Color.black.opacity(0.48)
                            )
                            .frame(width: 19, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(FloatingIconButtonStyle(diameter: 18))
                    .help(filter.title)
                    .accessibilityLabel(filter.title)
                    .accessibilityAddTraits(statusFilter == filter ? .isSelected : [])
                    .pointingHandCursor()
                }
            }

            compactDivider

            HStack(spacing: 0) {
                minimalSearchToggle

                Text("\(visibleRequirements.count) 项")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.46))
                    .fixedSize()
            }

            Spacer(minLength: 0)

            if !scriptMenuContents.isEmpty {
                NativeIconMenuButton(
                    kind: .symbol("terminal"),
                    contents: scriptMenuContents,
                    size: CGSize(width: 24, height: 24),
                    tintAlpha: 0.66,
                    help: "启动脚本",
                    hoverShape: .circle
                )
                .frame(width: 24, height: 24)
            }

            if !quickLinkMenuContents.isEmpty {
                NativeIconMenuButton(
                    kind: .symbol("link"),
                    contents: quickLinkMenuContents,
                    size: CGSize(width: 24, height: 24),
                    tintAlpha: 0.66,
                    help: "快速打开链接",
                    hoverShape: .circle
                )
                .frame(width: 24, height: 24)
            }

            settingsMenu(
                size: CGSize(width: 24, height: 24),
                hoverShape: .circle
            )
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(minimalBarBackground())
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.6)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 8, y: 3)
    }

    private var minimalSearchFilterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.42))
                .frame(width: 18)

            inlineSearchField()
                .frame(maxWidth: .infinity)

            compactDivider

            dateFilterButton(maximumWidth: 72)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(minimalBarBackground())
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.6)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 8, y: 3)
    }

    private var minimalSearchToggle: some View {
        Button {
            toggleSearch()
        } label: {
            Image(systemName: isSearchExpanded ? "xmark" : "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(
                    isSearchExpanded
                        ? DesignColor.doing
                        : Color.black.opacity(0.52)
                )
                .frame(width: 22, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(FloatingIconButtonStyle(diameter: 20))
        .help(isSearchExpanded ? "关闭搜索与筛选" : "搜索与筛选")
        .pointingHandCursor()
    }

    private func minimalBarBackground(cornerRadius: CGFloat = 9) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.36))
            )
    }

    @ViewBuilder
    private var modernBottomOverlay: some View {
        if #available(macOS 26.0, *) {
            nativeModernBottomOverlay
        } else {
            fallbackModernBottomOverlay
        }
    }

    @available(macOS 26.0, *)
    private var nativeModernBottomOverlay: some View {
        GlassEffectContainer(spacing: 4) {
            VStack(spacing: 8) {
                if showsCalendar {
                    calendarPanel
                        .glassEffect(
                            .regular.interactive(),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .glassEffectID("modern-calendar", in: modernGlassNamespace)
                        .padding(.horizontal, 10)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                HStack(spacing: 8) {
                    modernSearchCluster
                        .glassEffect(.regular.interactive(), in: Capsule())
                        .glassEffectID("modern-search", in: modernGlassNamespace)

                    Spacer(minLength: 8)

                    settingsMenu(
                        size: CGSize(width: 34, height: 34),
                        hoverShape: .circle
                    )
                        .glassEffect(.regular.interactive(), in: Circle())
                        .glassEffectID("modern-more", in: modernGlassNamespace)
                }
                .padding(.horizontal, 10)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    private var fallbackModernBottomOverlay: some View {
        VStack(spacing: 8) {
            if showsCalendar {
                calendarPanel
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.52), lineWidth: 0.6)
                    )
                    .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)
                    .padding(.horizontal, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 8) {
                modernSearchCluster
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.52), lineWidth: 0.6)
                    )
                    .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)

                Spacer(minLength: 8)

                settingsMenu(
                    size: CGSize(width: 34, height: 34),
                    hoverShape: .circle
                )
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.52), lineWidth: 0.6)
                    )
                    .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)
            }
            .padding(.horizontal, 10)
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    private var modernSearchCluster: some View {
        HStack(spacing: 3) {
            Button {
                toggleSearch()
            } label: {
                Image(systemName: isSearchExpanded ? "xmark" : "magnifyingglass")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isSearchExpanded ? DesignColor.doing : Color.black.opacity(0.62))
                    .frame(width: 26, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(FloatingIconButtonStyle(diameter: 24))
            .help(isSearchExpanded ? "关闭搜索" : "搜索")
            .pointingHandCursor()

            if isSearchExpanded {
                compactDivider

                inlineSearchField(width: 78)

                compactDivider

                dateFilterButton(maximumWidth: 62)
            }
        }
        .padding(.horizontal, isSearchExpanded ? 4 : 2)
        .frame(height: 34)
        .animation(.snappy(duration: 0.20), value: isSearchExpanded)
    }

    private func inlineSearchField(
        width: CGFloat? = nil,
        controlHeight: CGFloat = 24,
        fontSize: CGFloat = 10.5
    ) -> some View {
        HStack(spacing: 4) {
            TextField("搜索", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize))
                .foregroundStyle(DesignColor.textPrimary)
                .focused($isSearchFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.black.opacity(0.30))
                }
                .buttonStyle(.plain)
                .help("清空搜索")
                .pointingHandCursor()
            }
        }
        .frame(minWidth: width, maxWidth: width ?? .infinity)
        .frame(height: controlHeight)
        .contentShape(Rectangle())
    }

    private func dateFilterButton(
        maximumWidth: CGFloat,
        controlHeight: CGFloat = 24,
        fontSize: CGFloat = 10.5
    ) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.14)) {
                showsCalendar.toggle()
                displayMonth = selectedDay ?? Date()
            }
        } label: {
            HStack(spacing: 3) {
                Text(dateFilterTitle)
                    .lineLimit(1)
                Image(systemName: showsCalendar ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
            }
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(
                showsCalendar || hasActiveDateFilter
                    ? DesignColor.doing
                    : Color.black.opacity(0.58)
            )
            .padding(.horizontal, 3)
            .frame(minWidth: 42, maxWidth: maximumWidth)
            .frame(height: controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainFooterControlButtonStyle(isHovered: isDateFilterHovering))
        .onHover { isDateFilterHovering = $0 }
        .pointingHandCursor()
    }

    private var compactDivider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.10))
            .frame(width: 0.5, height: 15)
    }

    private var calendarPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                ForEach(RequirementDateFilter.allCases) { filter in
                    Button(filter.quickTitle) {
                        applyQuickDateFilter(filter)
                    }
                    .buttonStyle(CalendarQuickButtonStyle(isSelected: dateFilter == filter && selectedDay == nil))
                    .pointingHandCursor()
                }
            }

            HStack {
                Button {
                    moveDisplayMonth(by: -1)
                } label: {
                    Text("‹")
                        .frame(width: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.black.opacity(0.40))
                .pointingHandCursor()

                Spacer()

                Text(monthTitle(displayMonth))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignColor.textPrimary)

                Spacer()

                Button {
                    moveDisplayMonth(by: 1)
                } label: {
                    Text("›")
                        .frame(width: 24)
                }
                .buttonStyle(.plain)
                .disabled(isDisplayingCurrentOrFutureMonth)
                .foregroundStyle(isDisplayingCurrentOrFutureMonth ? Color.black.opacity(0.18) : Color.black.opacity(0.40))
                .pointingHandCursor()
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(weekdaySymbols, id: \.self) { weekday in
                    Text(weekday)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(weekday == "六" || weekday == "日" ? Color.red.opacity(0.55) : Color.black.opacity(0.35))
                        .frame(height: 16)
                }

                ForEach(calendarDays, id: \.id) { day in
                    if let date = day.date {
                        Button {
                            setActiveDateSelection(dateFilter: .all, selectedDay: date)
                            withAnimation(.snappy(duration: 0.14)) {
                                showsCalendar = false
                            }
                        } label: {
                            Text("\(Calendar.current.component(.day, from: date))")
                                .font(.system(size: 11, weight: calendarDayIsSelected(date) ? .semibold : .regular))
                                .frame(maxWidth: .infinity)
                                .frame(height: 19)
                                .foregroundStyle(calendarDayForeground(date))
                                .background(calendarDayBackground(date))
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(date > Date())
                        .pointingHandCursor()
                    } else {
                        Color.clear
                            .frame(height: 19)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 9)
    }

    private func settingsMenu(
        size: CGSize,
        hoverShape: NativeIconMenuHoverShape = .roundedRectangle(cornerRadius: 6)
    ) -> some View {
        NativeIconMenuButton(
            kind: .settings,
            contents: settingsMenuContents,
            size: size,
            tintAlpha: 0.84,
            help: "设置",
            hoverShape: hoverShape
        )
        .frame(width: size.width, height: size.height)
    }

    private var settingsMenuContents: [NativeMenuContent] {
        [
            .item(
                NativeMenuItemDescriptor(title: "总览", systemImage: "square.grid.2x2") {
                    onOpenOverview?()
                }
            ),
            .item(
                NativeMenuItemDescriptor(title: "导出数据", systemImage: "square.and.arrow.down") {
                    store.openDataFolder()
                }
            ),
            .separator(),
            .item(
                NativeMenuItemDescriptor(title: "设置", systemImage: "gearshape") {
                    onOpenSettings?()
                }
            ),
            .item(
                NativeMenuItemDescriptor(title: "关于", systemImage: "info.circle") {
                    onShowAbout?()
                }
            ),
            .item(
                NativeMenuItemDescriptor(title: "退出", systemImage: "power", isDestructive: true) {
                    NSApplication.shared.terminate(nil)
                }
            )
        ]
    }

    private var scriptMenuContents: [NativeMenuContent] {
        settingsStore.validScriptProjects.map { project in
            .submenu(
                NativeSubmenuDescriptor(
                    title: project.name,
                    systemImage: "folder",
                    contents: project.validScripts.map { script in
                        .item(
                            NativeMenuItemDescriptor(title: script.name, systemImage: "terminal") {
                                launchScript(project: project, script: script)
                            }
                        )
                    }
                )
            )
        }
    }

    private var quickLinkMenuContents: [NativeMenuContent] {
        settingsStore.validQuickLinks.map { link in
            .item(
                NativeMenuItemDescriptor(title: link.name, systemImage: "link") {
                    openQuickLink(link)
                }
            )
        }
    }

    private func commitAdding() {
        let addedCount = store.addFromBulkInput(bulkInput)
        guard addedCount > 0 else {
            return
        }

        bulkInput = ""
        withAnimation(.snappy(duration: 0.18)) {
            isAdding = false
        }
    }

    private func expandSearch() {
        withAnimation(.snappy(duration: 0.20)) {
            isSearchExpanded = true
        }

        DispatchQueue.main.async {
            isSearchFocused = true
        }
    }

    private func toggleSearch() {
        guard isSearchExpanded else {
            expandSearch()
            return
        }

        withAnimation(.snappy(duration: 0.20)) {
            searchText = ""
            isSearchExpanded = false
            showsCalendar = false
        }
        isSearchFocused = false
    }

    private func cancelAdding() {
        withAnimation(.snappy(duration: 0.18)) {
            isAdding = false
            bulkInput = ""
        }
    }

    private func launchScript(
        project: RequirementScriptProject,
        script: RequirementScriptCommand
    ) {
        Task {
            do {
                try await scriptLauncher.launch(project: project, script: script)
                store.lastNotice = "已启动 \(script.name)"
            } catch {
                store.lastNotice = error.localizedDescription
            }
        }
    }

    private func openQuickLink(_ link: RequirementQuickLink) {
        guard let url = URL(string: link.url) else {
            store.lastNotice = "链接格式无效"
            return
        }

        NSWorkspace.shared.open(url)
        store.lastNotice = "已打开 \(link.name)"
    }

    private var hasActiveDateFilter: Bool {
        dateFilter != .all || selectedDay != nil
    }

    private var activeDateSelection: RequirementPanelDateSelection {
        settingsStore.panelDateSelection(for: statusFilter)
    }

    private var dateFilter: RequirementDateFilter {
        activeDateSelection.dateFilter
    }

    private var selectedDay: Date? {
        activeDateSelection.selectedDay
    }

    private var dateFilterTitle: String {
        if let selectedDay {
            return shortDateTitle(selectedDay)
        }

        return dateFilter.quickTitle
    }

    private var weekdaySymbols: [String] {
        ["一", "二", "三", "四", "五", "六", "日"]
    }

    private var isDisplayingCurrentOrFutureMonth: Bool {
        let calendar = Calendar.current
        let displayComponents = calendar.dateComponents([.year, .month], from: displayMonth)
        let currentComponents = calendar.dateComponents([.year, .month], from: Date())
        guard
            let displayDate = calendar.date(from: displayComponents),
            let currentDate = calendar.date(from: currentComponents)
        else {
            return true
        }

        return displayDate >= currentDate
    }

    private var calendarDays: [CalendarDay] {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: displayMonth)
        guard
            let firstDay = calendar.date(from: components),
            let range = calendar.range(of: .day, in: .month, for: firstDay)
        else {
            return []
        }

        let weekday = calendar.component(.weekday, from: firstDay)
        let leadingBlanks = (weekday + 5) % 7
        var days = (0..<leadingBlanks).map { CalendarDay(id: "blank-\($0)", date: nil) }

        for day in range {
            let date = calendar.date(byAdding: .day, value: day - 1, to: firstDay)
            days.append(CalendarDay(id: "day-\(day)", date: date))
        }

        return days
    }

    private func applyQuickDateFilter(_ filter: RequirementDateFilter) {
        setActiveDateSelection(dateFilter: filter, selectedDay: nil)
        withAnimation(.snappy(duration: 0.14)) {
            showsCalendar = false
        }
    }

    private func setActiveDateSelection(
        dateFilter: RequirementDateFilter,
        selectedDay: Date?
    ) {
        settingsStore.setPanelDateSelection(
            RequirementPanelDateSelection(dateFilter: dateFilter, selectedDay: selectedDay),
            for: statusFilter
        )
    }

    private func moveDisplayMonth(by offset: Int) {
        guard let newMonth = Calendar.current.date(byAdding: .month, value: offset, to: displayMonth) else {
            return
        }

        displayMonth = minMonth(newMonth, Date())
    }

    private func minMonth(_ lhs: Date, _ rhs: Date) -> Date {
        let calendar = Calendar.current
        let leftComponents = calendar.dateComponents([.year, .month], from: lhs)
        let rightComponents = calendar.dateComponents([.year, .month], from: rhs)
        guard
            let left = calendar.date(from: leftComponents),
            let right = calendar.date(from: rightComponents)
        else {
            return lhs
        }

        return left > right ? right : lhs
    }

    private func calendarDayForeground(_ date: Date) -> Color {
        if date > Date() {
            return Color.black.opacity(0.20)
        }

        if calendarDayIsSelected(date) {
            return .white
        }

        return DesignColor.textPrimary
    }

    @ViewBuilder
    private func calendarDayBackground(_ date: Date) -> some View {
        if calendarDayIsSelected(date) {
            DesignColor.doing
        } else {
            Color.clear
        }
    }

    private func calendarDayIsSelected(_ date: Date) -> Bool {
        if let selectedDay {
            return Calendar.current.isDate(date, inSameDayAs: selectedDay)
        }

        return Calendar.current.isDateInToday(date)
    }

    private func monthTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年 M月"
        return formatter.string(from: date)
    }

    private func shortDateTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

}

private struct CalendarDay: Identifiable {
    let id: String
    let date: Date?
}

private struct BottomOverlayHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ModernTopOverlayHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ScrollIndicatorHider: NSViewRepresentable {
    func makeNSView(context: Context) -> HiderAttachmentView {
        HiderAttachmentView()
    }

    func updateNSView(_ view: HiderAttachmentView, context: Context) {
        view.refresh()
    }
}

/// 零宽、不绘制的滚动条：即使系统在滚动时重新启用它，也完全不可见，
/// 因此不会再出现“偶尔闪出滚动条”的情况。
private final class HiddenScroller: NSScroller {
    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        0
    }

    override func draw(_ dirtyRect: NSRect) {}
    override func drawKnob() {}
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

/// 持续隐藏弹窗内 ScrollView 的滚动条。除了出现/布局/滚动通知时复位外，
/// 还监听滚动内容的 bounds 变化：鼠标滚轮滚动不一定派发 live-scroll 通知，
/// 但一定改变 contentView 的 bounds，以此兜住滚动过程中被系统加回的滚动条。
private final class HiderAttachmentView: NSView {
    private var isObserving = false
    private var observedContentViews = Set<ObjectIdentifier>()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startObservingIfNeeded()
        refresh()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        refresh()
    }

    override func layout() {
        super.layout()
        refresh()
    }

    func refresh() {
        guard let contentView = window?.contentView else {
            return
        }
        hideScrollers(in: contentView)
    }

    private func startObservingIfNeeded() {
        guard !isObserving else {
            return
        }
        isObserving = true

        let center = NotificationCenter.default
        for name in [
            NSScrollView.willStartLiveScrollNotification,
            NSScrollView.didLiveScrollNotification,
            NSScrollView.didEndLiveScrollNotification
        ] {
            center.addObserver(self, selector: #selector(handleScroll(_:)), name: name, object: nil)
        }
    }

    @objc private func handleScroll(_ notification: Notification) {
        guard
            let scrollView = notification.object as? NSScrollView,
            scrollView.window === window
        else {
            return
        }
        applyHiddenState(scrollView)
        reapplyAfterCurrentPass(scrollView)
    }

    @objc private func handleContentBoundsChange(_ notification: Notification) {
        guard
            let contentView = notification.object as? NSClipView,
            contentView.window === window,
            let scrollView = contentView.enclosingScrollView
        else {
            return
        }
        applyHiddenState(scrollView)
        reapplyAfterCurrentPass(scrollView)
    }

    /// SwiftUI 可能在同一轮事件里把滚动条按系统 legacy 样式重新加回
    ///（右侧重新出现占位），追加一次异步复位，确保这轮更新之后仍不占位。
    private func reapplyAfterCurrentPass(_ scrollView: NSScrollView) {
        DispatchQueue.main.async { [weak self, weak scrollView] in
            guard let self, let scrollView else {
                return
            }
            self.applyHiddenState(scrollView)
        }
    }

    private func hideScrollers(in view: NSView) {
        if let scrollView = view as? NSScrollView {
            applyHiddenState(scrollView)
        }

        for subview in view.subviews {
            hideScrollers(in: subview)
        }
    }

    // SwiftUI 在滚动的每一帧都可能把 scrollerStyle 重置回系统 legacy 样式
    //（右侧重新预留占位），这里按需纠正、无变化时零开销，可安全高频调用。
    private func applyHiddenState(_ scrollView: NSScrollView) {
        if scrollView.scrollerStyle != .overlay {
            scrollView.scrollerStyle = .overlay
        }
        if !scrollView.autohidesScrollers {
            scrollView.autohidesScrollers = true
        }
        if scrollView.hasHorizontalScroller {
            scrollView.hasHorizontalScroller = false
        }
        if scrollView.hasVerticalScroller {
            scrollView.hasVerticalScroller = false
        }
        if !(scrollView.verticalScroller is HiddenScroller) {
            scrollView.verticalScroller = HiddenScroller()
        }
        if !(scrollView.horizontalScroller is HiddenScroller) {
            scrollView.horizontalScroller = HiddenScroller()
        }

        observeContentBoundsIfNeeded(scrollView)
    }

    private func observeContentBoundsIfNeeded(_ scrollView: NSScrollView) {
        let identifier = ObjectIdentifier(scrollView.contentView)
        guard !observedContentViews.contains(identifier) else {
            return
        }
        observedContentViews.insert(identifier)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleContentBoundsChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

private struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = NSFont.systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 60)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            text = textView.string
        }
    }
}

private struct FloatingIconButtonStyle: ButtonStyle {
    let diameter: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(
                FloatingIconFeedbackModifier(
                    diameter: diameter,
                    isPressed: configuration.isPressed
                )
            )
    }
}

private struct FloatingIconFeedbackModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    let diameter: CGFloat
    let isPressed: Bool

    func body(content: Content) -> some View {
        content
            .background {
                Circle()
                    .fill(Color.black.opacity(feedbackOpacity))
                    .frame(width: diameter, height: diameter)
                    .allowsHitTesting(false)
            }
            .onHover { isHovering = isEnabled && $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: isPressed)
    }

    private var feedbackOpacity: Double {
        guard isEnabled else {
            return 0
        }

        if isPressed {
            return 0.10
        }

        return isHovering ? 0.06 : 0
    }
}

private struct HeaderSegmentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, isProminent ? 12 : 10)
            .frame(height: 24)
            .background(backgroundColor(isPressed: configuration.isPressed))
    }

    private var foregroundColor: Color {
        if !isEnabled {
            return Color.black.opacity(0.32)
        }

        return isProminent ? Color.white : Color.black.opacity(0.60)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if !isEnabled {
            return Color.black.opacity(0.06)
        }

        return isProminent ? DesignColor.doing.opacity(isPressed ? 0.78 : 1)
            : Color.black.opacity(isPressed ? 0.08 : 0.04)
    }
}

private struct HeaderAddButtonStyle: ButtonStyle {
    var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let backgroundOpacity = if configuration.isPressed {
            0.10
        } else if isHovered {
            0.06
        } else {
            0.0
        }

        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(DesignColor.textPrimary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
            .background(
                Color.black.opacity(backgroundOpacity),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }
}

private struct PlainFooterControlButtonStyle: ButtonStyle {
    var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.54 : (isHovered ? 0.78 : 1))
    }
}

private struct CalendarQuickButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Color.white : Color.black.opacity(0.65))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                isSelected ? DesignColor.doing : Color.black.opacity(configuration.isPressed ? 0.08 : 0.05),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }
}

private struct StatusSegmentBar: View {
    @Binding var selection: RequirementStatusFilter

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(RequirementStatusFilter.allCases.enumerated()), id: \.element.id) { index, filter in
                Button {
                    withAnimation(.snappy(duration: 0.16)) {
                        selection = filter
                    }
                } label: {
                    Text(filter.title)
                        .font(.system(size: 10.5, weight: selection == filter ? .semibold : .regular))
                        .foregroundStyle(selection == filter ? DesignColor.textPrimary : Color.black.opacity(0.50))
                        .frame(maxWidth: .infinity)
                        .frame(height: 20)
                        .contentShape(Rectangle())
                        .background(
                            Group {
                                if selection == filter {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color.white.opacity(0.95))
                                        .shadow(color: Color.black.opacity(0.12), radius: 3, y: 1)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                if index < RequirementStatusFilter.allCases.count - 1 {
                    Color.clear
                        .frame(width: 1)
                }
            }
        }
        .padding(2)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.05))
        )
    }
}

private extension RequirementStatusFilter {
    var compactSystemImage: String {
        switch self {
        case .incomplete:
            "circle"
        case .active:
            "play.fill"
        case .pending:
            "clock.fill"
        case .paused:
            "exclamationmark.triangle.fill"
        case .completed:
            "checkmark.circle.fill"
        }
    }
}

private extension RequirementDateFilter {
    var quickTitle: String {
        switch self {
        case .all:
            "全部"
        case .today:
            "今日"
        case .thisWeek:
            "本周"
        case .thisMonth:
            "本月"
        }
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)

            Text("没有匹配的需求")
                .font(.headline)

            Text("可以调整筛选条件，或点击右上角添加。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
