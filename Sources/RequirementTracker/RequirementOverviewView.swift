import AppKit
import RequirementCore
import SwiftUI

private let overviewTopHeaderHeight: CGFloat = 60

struct RequirementOverviewView: View {
    @EnvironmentObject private var store: RequirementStore

    @State private var selectedID: Requirement.ID?
    @State private var selectedFilter: OverviewStatusFilter = .all
    @State private var selectedDateFilter: RequirementDateFilter = .all
    @State private var expandedToolbarPanel: OverviewToolbarPanel?
    @State private var searchText = ""
    @State private var selectedIssueType = ""
    @State private var selectedPriority = ""
    @State private var selectedTargetVersion = ""
    @State private var editingDraft: OverviewDraft?
    @State private var isShowingConfirmation = false
    @State private var sidebarWidth: CGFloat = 330
    @AppStorage("RequirementOverview.sortMode") private var overviewSortModeRawValue = RequirementOverviewSortMode.createdAt.rawValue

    private var overviewSortMode: RequirementOverviewSortMode {
        RequirementOverviewSortMode(rawValue: overviewSortModeRawValue) ?? .createdAt
    }

    private var sortedRequirements: [Requirement] {
        RequirementQuery.sortedForOverview(store.requirements, by: overviewSortMode)
    }

    private var statusFilteredRequirements: [Requirement] {
        RequirementQuery.filteredForOverview(
            dateScopedRequirements,
            status: selectedFilter.timelineStatus
        )
    }

    private var overviewMetadataFilter: RequirementOverviewMetadataFilter {
        RequirementOverviewMetadataFilter(
            issueType: selectedIssueType,
            priority: selectedPriority,
            targetVersion: selectedTargetVersion
        )
    }

    private var overviewMetadataOptions: RequirementOverviewMetadataOptions {
        RequirementQuery.overviewMetadataOptions(for: store.requirements)
    }

    private var metadataFilteredRequirements: [Requirement] {
        RequirementQuery.filteredForOverview(
            statusFilteredRequirements,
            metadata: overviewMetadataFilter
        )
    }

    private var visibleRequirements: [Requirement] {
        let query = normalized(searchText)
        guard !query.isEmpty else {
            return metadataFilteredRequirements
        }

        let queryParts = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return metadataFilteredRequirements.filter { requirement in
            let searchableText = ([
                requirement.jiraURL
            ] + requirement.allMRURLs + [
                requirement.title,
                requirement.note,
                requirement.pauseReason,
                requirement.issueType ?? "",
                requirement.priority ?? "",
                requirement.targetVersion ?? ""
            ])
            .joined(separator: " ")
            .foldedForSearch

            return queryParts.allSatisfy { searchableText.contains($0.foldedForSearch) }
        }
    }

    private var dateScopedRequirements: [Requirement] {
        sortedRequirements.filter(matchesSelectedDateFilter)
    }

    private var selectedRequirement: Requirement? {
        if let selectedID, let requirement = visibleRequirements.first(where: { $0.id == selectedID }) {
            return requirement
        }

        return visibleRequirements.first
    }

    private var isEditing: Bool {
        editingDraft != nil
    }

    private var pendingChanges: [OverviewChange] {
        guard let selectedRequirement, let editingDraft else {
            return []
        }

        return changes(for: selectedRequirement, draft: editingDraft)
    }

    private var canSaveDraft: Bool {
        guard let draft = editingDraft else {
            return false
        }

        if draft.isMarkedForDeletion {
            return true
        }

        if draft.status.requiresReason
            && draft.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }

