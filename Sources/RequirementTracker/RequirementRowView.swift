import AppKit
import RequirementCore
import SwiftUI

struct RequirementRowView: View {
    @EnvironmentObject private var store: RequirementStore
    @State private var isCopied = false
    @State private var isHoveringCard = false
    @State private var isHoveringTitle = false
    @State private var isHoveringMR = false
    @State private var editorMode: RowEditorMode?
    @State private var draftNote = ""
    @State private var draftMR = ""
    @State private var draftReason = ""
    @State private var advancesAfterMRSave = false
    @State private var requiresMRBeforeSave = false

    let requirement: Requirement
    let isExpanded: Bool
    let onToggleExpanded: () -> Void

    private var style: RequirementDisplayStyle {
        RequirementDisplayStyle(requirement: requirement)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            topLine

            if editorMode == .note {
                noteEditor
            } else if editorMode == .completionNote {
                completionNoteEditor
            } else {
                Text(requirement.title.isEmpty ? "暂无标题" : requirement.title)
                    .font(.system(size: 11))
                    .foregroundStyle(requirement.title.isEmpty ? Color.black.opacity(0.24) : Color.black.opacity(0.74))
                    .lineLimit(2)
                    .frame(minHeight: 15, alignment: .leading)

                if !requirement.note.isEmpty {
                    Text(requirement.note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.black.opacity(0.56))
                        .lineLimit(2)
                }

                metadataTags
            }

            if editorMode == .mr {
                mrEditor
            }

            if case .pauseReason = editorMode {
                reasonEditor
            } else if !requirement.pauseReason.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(requirement.pauseReason)
                        .lineLimit(2)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(DesignColor.paused)
            }

            bottomLine

