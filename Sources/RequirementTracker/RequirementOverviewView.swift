import AppKit
import RequirementCore
import SwiftUI

private let overviewTopHeaderHeight: CGFloat = 60

struct RequirementOverviewView: View {
    @EnvironmentObject private var store: RequirementStore

    @State private var selectedID: Requirement.ID?
    @State private var selectedFilter: OverviewStatusFilter = .all
    @State private var searchText = ""
    @State private var editingDraft: OverviewDraft?
    @State private var isShowingConfirmation = false
    @State private var sidebarWidth: CGFloat = 330

    private var sortedRequirements: [Requirement] {
        store.requirements.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }

            if lhs.activityDate != rhs.activityDate {
                return lhs.activityDate > rhs.activityDate
            }

            return lhs.jiraKey < rhs.jiraKey
        }
    }

    private var statusFilteredRequirements: [Requirement] {
        sortedRequirements.filter { selectedFilter.matches($0) }
    }

    private var visibleRequirements: [Requirement] {
        let query = normalized(searchText)
        guard !query.isEmpty else {
            return statusFilteredRequirements
        }

        let queryParts = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return statusFilteredRequirements.filter { requirement in
            let searchableText = [
                requirement.jiraURL,
                requirement.mrURL ?? "",
                requirement.note,
                requirement.pauseReason
            ]
            .joined(separator: " ")
            .foldedForSearch

            return queryParts.allSatisfy { searchableText.contains($0.foldedForSearch) }
        }
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

        return !pendingChanges.isEmpty
    }

    private var isConfirmingDeletion: Bool {
        pendingChanges.contains { $0.field == .delete }
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
        .onChange(of: searchText) { _ in
            ensureSelection()
        }
        .animation(.snappy(duration: 0.16), value: isShowingConfirmation)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            statsGrid

            searchBar

            ScrollView {
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
            .scrollIndicators(.automatic)
        }
        .background(Color.white.opacity(0.24))
    }

    private var statsGrid: some View {
        let stats = OverviewStats(requirements: store.requirements)

        return HStack(spacing: 8) {
            OverviewStatTile(
                filter: .all,
                value: stats.total,
                tint: DesignColor.textPrimary,
                isSelected: selectedFilter == .all,
                isPrimary: true
            ) {
                selectedFilter = .all
            }

            OverviewStatTile(
                filter: .active,
                value: stats.active,
                tint: DesignColor.doing,
                isSelected: selectedFilter == .active
            ) {
                selectedFilter = .active
            }

            OverviewStatTile(
                filter: .completed,
                value: stats.completed,
                tint: DesignColor.merged,
                isSelected: selectedFilter == .completed
            ) {
                selectedFilter = .completed
            }

            OverviewStatTile(
                filter: .exceptional,
                value: stats.exceptional,
                tint: DesignColor.stopped,
                isSelected: selectedFilter == .exceptional
            ) {
                selectedFilter = .exceptional
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

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.35))

                TextField("搜索 Jira / MR / 备注 / 原因", text: $searchText)
                    .font(.system(size: 11.5))
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
            )

            Button {
                searchText = ""
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .bold))
                    Text("重置")
                }
            }
            .buttonStyle(OverviewSearchResetButtonStyle())
            .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            .pointingHandCursor(!searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 0.5)
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

            ScrollView {
                VStack(spacing: 0) {
                    OverviewDetailRow(label: "状态") {
                        OverviewStatusBadge(status: OverviewStatusOption(requirement: requirement))
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

                    OverviewDetailRow(label: "MR") {
                        OverviewLinkValue(text: requirement.mrURL ?? "", emptyText: "暂无")
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
        }
    }

    private func editPanel(for requirement: Requirement) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(requirement.jiraKey)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(OverviewStatusOption(requirement: requirement).tint)

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

            ScrollView {
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
                                    Text(option.title)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
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
                        TextField("MR 地址", text: draftStringBinding(\.mrURL))
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
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

                ScrollView {
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
        store.update(id: selectedRequirement.id) { requirement in
            requirement.jiraURL = draft.jiraURL.trimmingCharacters(in: .whitespacesAndNewlines)
            requirement.mrURL = draft.mrURL.trimmingCharacters(in: .whitespacesAndNewlines)
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
        var entries: [OverviewTimelineEntry] = [
            OverviewTimelineEntry(
                status: OverviewStatusOption(requirement: requirement),
                date: requirement.activityDate
            )
        ]

        if requirement.isTested || requirement.isMerged {
            entries.append(OverviewTimelineEntry(status: .tested, date: requirement.updatedAt))
        }

        if requirement.isDone || requirement.isTested || requirement.isMerged {
            entries.append(OverviewTimelineEntry(status: .done, date: requirement.completedAt ?? requirement.updatedAt))
        }

        if requirement.stage == .active || requirement.isDone {
            entries.append(OverviewTimelineEntry(status: .active, date: requirement.createdAt))
        }

        if requirement.stage != .pending {
            entries.append(OverviewTimelineEntry(status: .pending, date: requirement.createdAt))
        }

        return entries.removingAdjacentDuplicateStatuses()
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func relativeDateText(_ date: Date) -> String {
        let calendar = Calendar.current
        let formattedDate = formattedDateText(date)

        if calendar.isDateInToday(date) {
            return "\(formattedDate)（今天）"
        }

        if calendar.isDateInYesterday(date) {
            return "\(formattedDate)（昨天）"
        }

        return formattedDate
    }

    private func formattedDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    private func timelineDateText(_ date: Date) -> String {
        relativeDateText(date)
    }
}

private enum OverviewStatusFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case completed
    case exceptional

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            "全部"
        case .active:
            "开发中"
        case .completed:
            "已完成"
        case .exceptional:
            "异常"
        }
    }

    func matches(_ requirement: Requirement) -> Bool {
        let status = OverviewStatusOption(requirement: requirement)

        switch self {
        case .all:
            return true
        case .active:
            return status == .active
        case .completed:
            return [.done, .tested, .merged].contains(status)
        case .exceptional:
            return [.paused, .stopped].contains(status)
        }
    }
}

private struct OverviewStats {
    let total: Int
    let active: Int
    let completed: Int
    let exceptional: Int

    init(requirements: [Requirement]) {
        total = requirements.count
        active = requirements.filter { OverviewStatusOption(requirement: $0) == .active }.count
        completed = requirements.filter {
            [.done, .tested, .merged].contains(OverviewStatusOption(requirement: $0))
        }.count
        exceptional = requirements.filter {
            [.paused, .stopped].contains(OverviewStatusOption(requirement: $0))
        }.count
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

    var title: String {
        switch self {
        case .pending:
            "待开发"
        case .active:
            "开发中"
        case .done:
            "开发完成"
        case .tested:
            "已测试"
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
            "circle.fill"
        case .done, .tested, .merged:
            "checkmark"
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
    let id = UUID()
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

                Spacer(minLength: 6)

                OverviewStatusBadge(status: status)
            }

            Text(summaryText)
                .font(.system(size: 10))
                .foregroundStyle(Color.black.opacity(0.45))
                .lineLimit(1)
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

    private func summaryDateText(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        let formattedDate = formatter.string(from: date)

        if calendar.isDateInToday(date) {
            return "\(formattedDate)（今天）"
        }

        if calendar.isDateInYesterday(date) {
            return "\(formattedDate)（昨天）"
        }

        return formattedDate
    }
}

private struct OverviewStatTile: View {
    let filter: OverviewStatusFilter
    let value: Int
    let tint: Color
    let isSelected: Bool
    var isPrimary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text("\(value)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(tint)

                Text(filter.title)
                    .font(.system(size: 9.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isPrimary ? Color.black.opacity(0.55) : tint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(
                (isPrimary ? Color.black.opacity(0.03) : tint.opacity(0.07)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? DesignColor.doing.opacity(0.35) : Color.clear, lineWidth: 1.2)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
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
                .foregroundStyle(Color.black.opacity(0.70))
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