        if draft.status == .merged && draft.mrURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }

        return !pendingChanges.isEmpty
    }

    private var isConfirmingDeletion: Bool {
        pendingChanges.contains { $0.field == .delete }
    }

    private var mergeDraftRequiresMR: Bool {
        guard let draft = editingDraft else {
            return false
        }

        return draft.status == .merged && draft.mrURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
                .ignoresSafeArea()

            if sortedRequirements.isEmpty {
                OverviewEmptyState()
            } else {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: sidebarWidth)
                        .opacity(isEditing ? 0.5 : 1)
                        .allowsHitTesting(!isEditing && !isShowingConfirmation)

                    OverviewSplitDivider(sidebarWidth: $sidebarWidth)
                        .allowsHitTesting(!isEditing && !isShowingConfirmation)

                    detailPanel
                }
            }

            if isShowingConfirmation {
                confirmationOverlay
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .background(TransparentWindowConfigurator())
        .onAppear(perform: ensureSelection)
        .onReceive(store.$requirements) { _ in
            ensureSelection()
        }
        .onChange(of: selectedFilter) { _ in
            ensureSelection()
        }
        .onChange(of: selectedDateFilter) { _ in
            ensureSelection()
        }
        .onChange(of: searchText) { _ in
            ensureSelection()
        }
        .onChange(of: selectedIssueType) { _ in
            ensureSelection()
        }
        .onChange(of: selectedPriority) { _ in
            ensureSelection()
        }
        .onChange(of: selectedTargetVersion) { _ in
            ensureSelection()
        }
        .animation(.snappy(duration: 0.16), value: isShowingConfirmation)
        .animation(.easeInOut(duration: 0.15), value: expandedToolbarPanel)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            statsGrid

            overviewToolbar

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 4) {
                    if visibleRequirements.isEmpty {
                        OverviewListEmptyState(
                            isSearching: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        .padding(.top, 70)
                    } else {
                        ForEach(Array(visibleRequirements.enumerated()), id: \.element.id) { index, requirement in
                            Button {
                                selectedID = requirement.id
                            } label: {
                                OverviewRequirementListRow(
                                    index: index + 1,
                                    requirement: requirement,
                                    isSelected: selectedRequirement?.id == requirement.id
                                )
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                        }
                    }
                }
                .padding(8)
            }
        }
        .background(Color.white.opacity(0.24))
    }

    private var statsGrid: some View {
        let stats = OverviewStats(requirements: dateScopedRequirements)

        return HStack(spacing: 8) {
            OverviewStatTile(
                filter: .all,
                value: stats.total,
                tint: OverviewStatusFilter.all.tint,
                isSelected: selectedFilter == .all,
                isPrimary: true
            ) {
                selectedFilter = .all
            }
            .frame(width: 72)

            VStack(spacing: 5) {
                overviewStatusFilterRow(OverviewStatusFilter.firstRow, stats: stats)
                overviewStatusFilterRow(OverviewStatusFilter.secondRow, stats: stats)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: overviewTopHeaderHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.07))
                .frame(height: 0.5)
        }
    }

    private func overviewStatusFilterRow(
        _ filters: [OverviewStatusFilter],
        stats: OverviewStats
    ) -> some View {
        HStack(spacing: 5) {
            ForEach(filters) { filter in
                OverviewStatTile(
                    filter: filter,
                    value: stats.value(for: filter),
                    tint: filter.tint,
                    isSelected: selectedFilter == filter
                ) {
                    selectedFilter = filter
                }
            }
        }
    }

    private var overviewToolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(RequirementDateFilter.allCases) { filter in
                        Button {
                            selectedDateFilter = filter
                        } label: {
                            Label(
                                filter.overviewTitle,
                                systemImage: selectedDateFilter == filter ? "checkmark" : "calendar"
                            )
                        }
                    }
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(
                    OverviewIconButtonStyle(
                        isSelected: selectedDateFilter != .all,
                        width: 24,
                        height: 20
                    )
                )
                .help(selectedDateFilter == .all ? "选择时间范围" : "时间范围：\(selectedDateFilter.overviewTitle)")
                .pointingHandCursor()

                Menu {
                    ForEach(RequirementOverviewSortMode.allCases) { mode in
                        Button {
                            overviewSortModeRawValue = mode.rawValue
                        } label: {
                            Label(
                                mode.title,
                                systemImage: overviewSortMode == mode
                                    ? "checkmark"
                                    : (mode == .createdAt ? "calendar" : "clock.arrow.circlepath")
                            )
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(
                    OverviewIconButtonStyle(
                        isSelected: overviewSortMode == .updatedAt,
                        width: 24,
                        height: 20
                    )
                )
                .help("排序：\(overviewSortMode.title)")
                .pointingHandCursor()

                Spacer(minLength: 8)

                Button {
                    toggleToolbarPanel(.jiraFilters)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(
                    OverviewIconButtonStyle(
                        isSelected: expandedToolbarPanel == .jiraFilters || !overviewMetadataFilter.isEmpty,
                        width: 24,
                        height: 20
                    )
                )
                .help(overviewMetadataFilter.isEmpty ? "Jira 属性筛选" : "Jira 属性筛选（已启用）")
                .pointingHandCursor()

                Button {
                    toggleToolbarPanel(.search)
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(
                    OverviewIconButtonStyle(
                        isSelected: expandedToolbarPanel == .search || !normalized(searchText).isEmpty,
                        width: 24,
                        height: 20
                    )
                )
                .help(normalized(searchText).isEmpty ? "搜索" : "搜索（已启用）")
                .pointingHandCursor()
            }
            .padding(.horizontal, 10)
            .frame(height: 32)

            expandedOverviewToolbarContent
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var expandedOverviewToolbarContent: some View {
        if expandedToolbarPanel == .search {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.34))

                TextField("搜索 Jira / MR / 标题 / 备注 / 原因", text: $searchText)
                    .font(.system(size: 11))
                    .textFieldStyle(.plain)

                if !normalized(searchText).isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.black.opacity(0.32))
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                    .pointingHandCursor()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 25)
            .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else if expandedToolbarPanel == .jiraFilters {
            HStack(spacing: 5) {
                OverviewMetadataFilterMenu(
                    title: "类型",
                    selection: $selectedIssueType,
                    options: overviewMetadataOptions.issueTypes
                )

                OverviewMetadataFilterMenu(
                    title: "优先级",
                    selection: $selectedPriority,
                    options: overviewMetadataOptions.priorities
                )

                OverviewMetadataFilterMenu(
                    title: "版本",
                    selection: $selectedTargetVersion,
                    options: overviewMetadataOptions.targetVersions
                )

                if !overviewMetadataFilter.isEmpty {
                    Button {
                        clearOverviewMetadataFilters()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .bold))
                    }
                    .buttonStyle(
                        OverviewIconButtonStyle(
                            isSelected: false,
                            width: 22,
                            height: 20
                        )
                    )
                    .help("清除 Jira 筛选")
                    .pointingHandCursor()
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var detailPanel: some View {
        if let selectedRequirement {
            if editingDraft != nil {
                editPanel(for: selectedRequirement)
            } else {
                readOnlyPanel(for: selectedRequirement)
            }
        } else {
            OverviewEmptyState()
        }
    }

    private func readOnlyPanel(for requirement: Requirement) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(requirement.jiraKey)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(OverviewStatusOption(requirement: requirement).tint)
                        .textSelection(.enabled)

                    Text(requirement.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.56))
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    Text("\(relativeDateText(requirement.activityDate))更新")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.black.opacity(0.40))
                }

                Spacer()

                Button("编辑") {
                    beginEditing(requirement)
                }
                .buttonStyle(OverviewPrimaryButtonStyle())
                .pointingHandCursor()
            }
            .padding(.horizontal, 20)
            .frame(height: overviewTopHeaderHeight)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.black.opacity(0.07))
                    .frame(height: 0.5)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    OverviewDetailRow(label: "状态") {
                        OverviewStatusBadge(status: OverviewStatusOption(requirement: requirement))
                    }

                    OverviewDetailRow(label: "Jira类型") {
                        OverviewTextValue(
                            text: requirement.issueType ?? "",
                            emptyText: "暂无",
                            isMonospaced: false,
                            textColor: overviewIssueTypeColor(for: requirement.issueType ?? "")
                        )
                    }

                    OverviewDetailRow(label: "优先级") {
                        OverviewTextValue(
                            text: requirement.priority ?? "",
                            emptyText: "暂无",
                            isMonospaced: false,
                            textColor: overviewPriorityColor(for: requirement.priority ?? "")
                        )
                    }

                    OverviewDetailRow(label: "版本") {
                        OverviewTextValue(
                            text: requirement.targetVersion ?? "",
                            emptyText: "暂无",
                            isMonospaced: false,
                            textColor: overviewVersionColor
                        )
                    }

                    if requirement.stage == .paused || requirement.stage == .stopped {
                        OverviewDetailRow(
                            label: requirement.stage == .stopped ? "停止原因" : "暂停原因",
                            labelColor: OverviewStatusOption(requirement: requirement).tint,
                            alignment: .top,
                            labelTopPadding: 1,
                            labelWeight: .semibold
                        ) {
                            OverviewTextValue(
                                text: requirement.pauseReason,
                                emptyText: "暂无",
                                isMonospaced: false
                            )
                        }
                    }

                    OverviewDetailRow(label: "Jira") {
                        OverviewLinkValue(text: requirement.jiraURL)
                    }

                    OverviewDetailRow(label: "MR", alignment: .top, labelTopPadding: 1) {
                        if requirement.allMRURLs.isEmpty {
                            OverviewLinkValue(text: "", emptyText: "暂无")
                        } else {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(requirement.allMRURLs, id: \.self) { mrURL in
                                    OverviewLinkValue(text: mrURL)
                                }
                            }
                        }
                    }

                    OverviewDetailRow(label: "备注", alignment: .top, labelTopPadding: 1) {
                        OverviewTextValue(
                            text: requirement.note,
                            emptyText: "暂无说明",
                            isMonospaced: false
                        )
                    }

                    timelineSection(for: requirement)
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func editPanel(for requirement: Requirement) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(requirement.jiraKey)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(OverviewStatusOption(requirement: requirement).tint)
                        .textSelection(.enabled)

                    Text(requirement.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.56))
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                Button("取消") {
                    cancelEditing()
                }
                .buttonStyle(OverviewSecondaryButtonStyle())
                .pointingHandCursor()

                Button("保存修改") {
                    presentConfirmationIfNeeded()
                }
                .buttonStyle(OverviewPrimaryButtonStyle())
                .disabled(!canSaveDraft)
                .opacity(canSaveDraft ? 1 : 0.45)
                .pointingHandCursor(canSaveDraft)
            }
            .padding(.horizontal, 20)
            .frame(height: overviewTopHeaderHeight)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.black.opacity(0.07))
                    .frame(height: 0.5)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("状态")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.40))

                        LazyVGrid(
                            columns: [
                                GridItem(.adaptive(minimum: 78), spacing: 8)
                            ],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(OverviewStatusOption.allCases) { option in
                                Button {
                                    editingDraft?.status = option
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: option.systemImage)
                                            .font(.system(size: 10, weight: .semibold))
                                        Text(option.title)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                }
                                .buttonStyle(
                                    OverviewStatusOptionButtonStyle(
                                        status: option,
                                        isSelected: editingDraft?.status == option
                                    )
                                )
                                .pointingHandCursor()
                            }
                        }
                    }
                    .padding(.bottom, 16)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.black.opacity(0.06))
                            .frame(height: 0.5)
                    }

                    OverviewEditFieldRow(label: "Jira") {
                        TextField("Jira 地址", text: draftStringBinding(\.jiraURL))
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                    }

                    OverviewEditFieldRow(label: "MR") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("MR 地址", text: draftStringBinding(\.mrURL))
                                .font(.system(size: 12, design: .monospaced))
                                .textFieldStyle(.roundedBorder)

                            if mergeDraftRequiresMR {
                                Label("转为已合并前需要填写 MR 地址", systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(DesignColor.stopped)
                            }
                        }
                    }

                    OverviewEditFieldRow(label: "备注", alignment: .top, labelTopPadding: 9) {
                        OverviewTextEditor(text: draftStringBinding(\.note), height: 72)
                    }

                    if let draft = editingDraft, draft.status.requiresReason {
                        reasonEditor(status: draft.status)
                            .padding(.top, 2)
                    }

                    deleteSection
                }
                .padding(20)
            }
        }
    }

    private var deleteSection: some View {
        let isMarked = editingDraft?.isMarkedForDeletion == true

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                editingDraft?.isMarkedForDeletion.toggle()
            } label: {
                Label(isMarked ? "取消删除标记" : "删除需求", systemImage: isMarked ? "arrow.uturn.backward" : "trash")
            }
            .buttonStyle(OverviewDestructiveSecondaryButtonStyle(isMarked: isMarked))
            .pointingHandCursor()

            if isMarked {
                Text("已标记删除，点击右上角保存修改后需要再次确认。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DesignColor.stopped.opacity(0.78))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18)
    }

    private func reasonEditor(status: OverviewStatusOption) -> some View {
        let title = status == .stopped ? "停止原因" : "暂停原因"

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: status == .stopped ? "xmark.circle.fill" : "pause.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(status.tint)

            OverviewTextEditor(text: draftStringBinding(\.reason), height: 60)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(status.tint.opacity(0.20), lineWidth: 0.5)
                )
        }
        .padding(12)
        .background(status.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(status.tint.opacity(0.20), lineWidth: 0.5)
        )
    }

    private func timelineSection(for requirement: Requirement) -> some View {
        let entries = overviewTimelineEntries(for: requirement)

        return VStack(alignment: .leading, spacing: 10) {
            Text("状态记录")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.30))

            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: entry.status.systemImage)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(entry.status.tint)
                            .frame(width: 14)

                        Text(entry.status.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.65))
                            .frame(width: 58, alignment: .leading)

                        Text(timelineDateText(entry.date))
                            .font(.system(size: 10))
                            .foregroundStyle(Color.black.opacity(0.35))

                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)

                    if index < entries.count - 1 {
                        Rectangle()
                            .fill(Color.black.opacity(0.05))
                            .frame(height: 0.5)
                    }
                }
            }
            .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.top, 20)
    }

    private var confirmationOverlay: some View {
        ZStack {
            VisualEffectView(material: .popover, blendingMode: .withinWindow)
                .opacity(0.28)
                .ignoresSafeArea()

            Color.black.opacity(0.055)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isConfirmingDeletion ? "删除确认" : "修改确认")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(isConfirmingDeletion ? DesignColor.stopped : Color(hex: 0x0055CC))

                    Text(isConfirmingDeletion ? "确认删除该需求？该操作会从总览和弹窗列表中移除。" : "检测到 \(pendingChanges.count) 个修改，确认提交？还原某项可单独撤销该修改")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.black.opacity(0.60))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Rectangle().fill(DesignColor.doing.opacity(0.06)))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.black.opacity(0.07))
                        .frame(height: 0.5)
                }

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(pendingChanges) { change in
                            OverviewChangeCard(change: change) {
                                revertChange(change.field)
                            }
                        }
                    }
                    .padding(16)
                }
                .frame(maxHeight: 400)

                HStack(spacing: 8) {
                    Spacer()

                    Button("取消") {
                        isShowingConfirmation = false
                    }
                    .buttonStyle(OverviewSecondaryButtonStyle())
                    .pointingHandCursor()

                    Button(isConfirmingDeletion ? "确认删除" : "确认提交") {
                        commitEditing()
                    }
                    .buttonStyle(OverviewPrimaryButtonStyle(tint: isConfirmingDeletion ? DesignColor.stopped : DesignColor.doing))
                    .disabled(pendingChanges.isEmpty)
                    .opacity(pendingChanges.isEmpty ? 0.45 : 1)
                    .pointingHandCursor(!pendingChanges.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.black.opacity(0.07))
                        .frame(height: 0.5)
                }
            }
            .frame(width: 520)
            .background(Color.white.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.22), radius: 24, y: 12)
        }
    }

    private func ensureSelection() {
        guard !visibleRequirements.isEmpty else {
            selectedID = nil
            editingDraft = nil
            isShowingConfirmation = false
            return
        }

        if let selectedID, visibleRequirements.contains(where: { $0.id == selectedID }) {
            return
        }

        selectedID = visibleRequirements.first?.id
        editingDraft = nil
        isShowingConfirmation = false
    }

    private func toggleToolbarPanel(_ panel: OverviewToolbarPanel) {
        withAnimation(.easeInOut(duration: 0.15)) {
            expandedToolbarPanel = expandedToolbarPanel == panel ? nil : panel
        }
    }

    private func clearOverviewMetadataFilters() {
        selectedIssueType = ""
        selectedPriority = ""
        selectedTargetVersion = ""
    }

    private func matchesSelectedDateFilter(_ requirement: Requirement) -> Bool {
        let calendar = Calendar.current

        switch selectedDateFilter {
        case .all:
            return true
        case .today:
            return calendar.isDate(requirement.activityDate, inSameDayAs: Date())
        case .thisWeek:
            return calendar.isDate(requirement.activityDate, equalTo: Date(), toGranularity: .weekOfYear)
        case .thisMonth:
            return calendar.isDate(requirement.activityDate, equalTo: Date(), toGranularity: .month)
        }
    }

    private func beginEditing(_ requirement: Requirement) {
        editingDraft = OverviewDraft(requirement: requirement)
        isShowingConfirmation = false
    }

    private func cancelEditing() {
        editingDraft = nil
        isShowingConfirmation = false
    }

    private func presentConfirmationIfNeeded() {
        guard canSaveDraft else {
            return
        }

        isShowingConfirmation = true
    }

    private func commitEditing() {
        guard !mergeDraftRequiresMR else {
            isShowingConfirmation = false
            return
        }

        guard
            let selectedRequirement,
            let draft = editingDraft,
            !pendingChanges.isEmpty
        else {
            isShowingConfirmation = false
            return
        }

        if draft.isMarkedForDeletion {
            store.delete(id: selectedRequirement.id)
            selectedID = visibleRequirements.first?.id
            editingDraft = nil
            isShowingConfirmation = false
            ensureSelection()
            return
        }

        let reason = draft.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftMRURL = draft.mrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        store.update(id: selectedRequirement.id) { requirement in
            requirement.jiraURL = draft.jiraURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if draftMRURL.isEmpty {
                requirement.mrURL = nil
                requirement.normalizeMergeRequestURLs()
            } else {
                requirement.recordMergeRequestURL(draftMRURL)
            }
            requirement.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.status.apply(to: &requirement, reason: reason, now: Date())
        }

        selectedID = selectedRequirement.id
        editingDraft = nil
        isShowingConfirmation = false
    }

    private func revertChange(_ field: OverviewChange.Field) {
        guard let selectedRequirement, var draft = editingDraft else {
            return
        }

        switch field {
        case .status:
            draft.status = OverviewStatusOption(requirement: selectedRequirement)
        case .jiraURL:
            draft.jiraURL = selectedRequirement.jiraURL
        case .mrURL:
            draft.mrURL = selectedRequirement.mrURL ?? ""
        case .note:
            draft.note = selectedRequirement.note
        case .reason:
            draft.reason = selectedRequirement.pauseReason
        case .delete:
            draft.isMarkedForDeletion = false
        }

        editingDraft = draft

        if changes(for: selectedRequirement, draft: draft).isEmpty {
            isShowingConfirmation = false
        }
    }

    private func draftStringBinding(_ keyPath: WritableKeyPath<OverviewDraft, String>) -> Binding<String> {
        Binding(
            get: { editingDraft?[keyPath: keyPath] ?? "" },
            set: { editingDraft?[keyPath: keyPath] = $0 }
        )
    }

    private func changes(for requirement: Requirement, draft: OverviewDraft) -> [OverviewChange] {
        let originalStatus = OverviewStatusOption(requirement: requirement)
        var changes: [OverviewChange] = []

        if draft.isMarkedForDeletion {
            return [
                OverviewChange(
                    field: .delete,
                    title: "删除",
                    beforeText: "保留 \(requirement.jiraKey)",
                    afterText: "确认删除该需求"
                )
            ]
        }

        if draft.status != originalStatus {
            changes.append(
                OverviewChange(
                    field: .status,
                    title: "状态",
                    beforeText: originalStatus.title,
                    afterText: draft.status.title,
                    beforeStatus: originalStatus,
                    afterStatus: draft.status
                )
            )
        }

        if normalized(draft.jiraURL) != normalized(requirement.jiraURL) {
            changes.append(
                OverviewChange(
                    field: .jiraURL,
                    title: "Jira",
                    beforeText: requirement.jiraURL,
                    afterText: draft.jiraURL
                )
            )
        }

        if normalized(draft.mrURL) != normalized(requirement.mrURL ?? "") {
            changes.append(
                OverviewChange(
                    field: .mrURL,
                    title: "MR",
                    beforeText: requirement.mrURL ?? "",
                    afterText: draft.mrURL
                )
            )
        }

        if normalized(draft.note) != normalized(requirement.note) {
            changes.append(
                OverviewChange(
                    field: .note,
                    title: "备注",
                    beforeText: requirement.note,
                    afterText: draft.note
                )
            )
        }

        let shouldCompareReason = draft.status.requiresReason || originalStatus.requiresReason
        if shouldCompareReason && normalized(draft.reason) != normalized(requirement.pauseReason) {
            changes.append(
                OverviewChange(
                    field: .reason,
                    title: draft.status == .stopped ? "停止原因" : "暂停原因",
                    beforeText: requirement.pauseReason,
                    afterText: draft.reason
                )
            )
        }

        return changes
    }

    private func overviewTimelineEntries(for requirement: Requirement) -> [OverviewTimelineEntry] {
        requirement.statusHistoryNewestFirst.map {
            OverviewTimelineEntry(
                id: $0.id,
                status: OverviewStatusOption(status: $0.status),
                date: $0.date
            )
        }
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func relativeDateText(_ date: Date) -> String {
        let calendar = Calendar.current
        let formattedDate = RequirementDateDisplayFormatter.displayText(for: date, calendar: calendar)

        if calendar.isDateInToday(date) {
            return "\(formattedDate)（今天）"
        }

        if calendar.isDateInYesterday(date) {
            return "\(formattedDate)（昨天）"
        }

        return formattedDate
    }

    private func timelineDateText(_ date: Date) -> String {
        relativeDateText(date)
    }
}