            if isExpanded && editorMode == nil {
                timelineView
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                        )
                    )
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 11)
        .padding(.bottom, 7)
        .clipped()
        .background(Color(hex: 0xFAFAFA, opacity: isExpanded ? 0.96 : 0.92), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(isHoveringCard ? 0.018 : 0))
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.black.opacity(0.09), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .shadow(color: Color.black.opacity(0.07), radius: 4, y: 1)
        .padding(.vertical, 4)
        .onHover { isHoveringCard = $0 }
        .animation(.easeOut(duration: 0.12), value: isHoveringCard)
    }

    private var topLine: some View {
        HStack(alignment: .center, spacing: 4) {
            if let issueTypeText {
                let issueTypeTint = issueTypeColor(for: issueTypeText)
                Text(issueTypeText)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(issueTypeTint)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(height: 16)
                    .background(issueTypeTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            }

            Button {
                store.openJira(for: requirement.id)
            } label: {
                HStack(spacing: 3) {
                    jiraKeyText
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .lineLimit(1)

                    if isHoveringCard || isHoveringTitle {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(style.color)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("打开 Jira")
            .onHover { isHoveringTitle = $0 }
            .pointingHandCursor()

            if let mrIdentifier = RequirementParser.mrIdentifier(from: requirement.mrURL) {
                Button {
                    store.openMR(for: requirement.id)
                } label: {
                    HStack(spacing: 3) {
                        Text(mrIdentifier)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))

                        if isHoveringCard || isHoveringMR {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 7, weight: .bold))
                        }
                    }
                    .foregroundStyle(DesignColor.doing)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(DesignColor.doing.opacity(0.09), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("打开 MR")
                .onHover { isHoveringMR = $0 }
                .pointingHandCursor()
            }

            Spacer(minLength: 4)

            Button {
                guard !isCopied else {
                    return
                }

                store.copyCombined(for: requirement.id, notify: false)
                isCopied = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    isCopied = false
                }
            } label: {
                CopyGlyph(isCopied: isCopied, tint: isCopied ? style.color : Color.black.opacity(0.25))
            }
            .buttonStyle(RowPlainIconButtonStyle(tint: isCopied ? style.color : Color.black.opacity(0.25)))
            .allowsHitTesting(!isCopied)
            .help("复制 Jira 与 MR 地址")
            .pointingHandCursor()

            rowMenu
        }
    }

    @ViewBuilder
    private var metadataTags: some View {
        let priorityText = trimmed(requirement.priority)
        let versionText = trimmed(requirement.targetVersion)

        if priorityText != nil || versionText != nil {
            HStack(spacing: 7) {
                if let priorityText {
                    Text("#\(priorityText)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(priorityColor(for: priorityText))
                        .lineLimit(1)
                }

                if let versionText {
                    Text("#\(versionText)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DesignColor.doing)
                        .lineLimit(1)
                }
            }
        }
    }

    private var issueTypeText: String? {
        trimmed(requirement.issueType)
    }

    private func issueTypeColor(for value: String) -> Color {
        let normalized = value.lowercased()

        if normalized.contains("故障") || normalized.contains("bug") {
            return DesignColor.stopped
        }

        if normalized.contains("改进") || normalized.contains("improvement") {
            return DesignColor.merged
        }

        return Color.black.opacity(0.58)
    }

    private func priorityColor(for value: String) -> Color {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        if normalized.hasPrefix("P0") {
            return DesignColor.stopped
        }

        if normalized.hasPrefix("P1") {
            return DesignColor.paused
        }

        if normalized.hasPrefix("P2") {
            return DesignColor.merged
        }

        return DesignColor.stopped
    }

    private func trimmed(_ value: String?) -> String? {
        let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private var bottomLine: some View {
        HStack(spacing: 5) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.26))
                .frame(width: 9, height: 8)

            statusIcon

            Text(style.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(style.color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Text("· \(relativeDateText(requirement.activityDate))")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.black.opacity(0.30))
                .lineLimit(1)
                .layoutPriority(2)

            Spacer()

            if let action = style.advanceAction {
                Button {
                    performAdvanceAction()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 8, weight: .semibold))
                        Text(action.title)
                    }
                }
                .buttonStyle(ActionPillButtonStyle(tint: action.color))
                .help(action.title)
                .pointingHandCursor()
                .layoutPriority(3)
                .fixedSize(horizontal: true, vertical: false)
            } else if style.showsTerminalCheck {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(style.color)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onToggleExpanded()
        }
        .pointingHandCursor()
    }

    private var rowMenu: some View {
        NativeIconMenuButton(
            kind: .more,
            contents: rowMenuContents,
            size: CGSize(width: 18, height: 18),
            tintAlpha: 0.35,
            help: "更多操作"
        )
        .frame(width: 18, height: 18)
    }

    private var canPause: Bool {
        !requirement.isMerged
            && requirement.stage != .paused
            && requirement.stage != .stopped
    }

    private var canStop: Bool {
        !requirement.isMerged
            && requirement.stage != .stopped
    }

    private var rowMenuContents: [NativeMenuContent] {
        var contents: [NativeMenuContent] = [
            .item(
                NativeMenuItemDescriptor(
                    title: requirement.note.isEmpty ? "添加备注" : "编辑备注",
                    systemImage: "square.and.pencil"
                ) {
                    beginEditing(.note)
                }
            ),
            .item(
                NativeMenuItemDescriptor(
                    title: requirement.mrURL?.isEmpty == false ? "编辑 MR" : "添加 MR",
                    systemImage: "link"
                ) {
                    beginMREditing(advanceAfterSave: false)
                }
            )
        ]

        if requirement.canMarkMergedDirectly {
            contents.append(
                .item(
                    NativeMenuItemDescriptor(title: "一键标为已完成", systemImage: "checkmark.seal") {
                        if requirement.hasMergeRequestURL {
                            store.markCompleted(id: requirement.id)
                        } else {
                            beginCompletionNoteEditing()
                        }
                    }
                )
            )
        }

        if canPause || canStop {
            contents.append(.separator())

            if canPause {
                contents.append(
                    .item(
                        NativeMenuItemDescriptor(title: "暂停开发", systemImage: "pause") {
                            beginReasonEditing(.paused)
                        }
                    )
                )
            }

            if canStop {
                contents.append(
                    .item(
                        NativeMenuItemDescriptor(title: "停止需求", systemImage: "xmark.circle") {
                            beginReasonEditing(.stopped)
                        }
                    )
                )
            }
        }

        if requirement.stage == .paused || requirement.stage == .stopped {
            contents.append(.separator())
            contents.append(
                .item(
                    NativeMenuItemDescriptor(
                        title: requirement.stage == .paused ? "编辑暂停原因" : "编辑停止原因",
                        systemImage: "exclamationmark.bubble"
                    ) {
                        beginReasonEditing(requirement.stage)
                    }
                )
            )
        }

        return contents
    }

    private var timelineView: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(timelineEntries) { entry in
                HStack(spacing: 12) {
                    TimelineDot(color: entry.color, systemImage: entry.systemImage)
                        .frame(width: 9)

                    Text(entry.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(DesignColor.textPrimary)
                        .frame(width: 58, alignment: .leading)

                    Text(timelineDateText(entry.date))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.black.opacity(0.38))

                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.top, 3)
    }

    private var noteEditor: some View {
        editPanel(title: "备注", placeholder: "补充说明...", text: $draftNote, isMultiline: true) {
            store.update(id: requirement.id) { requirement in
                requirement.note = draftNote
            }
            closeEditor()
        }
        .padding(.top, 1)
    }

    private var completionNoteEditor: some View {
        let canSave = !draftNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return editPanel(
            title: "完成备注",
            placeholder: "说明无需解决或完成原因...",
            text: $draftNote,
            isMultiline: true,
            canSave: canSave,
            saveTitle: "完成"
        ) {
            let note = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !note.isEmpty else {
                return
            }

            store.markMerged(id: requirement.id, note: note)
            closeEditor()
        }
        .padding(.top, 1)
    }

    private var mrEditor: some View {
        let canSave = !requiresMRBeforeSave || !draftMR.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return editPanel(
            title: "MR 地址",
            placeholder: "粘贴 MR / 合并请求链接...",
            text: $draftMR,
            canSave: canSave
        ) {
            store.update(id: requirement.id) { requirement in
                requirement.mrURL = draftMR
            }

            if advancesAfterMRSave {
                store.advance(id: requirement.id)
            }

            closeEditor()
        }
        .padding(.top, 1)
    }

    private var reasonEditor: some View {
        let targetStage = reasonEditingStage ?? .paused
        let title = targetStage == .stopped ? "停止原因" : "暂停原因"
        let placeholder = targetStage == .stopped ? "说明停止原因..." : "说明暂停原因..."
        let canSave = !draftReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return editPanel(
            title: title,
            placeholder: placeholder,
            text: $draftReason,
            isMultiline: true,
            canSave: canSave
        ) {
            let reason = draftReason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty else {
                return
            }

            store.update(id: requirement.id) { requirement in
                requirement.stage = targetStage
                requirement.pauseReason = reason
                requirement.isMerged = false
            }
            closeEditor()
        }
        .padding(.top, 1)
    }

    private func editPanel(
        title: String,
        placeholder: String,
        text: Binding<String>,
        isMultiline: Bool = false,
        canSave: Bool = true,
        saveTitle: String = "保存",
        onSave: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.55))

            if isMultiline {
                ZStack(alignment: .topLeading) {
                    MultilineRowEditor(text: text)
                        .frame(height: 48)

                    if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(placeholder)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.black.opacity(0.38))
                            .allowsHitTesting(false)
                    }
                }
                .padding(7)
                .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                )
            } else {
                TextField(placeholder, text: text)
                    .font(.system(size: 11))
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 6) {
                Spacer()

                Button("取消") {
                    closeEditor()
                }
                .buttonStyle(InlineCancelButtonStyle())
                .pointingHandCursor()

                Button(saveTitle) {
                    onSave()
                }
                .buttonStyle(InlineSaveButtonStyle())
                .disabled(!canSave)
                .pointingHandCursor(canSave)
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var timelineEntries: [TimelineEntry] {
        requirement.statusHistory.reversed().map { timelineEntry(for: $0) }
    }

    private func beginEditing(_ mode: RowEditorMode) {
        draftNote = requirement.note
        draftMR = requirement.mrURL ?? ""
        advancesAfterMRSave = false
        requiresMRBeforeSave = false
        editorMode = mode
    }

    private func beginMREditing(advanceAfterSave: Bool, requiresValue: Bool = false) {
        draftNote = requirement.note
        draftMR = requirement.mrURL ?? ""
        advancesAfterMRSave = advanceAfterSave
        requiresMRBeforeSave = requiresValue
        editorMode = .mr
    }

    private func beginCompletionNoteEditing() {
        draftNote = requirement.note
        draftMR = requirement.mrURL ?? ""
        advancesAfterMRSave = false
        requiresMRBeforeSave = false
        editorMode = .completionNote
    }

    private func beginReasonEditing(_ stage: RequirementStage) {
        draftReason = requirement.pauseReason
        advancesAfterMRSave = false
        requiresMRBeforeSave = false
        editorMode = .pauseReason(stage)
    }

    private func closeEditor() {
        editorMode = nil
        advancesAfterMRSave = false
        requiresMRBeforeSave = false
    }

    private var reasonEditingStage: RequirementStage? {
        if case let .pauseReason(stage) = editorMode {
            return stage
        }

        return nil
    }

    private func performAdvanceAction() {
        if shouldPromptMRBeforeMerging {
            beginMREditing(advanceAfterSave: true, requiresValue: true)
            return
        }

        store.advance(id: requirement.id)
    }

    private var shouldPromptMRBeforeMerging: Bool {
        !requirement.isMerged
            && requirement.isTested
            && !requirement.hasMergeRequestURL
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch style.icon {
        case .emptyCircle:
            Circle()
                .stroke(style.color, lineWidth: 1.4)
                .frame(width: 8, height: 8)
        case .filledCircle:
            Circle()
                .fill(style.color)
                .frame(width: 8, height: 8)
        case .check:
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(style.color)
                .frame(width: 8, height: 8)
        case .pause:
            Image(systemName: "pause.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(style.color)
                .frame(width: 8, height: 8)
        case .xmark:
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(style.color)
                .frame(width: 8, height: 8)
        }
    }

    private var jiraKeyText: Text {
        let parts = requirement.jiraKey.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return Text(requirement.jiraKey)
                .foregroundColor(style.color)
        }

        return Text("\(parts[0])-")
            .foregroundColor(style.color)
        + Text(parts[1])
            .foregroundColor(style.color)
            .bold()
    }

    private func relativeDateText(_ date: Date) -> String {
        let calendar = Calendar.current
        let formattedDate = RequirementDateDisplayFormatter.dayDisplayText(for: date, calendar: calendar)

        if calendar.isDateInToday(date) {
            return "\(formattedDate)（今天）"
        }

        if calendar.isDateInYesterday(date) {
            return "\(formattedDate)（昨天）"
        }

        return formattedDate
    }

    private func timelineDateText(_ date: Date) -> String {
        RequirementDateDisplayFormatter.shortDisplayText(for: date)
    }

    private func timelineEntry(for event: RequirementStatusEvent) -> TimelineEntry {
        let presentation = TimelineStatusPresentation(status: event.status)
        return TimelineEntry(
            id: event.id,
            title: presentation.title,
            date: event.date,
            color: presentation.color,
            systemImage: presentation.systemImage
        )
    }
}

