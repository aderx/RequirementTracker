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
    @State private var expandedID: Requirement.ID?
    @State private var showsCalendar = false
    @State private var displayMonth = Date()
    @State private var isDateFilterHovering = false
    @State private var isAddButtonHovering = false

    private var visibleRequirements: [Requirement] {
        let filtered = RequirementQuery.filteredAndSorted(
            store.requirements,
            statusFilter: statusFilter,
            dateFilter: dateFilter
        )

        guard let selectedDay else {
            return filtered
        }

        return filtered.filter {
            Calendar.current.isDate($0.activityDate, inSameDayAs: selectedDay)
        }
    }

    private var panelHeight: CGFloat {
        RequirementPanelMetrics.height(isCalendarVisible: showsCalendar)
    }

    var body: some View {
        ZStack {
            Color.clear
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                if isAdding {
                    addPanel
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                filterBar

                GlassDivider()

                contentList

                if showsCalendar {
                    GlassDivider()

                    calendarPanel
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                GlassDivider()
                footer
            }

        }
        .frame(width: RequirementPanelMetrics.width, height: panelHeight)
        .onAppear {
            onCalendarVisibilityChange?(showsCalendar)
        }
        .onChange(of: showsCalendar) { isVisible in
            onCalendarVisibilityChange?(isVisible)
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Text("需求记录")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)

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

    private var contentList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                if visibleRequirements.isEmpty {
                    EmptyStateView()
                        .padding(.top, 80)
                } else {
                    ForEach(visibleRequirements) { requirement in
                        RequirementRowView(
                            requirement: requirement,
                            isExpanded: expandedID == requirement.id,
                            onToggleExpanded: {
                                withAnimation(.snappy(duration: 0.18)) {
                                    expandedID = expandedID == requirement.id ? nil : requirement.id
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
            .padding(.vertical, 4)
            .animation(.snappy(duration: 0.22), value: visibleRequirements.map(\.id))
        }
        .scrollIndicators(.hidden)
        .background(ScrollIndicatorHider())
    }

    private var footer: some View {
        HStack(spacing: 7) {
            dateFilterButton

            Text("\(visibleRequirements.count) 项")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.black.opacity(0.38))

            Spacer()

            settingsMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var dateFilterButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.14)) {
                showsCalendar.toggle()
                displayMonth = selectedDay ?? Date()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(.system(size: 10, weight: .medium))
                Text(dateFilterTitle)
                    .lineLimit(1)
                Image(systemName: showsCalendar ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 76)
            .frame(height: 22)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(FooterChipButtonStyle(isSelected: showsCalendar || hasActiveDateFilter, isHovered: isDateFilterHovering))
        .fixedSize()
        .onHover { isDateFilterHovering = $0 }
        .pointingHandCursor()
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

    private var settingsMenu: some View {
        NativeIconMenuButton(
            kind: .settings,
            contents: settingsMenuContents,
            size: CGSize(width: 24, height: 22),
            tintAlpha: 0.84,
            help: "设置"
        )
        .frame(width: 24, height: 22)
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

private struct ScrollIndicatorHider: NSViewRepresentable {
    func makeNSView(context: Context) -> HiderAttachmentView {
        let view = HiderAttachmentView()
        view.scheduleHidingPasses()
        return view
    }

    func updateNSView(_ view: HiderAttachmentView, context: Context) {
        view.scheduleHidingPasses()
    }
}

private final class HiderAttachmentView: NSView {
    private var isHidingScheduled = false

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleHidingPasses()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleHidingPasses()
    }

    override func layout() {
        super.layout()
        scheduleHidingPasses()
    }

    func scheduleHidingPasses() {
        guard !isHidingScheduled else {
            return
        }

        isHidingScheduled = true
        let delays = [0.0, 0.05, 0.2, 0.6, 1.2]
        for (index, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.hideIndicators()
                if index == delays.count - 1 {
                    self?.isHidingScheduled = false
                }
            }
        }
    }

    private func hideIndicators() {
        var current: NSView? = self
        while let candidate = current {
            hideScrollIndicators(in: candidate)
            current = candidate.superview
        }

        if let contentView = window?.contentView {
            hideScrollIndicators(in: contentView)
        }
    }

    private func hideScrollIndicators(in view: NSView) {
        if let scrollView = view as? NSScrollView {
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            scrollView.verticalScroller = nil
            scrollView.horizontalScroller = nil
        }

        if let scroller = view as? NSScroller {
            scroller.isHidden = true
            scroller.alphaValue = 0
        }

        for subview in view.subviews {
            hideScrollIndicators(in: subview)
        }
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

private struct FooterChipButtonStyle: ButtonStyle {
    var isSelected = false
    var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let backgroundOpacity = if isSelected {
            0.07
        } else if configuration.isPressed {
            0.10
        } else if isHovered {
            0.07
        } else {
            0.04
        }

        configuration.label
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(isSelected ? DesignColor.doing : Color.black.opacity(0.65))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? DesignColor.doing.opacity(backgroundOpacity) : Color.black.opacity(backgroundOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? DesignColor.doing.opacity(0.25) : Color.black.opacity(0.11), lineWidth: 0.5)
            )
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