private enum OverviewToolbarPanel {
    case jiraFilters
    case search
}

private enum OverviewStatusFilter: String, CaseIterable, Identifiable {
    case all
    case pending
    case active
    case done
    case tested
    case merged
    case paused
    case stopped

    var id: String { rawValue }

    static let firstRow: [OverviewStatusFilter] = [.pending, .active, .done, .tested]
    static let secondRow: [OverviewStatusFilter] = [.merged, .paused, .stopped]

    var title: String {
        switch self {
        case .all:
            "全部"
        case .pending:
            "待开发"
        case .active:
            "开发中"
        case .done:
            "开发完成"
        case .tested:
            "已自测"
        case .merged:
            "已合并"
        case .paused:
            "已暂停"
        case .stopped:
            "已停止"
        }
    }

    var timelineStatus: RequirementTimelineStatus? {
        switch self {
        case .all:
            nil
        case .pending:
            .pending
        case .active:
            .active
        case .done:
            .done
        case .tested:
            .tested
        case .merged:
            .merged
        case .paused:
            .paused
        case .stopped:
            .stopped
        }
    }

    var tint: Color {
        guard let timelineStatus else {
            return DesignColor.textPrimary
        }

        return OverviewStatusOption(status: timelineStatus).tint
    }
}

private struct OverviewStats {
    private let requirements: [Requirement]
    let total: Int