private enum RowEditorMode: Equatable {
    case note
    case completionNote
    case mr
    case pauseReason(RequirementStage)
}

private struct TimelineEntry: Identifiable {
    let id: UUID
    let title: String
    let date: Date
    let color: Color
    let systemImage: String
}

private struct TimelineDot: View {
    let color: Color
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 12, height: 10)
    }
}

private struct TimelineStatusPresentation {
    let title: String
    let color: Color
    let systemImage: String

    init(status: RequirementTimelineStatus) {
        switch status {
        case .pending:
            title = "待开发"
            color = DesignColor.todo
            systemImage = "circle"
        case .active:
            title = "开发中"
            color = DesignColor.doing
            systemImage = "play.fill"
        case .done:
            title = "开发完成"
            color = DesignColor.devDone
            systemImage = "flag.checkered"
        case .tested:
            title = "已自测"
            color = DesignColor.tested
            systemImage = "checkmark.seal"
        case .merged:
            title = "已合并"
            color = DesignColor.merged
            systemImage = "arrow.triangle.merge"
        case .paused:
            title = "已暂停"
            color = DesignColor.paused
            systemImage = "pause.fill"
        case .stopped:
            title = "已停止"
            color = DesignColor.stopped
            systemImage = "xmark"
        }
    }
}