    init(requirements: [Requirement]) {
        self.requirements = requirements
        total = requirements.count
    }

    func value(for filter: OverviewStatusFilter) -> Int {
        RequirementQuery.filteredForOverview(
            requirements,
            status: filter.timelineStatus
        ).count
    }
}

private struct OverviewDraft: Equatable {
    var status: OverviewStatusOption
    var jiraURL: String
    var mrURL: String
    var note: String
    var reason: String
    var isMarkedForDeletion: Bool

    init(requirement: Requirement) {
        status = OverviewStatusOption(requirement: requirement)
        jiraURL = requirement.jiraURL
        mrURL = requirement.mrURL ?? ""
        note = requirement.note
        reason = requirement.pauseReason
        isMarkedForDeletion = false
    }
}

private enum OverviewStatusOption: String, CaseIterable, Identifiable {
    case pending
    case active
    case done
    case tested
    case merged
    case paused
    case stopped

    var id: String { rawValue }

    init(requirement: Requirement) {
        if requirement.stage == .stopped {
            self = .stopped
        } else if requirement.stage == .paused {
            self = .paused
        } else if requirement.isMerged {
            self = .merged
        } else if requirement.isTested {
            self = .tested
        } else if requirement.isDone || requirement.stage == .completed {
            self = .done
        } else if requirement.stage == .active {
            self = .active
        } else {
            self = .pending
        }
    }

    init(status: RequirementTimelineStatus) {
        switch status {
        case .pending:
            self = .pending
        case .active:
            self = .active
        case .done:
            self = .done
        case .tested:
            self = .tested
        case .merged:
            self = .merged
        case .paused:
            self = .paused
        case .stopped:
            self = .stopped
        }
    }

    var title: String {
        switch self {
        case .pending:
            "待开发"
        case .active:
            "开发中"
        case .done:
            "开发完成"
        case .tested:
            "已自测"
        case .merged:
            "已合并"
        case .paused:
            "已暂停"
        case .stopped:
            "已停止"
        }
    }

    var tint: Color {
        switch self {
        case .pending:
            DesignColor.todo
        case .active:
            DesignColor.doing
        case .done:
            DesignColor.devDone
        case .tested:
            DesignColor.tested
        case .merged:
            DesignColor.merged
        case .paused:
            DesignColor.paused
        case .stopped:
            DesignColor.stopped
        }
    }

    var systemImage: String {
        switch self {
        case .pending:
            "circle"
        case .active:
            "play.fill"
        case .done:
            "flag.checkered"
        case .tested:
            "checkmark.seal"
        case .merged:
            "arrow.triangle.merge"
        case .paused:
            "pause.fill"
        case .stopped:
            "xmark"
        }
    }