private struct MultilineRowEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: 11)
        textView.textColor = .labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
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

private struct RequirementInlineEditor: View {
    @EnvironmentObject private var store: RequirementStore

    let requirementID: Requirement.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("阶段", selection: stageBinding) {
                ForEach(RequirementStage.allCases) { stage in
                    Text(stage.shortTitle).tag(stage)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 14) {
                Toggle("已完成", isOn: boolBinding(\.isDone))
                Toggle("已自测", isOn: boolBinding(\.isTested))
                Toggle("已合并", isOn: boolBinding(\.isMerged))
            }
            .toggleStyle(.checkbox)

            TextField("Jira 地址", text: stringBinding(\.jiraURL))
                .textFieldStyle(.roundedBorder)

            TextField("MR 地址（完成后可选）", text: mrURLBinding)
                .textFieldStyle(.roundedBorder)

            TextField("需求标题", text: stringBinding(\.title))
                .textFieldStyle(.roundedBorder)

            TextField("需求备注", text: stringBinding(\.note))
                .textFieldStyle(.roundedBorder)

            TextField("异常原因", text: stringBinding(\.pauseReason))
                .textFieldStyle(.roundedBorder)
        }
    }

    private var stageBinding: Binding<RequirementStage> {
        Binding(
            get: { store.requirement(id: requirementID)?.stage ?? .pending },
            set: { store.setStage(id: requirementID, stage: $0) }
        )
    }

    private var mrURLBinding: Binding<String> {
        Binding(
            get: { store.requirement(id: requirementID)?.mrURL ?? "" },
            set: { newValue in
                store.update(id: requirementID) { requirement in
                    requirement.mrURL = newValue
                }
            }
        )
    }

    private func stringBinding(_ keyPath: WritableKeyPath<Requirement, String>) -> Binding<String> {
        Binding(
            get: { store.requirement(id: requirementID)?[keyPath: keyPath] ?? "" },
            set: { newValue in
                store.update(id: requirementID) { requirement in
                    requirement[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func boolBinding(_ keyPath: WritableKeyPath<Requirement, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.requirement(id: requirementID)?[keyPath: keyPath] ?? false },
            set: { newValue in
                store.update(id: requirementID) { requirement in
                    requirement[keyPath: keyPath] = newValue
                }
            }
        )
    }
}

private struct RowPlainIconButtonStyle: ButtonStyle {
    var tint = Color.black.opacity(0.25)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(configuration.isPressed ? tint.opacity(0.70) : tint)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
    }
}

private struct CopyGlyph: View {
    let isCopied: Bool
    let tint: Color

    var body: some View {
        ZStack(alignment: .center) {
            if isCopied {
                Image(systemName: "checkmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(tint)
            } else {
                CopySheetsShape()
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: 13, height: 13)
            }
        }
        .frame(width: 14, height: 14)
    }
}

private struct CopySheetsShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let origin = CGPoint(
            x: rect.midX - 12 * scale,
            y: rect.midY - 12 * scale
        )

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }

        func scaledRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
            CGRect(
                x: origin.x + x * scale,
                y: origin.y + y * scale,
                width: width * scale,
                height: height * scale
            )
        }

        var path = Path()
        path.addRoundedRect(
            in: scaledRect(x: 9, y: 9, width: 11, height: 11),
            cornerSize: CGSize(width: 2.5 * scale, height: 2.5 * scale)
        )
        path.move(to: point(6, 15))
        path.addLine(to: point(5, 15))
        path.addCurve(
            to: point(3, 13),
            control1: point(4, 15),
            control2: point(3, 14)
        )
        path.addLine(to: point(3, 5))
        path.addCurve(
            to: point(5, 3),
            control1: point(3, 4),
            control2: point(4, 3)
        )
        path.addLine(to: point(13, 3))
        path.addCurve(
            to: point(15, 5),
            control1: point(14, 3),
            control2: point(15, 4)
        )
        path.addLine(to: point(15, 6))
        return path
    }
}