    var requiresReason: Bool {
        self == .paused || self == .stopped
    }

    func apply(to requirement: inout Requirement, reason: String, now: Date) {
        switch self {
        case .pending:
            requirement.stage = .pending
            requirement.pauseReason = ""
            requirement.isDone = false
            requirement.isTested = false
            requirement.isMerged = false
            requirement.completedAt = nil
        case .active:
            requirement.stage = .active
            requirement.pauseReason = ""
            requirement.isDone = false
            requirement.isTested = false
            requirement.isMerged = false
            requirement.completedAt = nil
        case .done:
            requirement.stage = .completed
            requirement.pauseReason = ""
            requirement.isDone = true
            requirement.isTested = false
            requirement.isMerged = false
            requirement.completedAt = requirement.completedAt ?? now
        case .tested:
            requirement.stage = .completed
            requirement.pauseReason = ""
            requirement.isDone = true
            requirement.isTested = true
            requirement.isMerged = false
            requirement.completedAt = requirement.completedAt ?? now
        case .merged:
            requirement.stage = .completed
            requirement.pauseReason = ""
            requirement.isDone = true
            requirement.isTested = true
            requirement.isMerged = true
            requirement.completedAt = requirement.completedAt ?? now
        case .paused:
            requirement.stage = .paused
            requirement.pauseReason = reason
            requirement.isMerged = false
        case .stopped:
            requirement.stage = .stopped
            requirement.pauseReason = reason
            requirement.isMerged = false
        }
    }
}

private struct OverviewChange: Identifiable {
    enum Field: Hashable {
        case status
        case jiraURL
        case mrURL
        case note
        case reason
        case delete
    }

    let field: Field
    let title: String
    let beforeText: String
    let afterText: String
    var beforeStatus: OverviewStatusOption?
    var afterStatus: OverviewStatusOption?

    var id: Field { field }
}

private struct OverviewTimelineEntry: Identifiable {
    let id: UUID
    let status: OverviewStatusOption
    let date: Date
}

private struct OverviewSplitDivider: View {
    @Binding var sidebarWidth: CGFloat
    @State private var dragStartWidth: CGFloat?
    @State private var dragStartX: CGFloat?
    @State private var isHovering = false
    @State private var isCursorPushed = false

    private let minWidth: CGFloat = 260
    private let maxWidth: CGFloat = 420

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 12)
        }
            .frame(width: 12)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        let startWidth = dragStartWidth ?? sidebarWidth
                        let startX = dragStartX ?? value.startLocation.x
                        dragStartWidth = startWidth
                        dragStartX = startX

                        var transaction = Transaction()
                        transaction.animation = nil
                        withTransaction(transaction) {
                            sidebarWidth = min(max(startWidth + value.location.x - startX, minWidth), maxWidth)
                        }
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        dragStartX = nil
                    }
            )
            .onHover { hovering in
                isHovering = hovering
                if hovering, !isCursorPushed {
                    NSCursor.resizeLeftRight.push()
                    isCursorPushed = true
                } else if !hovering, isCursorPushed {
                    NSCursor.pop()
                    isCursorPushed = false
                }
            }
            .onDisappear {
                if isCursorPushed {
                    NSCursor.pop()
                    isCursorPushed = false
                }
            }
        }
    }

private struct OverviewRequirementListRow: View {
    let index: Int
    let requirement: Requirement
    let isSelected: Bool
    @State private var isHovering = false

    private var status: OverviewStatusOption {
        OverviewStatusOption(requirement: requirement)
    }

    var body: some View {
        let title = requirement.title.trimmingCharacters(in: .whitespacesAndNewlines)

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("#\(index)")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? DesignColor.doing : Color.black.opacity(0.42))
                    .padding(.horizontal, 5)
                    .frame(height: 17)
                    .background(
                        Color.black.opacity(isSelected ? 0.06 : 0.035),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )

                Text(requirement.jiraKey)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(status.tint)
                    .lineLimit(1)
                    .textSelection(.enabled)

                Spacer(minLength: 6)

                OverviewStatusBadge(status: status)
            }

            Text(title.isEmpty ? "暂无标题" : title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.black.opacity(title.isEmpty ? 0.34 : 0.62))
                .lineLimit(1)
                .truncationMode(.tail)

            Text(summaryText)
                .font(.system(size: 10))
                .foregroundStyle(Color.black.opacity(0.45))
                .lineLimit(1)

            metadataTags
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            rowBackground,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? DesignColor.doing.opacity(0.22) : Color.clear, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        if isSelected {
            return DesignColor.doing.opacity(0.10)
        }

        if isHovering {
            return Color.black.opacity(0.045)
        }

        return .clear
    }

    private var summaryText: String {
        var parts = [summaryDateText(requirement.createdAt)]
        let detail = requirement.stage == .paused || requirement.stage == .stopped
            ? requirement.pauseReason
            : requirement.note

        if !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(detail)
        }

        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var metadataTags: some View {
        let issueType = trimmed(requirement.issueType)
        let priority = trimmed(requirement.priority)
        let version = trimmed(requirement.targetVersion)

        if issueType != nil || priority != nil || version != nil {
            HStack(spacing: 7) {
                if let issueType {
                    Text(issueType)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(overviewIssueTypeColor(for: issueType))
                }

                if let priority {
                    Text("#\(priority)")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(overviewPriorityColor(for: priority))
                }

                if let version {
                    Text("#\(version)")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(overviewVersionColor)
                }
            }
            .lineLimit(1)
        }
    }

    private func trimmed(_ value: String?) -> String? {
        let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func summaryDateText(_ date: Date) -> String {
        let calendar = Calendar.current
        let formattedDate = RequirementDateDisplayFormatter.displayText(for: date, calendar: calendar)

        if calendar.isDateInToday(date) {
            return "\(formattedDate)（今天）"
        }

        if calendar.isDateInYesterday(date) {
            return "\(formattedDate)（昨天）"
        }

        return formattedDate
    }
}

private func overviewIssueTypeColor(for value: String) -> Color {
    let normalized = value.lowercased()

    if normalized.contains("故障") || normalized.contains("bug") {
        return DesignColor.stopped
    }

    if normalized.contains("改进") || normalized.contains("improvement") {
        return DesignColor.merged
    }

    return Color.black.opacity(0.52)
}

private func overviewPriorityColor(for value: String) -> Color {
    let normalized = value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .uppercased()

    if normalized.hasPrefix("P2") {
        return DesignColor.merged
    }

    if normalized.hasPrefix("P1") {
        return DesignColor.paused
    }

    if normalized.hasPrefix("P0") {
        return DesignColor.stopped
    }

    return DesignColor.stopped
}

private let overviewVersionColor = DesignColor.doing

private struct OverviewStatTile: View {
    let filter: OverviewStatusFilter
    let value: Int
    let tint: Color
    let isSelected: Bool
    var isPrimary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isPrimary {
                    VStack(spacing: 1) {
                        Text("\(value)")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(tint)
                            .monospacedDigit()

                        Text(filter.title)
                            .font(.system(size: 9.5, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(Color.black.opacity(0.55))
                            .lineLimit(1)
                    }
                } else {
                    HStack(spacing: 3) {
                        Text(filter.title)
                            .font(.system(size: 9, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)

                        Text("\(value)")
                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(tint)
                    .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: isPrimary ? 46 : 21)
            .background(
                isPrimary
                    ? Color.black.opacity(0.03)
                    : tint.opacity(isSelected ? 0.15 : 0.07),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? (isPrimary ? DesignColor.doing : tint).opacity(0.42)
                            : Color.clear,
                        lineWidth: 1.2
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}

private struct OverviewIconButtonStyle: ButtonStyle {
    let isSelected: Bool
    var width: CGFloat = 34
    var height: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isSelected ? DesignColor.doing : Color.black.opacity(0.56))
            .frame(width: width)
            .frame(height: height)
            .background(
                (isSelected ? DesignColor.doing.opacity(0.10) : Color.black.opacity(configuration.isPressed ? 0.07 : 0.035)),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? DesignColor.doing.opacity(0.25) : Color.black.opacity(0.10), lineWidth: 0.5)
            )
    }
}

private struct OverviewMetadataFilterMenu: View {
    let title: String
    @Binding var selection: String
    let options: [String]

    var body: some View {
        Menu {
            Button {
                selection = ""
            } label: {
                Label("全部\(title)", systemImage: selection.isEmpty ? "checkmark" : "circle")
            }

            if !options.isEmpty {
                Divider()
            }

            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Label(option, systemImage: selection == option ? "checkmark" : "circle")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(selection.isEmpty ? title : selection)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(OverviewMetadataFilterButtonStyle(isSelected: !selection.isEmpty))
        .help(selection.isEmpty ? "筛选\(title)" : "\(title)：\(selection)")
        .pointingHandCursor()
    }
}

private struct OverviewMetadataFilterButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9.5, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? DesignColor.doing : Color.black.opacity(0.54))
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .background(
                isSelected
                    ? DesignColor.doing.opacity(0.10)
                    : Color.black.opacity(configuration.isPressed ? 0.07 : 0.035),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        isSelected ? DesignColor.doing.opacity(0.24) : Color.black.opacity(0.09),
                        lineWidth: 0.5
                    )
            )
    }
}