private struct InlineCancelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.62))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                Color.black.opacity(configuration.isPressed ? 0.09 : 0.04),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
    }
}

private struct InlineSaveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                DesignColor.doing.opacity(configuration.isPressed ? 0.78 : 1),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
    }
}

private struct ActionPillButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minWidth: 42, minHeight: 24)
            .background(
                tint.opacity(configuration.isPressed ? 0.18 : 0.10),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .pointingHandCursor()
    }
}

private enum RequirementStatusGlyph {
    case emptyCircle
    case filledCircle
    case check
    case pause
    case xmark
}

private struct RequirementAdvanceAction {
    let title: String
    let color: Color
    let systemImage: String
}

private struct RequirementDisplayStyle {
    let title: String
    let color: Color
    let icon: RequirementStatusGlyph
    let advanceAction: RequirementAdvanceAction?
    let showsTerminalCheck: Bool

    init(requirement: Requirement) {
        if requirement.stage == .stopped {
            title = "已停止"
            color = DesignColor.stopped
            icon = .xmark
            advanceAction = nil
            showsTerminalCheck = false
            return
        }

        if requirement.stage == .paused {
            title = "已暂停"
            color = DesignColor.paused
            icon = .pause
            advanceAction = RequirementAdvanceAction(title: "继续", color: DesignColor.paused, systemImage: "arrow.clockwise")
            showsTerminalCheck = false
            return
        }

        if requirement.isMerged {
            title = "已合并"
            color = DesignColor.merged
            icon = .check
            advanceAction = nil
            showsTerminalCheck = false
            return
        }

        if requirement.isTested {
            title = "已自测"
            color = DesignColor.tested
            icon = .check
            advanceAction = RequirementAdvanceAction(title: "合并", color: DesignColor.merged, systemImage: "arrow.triangle.merge")
            showsTerminalCheck = false
            return
        }

        if requirement.isDone || requirement.stage == .completed {
            title = "开发完成"
            color = DesignColor.devDone
            icon = .check
            advanceAction = RequirementAdvanceAction(title: "测试", color: DesignColor.tested, systemImage: "checkmark.seal")
            showsTerminalCheck = false
            return
        }

        switch requirement.stage {
        case .pending:
            title = "待开发"
            color = DesignColor.todo
            icon = .emptyCircle
            advanceAction = RequirementAdvanceAction(title: "开始", color: DesignColor.doing, systemImage: "play.fill")
            showsTerminalCheck = false
        case .active:
            title = "开发中"
            color = DesignColor.doing
            icon = .filledCircle
            advanceAction = RequirementAdvanceAction(title: "完成", color: DesignColor.devDone, systemImage: "flag.checkered")
            showsTerminalCheck = false
        case .paused:
            title = "已暂停"
            color = DesignColor.paused
            icon = .pause
            advanceAction = RequirementAdvanceAction(title: "继续", color: DesignColor.paused, systemImage: "arrow.clockwise")
            showsTerminalCheck = false
        case .stopped:
            title = "已停止"
            color = DesignColor.stopped
            icon = .xmark
            advanceAction = nil
            showsTerminalCheck = false
        case .completed:
            title = "开发完成"
            color = DesignColor.devDone
            icon = .check
            advanceAction = RequirementAdvanceAction(title: "测试", color: DesignColor.tested, systemImage: "checkmark.seal")
            showsTerminalCheck = false
        }
    }
}

private extension Array where Element == TimelineEntry {
    func removingAdjacentDuplicates() -> [TimelineEntry] {
        var result: [TimelineEntry] = []

        for entry in self where result.last?.title != entry.title {
            result.append(entry)
        }

        return result
    }
}