private struct OverviewListEmptyState: View {
    let isSearching: Bool

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: isSearching ? "magnifyingglass" : "tray")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.22))

            Text(isSearching ? "没有匹配结果" : "当前状态暂无需求")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.42))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct OverviewStatusBadge: View {
    let status: OverviewStatusOption

    var body: some View {
        Text(status.title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(status.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct OverviewDetailRow<Content: View>: View {
    let label: String
    var labelColor = Color.black.opacity(0.40)
    var alignment: VerticalAlignment = .center
    var labelTopPadding: CGFloat = 0
    var labelWeight: Font.Weight = .regular
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: alignment, spacing: 16) {
            Text(label)
                .font(.system(size: 11, weight: labelWeight))
                .foregroundStyle(labelColor)
                .frame(width: 72, alignment: .leading)
                .padding(.top, labelTopPadding)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 0.5)
        }
    }
}

private struct OverviewEditFieldRow<Content: View>: View {
    let label: String
    var alignment: VerticalAlignment = .center
    var labelTopPadding: CGFloat = 0
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.black.opacity(0.45))
                .frame(width: 64, alignment: .leading)
                .padding(.top, labelTopPadding)

            content()
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 0.5)
        }
    }
}

private struct OverviewLinkValue: View {
    let text: String
    var emptyText = "暂无"

    var body: some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(emptyText)
                .font(.system(size: 12))
                .italic()
                .foregroundStyle(Color.black.opacity(0.30))
        } else {
            Button {
                open(text)
            } label: {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DesignColor.doing)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pointingHandCursor()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}

private struct OverviewTextValue: View {
    let text: String
    let emptyText: String
    let isMonospaced: Bool
    var textColor: Color = Color.black.opacity(0.70)

    var body: some View {
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if isEmpty {
            Text(emptyText)
                .font(.system(size: 12, design: isMonospaced ? .monospaced : .default))
                .foregroundStyle(Color.black.opacity(0.30))
                .italic()
                .lineSpacing(2)
                .textSelection(.enabled)
        } else {
            Text(text)
                .font(.system(size: 12, design: isMonospaced ? .monospaced : .default))
                .foregroundStyle(textColor)
                .lineSpacing(2)
                .textSelection(.enabled)
        }
    }
}

private struct OverviewTextEditor: View {
    @Binding var text: String
    let height: CGFloat

    var body: some View {
        OverviewPlainTextEditor(text: $text)
            .frame(height: height)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.90), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5)
            )
    }
}

private struct OverviewPlainTextEditor: NSViewRepresentable {
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
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
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

private struct OverviewChangeCard: View {
    let change: OverviewChange
    let onRevert: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(change.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.85))

                Spacer()

                Button {
                    onRevert()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .bold))
                        Text("重置修改")
                    }
                }
                .buttonStyle(OverviewSmallSecondaryButtonStyle())
                .pointingHandCursor()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.03))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.black.opacity(0.07))
                    .frame(height: 0.5)
            }

            HStack(alignment: .top, spacing: 12) {
                changeValueBlock(title: "之前", text: change.beforeText, status: change.beforeStatus)

                Text("→")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.25))
                    .padding(.top, 24)

                changeValueBlock(title: "之后", text: change.afterText, status: change.afterStatus)
            }
            .padding(12)
        }
        .background(Color.white.opacity(0.98), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.09), lineWidth: 0.5)
        )
    }

    private func changeValueBlock(title: String, text: String, status: OverviewStatusOption?) -> some View {
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Color.black.opacity(0.45))

            if let status {
                OverviewStatusBadge(status: status)
                    .padding(.vertical, 4)
            } else {
                Text(isEmpty ? "无数据" : text)
                    .font(.system(size: 11))
                    .foregroundStyle(isEmpty ? Color.black.opacity(0.28) : Color.black.opacity(0.65))
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OverviewEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.22))

            Text("暂无需求")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OverviewPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint = DesignColor.doing

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(
                tint.opacity(configuration.isPressed ? 0.78 : 1),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .pointingHandCursor(isEnabled)
    }
}

private struct OverviewSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.65))
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(
                Color.black.opacity(configuration.isPressed ? 0.07 : 0.03),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
            )
            .pointingHandCursor(isEnabled)
    }
}

private struct OverviewSmallSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.60))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                Color.black.opacity(configuration.isPressed ? 0.07 : 0.03),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
            )
            .pointingHandCursor(isEnabled)
    }
}

private struct OverviewSearchResetButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.58))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                Color.black.opacity(configuration.isPressed ? 0.07 : 0.035),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
            )
            .pointingHandCursor(isEnabled)
    }
}

private struct OverviewDestructiveSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let isMarked: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(isMarked ? Color.black.opacity(0.62) : DesignColor.stopped)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                (isMarked ? Color.black.opacity(0.035) : DesignColor.stopped.opacity(0.08))
                    .opacity(configuration.isPressed ? 0.80 : 1),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isMarked ? Color.black.opacity(0.12) : DesignColor.stopped.opacity(0.24), lineWidth: 0.5)
            )
            .pointingHandCursor(isEnabled)
    }
}

private struct OverviewStatusOptionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let status: OverviewStatusOption
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(status.tint)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(
                status.tint.opacity(configuration.isPressed ? 0.19 : 0.13),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? status.tint : Color.clear, lineWidth: 1.5)
            )
            .pointingHandCursor(isEnabled)
    }
}

private extension RequirementDateFilter {
    var overviewTitle: String {
        switch self {
        case .all:
            "全部"
        case .today:
            "今天"
        case .thisWeek:
            "本周"
        case .thisMonth:
            "本月"
        }
    }
}

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var foldedForSearch: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_CN"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Array where Element == OverviewTimelineEntry {
    func removingAdjacentDuplicateStatuses() -> [OverviewTimelineEntry] {
        var result: [OverviewTimelineEntry] = []

        for entry in self where result.last?.status != entry.status {
            result.append(entry)
        }

        return result
    }
}
