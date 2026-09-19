import AppKit
import RequirementCore
import SwiftUI

struct RequirementSettingsView: View {
    @EnvironmentObject private var settingsStore: RequirementSettingsStore
    @State private var selectedTab: RequirementSettingsTab = .base
    @State private var selectedSortFilter: RequirementStatusFilter = .incomplete
    @State private var selectedProjectID: RequirementScriptProject.ID?
    @State private var showsGlobalCommands = true
    @State private var selectedGlobalCommand: DeveloperCommand = .zsStart
    @State private var pluginAlertMessage = ""
    @State private var isInstallingNativeHost = false
    @State private var nativeHostStatus: RequirementNativeHostStatus?
    @StateObject private var calendarAccessManager = CalendarAccessManager()

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: Binding<RequirementSettingsTab?>(
                get: { selectedTab },
                set: { if let tab = $0 { selectedTab = tab } }
            )) {
                Section("设置") {
                    ForEach(RequirementSettingsTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.systemImage)
                            .padding(.vertical, 6)
                            .tag(tab)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(selectedTab.title)
                            .font(.system(size: 24, weight: .bold))
                        Text(selectedTab.subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 2)

                    Group {
                        switch selectedTab {
                        case .base: baseConfigurationView
                        case .plugin: pluginConfigurationView
                        case .scripts: scriptConfigurationView
                        case .quickLinks: quickLinksView
                        }
                    }
                }
                .frame(maxWidth: 800, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .navigationTitle("设置")
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(.hidden, for: .windowToolbar)
        .frame(minWidth: 960, idealWidth: 1040, minHeight: 640, idealHeight: 700)
        .onAppear {
            ensureProjectSelection()
            calendarAccessManager.refresh()
        }
        .onChange(of: settingsStore.configuration.scriptProjects.map(\.id)) { _ in
            ensureProjectSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            calendarAccessManager.refresh()
        }
        .alert("插件配置", isPresented: Binding(
            get: { !pluginAlertMessage.isEmpty },
            set: { isPresented in
                if !isPresented {
                    pluginAlertMessage = ""
                }
            }
        )) {
            Button("好") {
                pluginAlertMessage = ""
            }
        } message: {
            Text(pluginAlertMessage)
        }
    }

    private var baseConfigurationView: some View {
        let rules = settingsStore.tabSortRules(for: selectedSortFilter)
        let isDefault = rules == RequirementTabSortConfiguration.defaultRules(for: selectedSortFilter)

        return VStack(alignment: .leading, spacing: 20) {
            SettingsContentCard("外观") {
                SettingsFieldRow("弹窗样式") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("弹窗样式", selection: Binding(
                            get: { settingsStore.panelStyle },
                            set: { settingsStore.setPanelStyle($0) }
                        )) {
                            ForEach(RequirementPanelStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 380)
                        Text(settingsStore.panelStyle.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            SettingsContentCard("系统日历") {
                SettingsFieldRow("访问权限") {
                    HStack(spacing: 12) {
                        Label(calendarAccessManager.statusTitle, systemImage: calendarAccessManager.statusSystemImage)
                            .foregroundStyle(calendarAccessTint)
                        Spacer(minLength: 12)
                        Button(calendarAccessManager.isRequesting ? "请求中…" : calendarAccessManager.actionTitle) {
                            calendarAccessManager.performPrimaryAction()
                        }
                        .disabled(calendarAccessManager.isRequesting
                            || calendarAccessManager.state == .fullAccess
                            || calendarAccessManager.state == .unavailable)
                    }
                }
                Text("允许小组件读取系统日历中的节假日订阅和日程，仅用于本机展示。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let errorMessage = calendarAccessManager.errorMessage {
                    Text(errorMessage).font(.callout).foregroundStyle(.red)
                }
            }
            SettingsContentCard("列表排序") {
                HStack {
                    Text("状态页").foregroundStyle(.secondary)
                    Picker("状态页", selection: $selectedSortFilter) {
                        ForEach(RequirementStatusFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Spacer()
                    Button("恢复默认排序") { settingsStore.resetTabSortRules(for: selectedSortFilter) }
                        .disabled(isDefault)
                }
                Divider()
                VStack(spacing: 4) {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        tabSortRuleRow(statusFilter: selectedSortFilter, rule: rule, index: index, count: rules.count)
                    }
                }
                Text("使用右侧箭头调整状态顺序，点击时间方向切换组内排序。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var calendarAccessTint: Color {
        switch calendarAccessManager.state {
        case .fullAccess:
            return .green
        case .notDetermined:
            return DesignColor.doing
        case .denied, .unavailable:
            return DesignColor.stopped
        }
    }

    private func tabSortRuleRow(
        statusFilter: RequirementStatusFilter,
        rule: RequirementTabSortRule,
        index: Int,
        count: Int
    ) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Circle().fill(settingsStatusTint(rule.status)).frame(width: 7, height: 7)
            Text(rule.status.title).font(.system(size: 13))
            Spacer()
            Button {
                settingsStore.toggleTabSortDirection(for: statusFilter, ruleID: rule.id)
            } label: {
                Label(rule.ascending ? "旧 → 新" : "新 → 旧", systemImage: rule.ascending ? "arrow.up" : "arrow.down")
                    .frame(width: 76)
            }
            .help("切换组内时间排序")
            reorderButtons(
                canMoveUp: index > 0, canMoveDown: index < count - 1,
                onMoveUp: { settingsStore.moveTabSortRule(for: statusFilter, ruleID: rule.id, offset: -1) },
                onMoveDown: { settingsStore.moveTabSortRule(for: statusFilter, ruleID: rule.id, offset: 1) }
            )
        }
        .frame(minHeight: 36)
    }

    private func reorderButtons(
        canMoveUp: Bool,
        canMoveDown: Bool,
        onMoveUp: @escaping () -> Void,
        onMoveDown: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 2) {
            Button(action: onMoveUp) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(SettingsIconButtonStyle())
            .disabled(!canMoveUp)
            .foregroundStyle(DesignColor.textPrimary.opacity(canMoveUp ? 0.55 : 0.18))
            .help("上移")
            .pointingHandCursor(canMoveUp)

            Button(action: onMoveDown) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(SettingsIconButtonStyle())
            .disabled(!canMoveDown)
            .foregroundStyle(DesignColor.textPrimary.opacity(canMoveDown ? 0.55 : 0.18))
            .help("下移")
            .pointingHandCursor(canMoveDown)
        }
    }

    private func placeholder(icon: String, title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(DesignColor.textSecondary)

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)
        }
    }

    private var scriptConfigurationView: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsContentCard("脚本来源") {
                HStack(spacing: 12) {
                    Picker("选择命令或项目", selection: scriptSourceSelection) {
                        Section("全局命令") {
                            ForEach(DeveloperCommand.allCases) { command in
                                Text(command.rawValue).tag("command:" + command.rawValue)
                            }
                        }
                        Section("项目脚本") {
                            ForEach(settingsStore.configuration.scriptProjects) { project in
                                Text(project.name.isEmpty ? "未命名项目" : project.name).tag(project.id.uuidString)
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    Spacer(minLength: 8)
                    Button("添加项目", action: chooseProjectFolder)
                    Button("删除项目", role: .destructive) {
                        if !showsGlobalCommands, let selectedProjectID {
                            settingsStore.deleteScriptProject(id: selectedProjectID)
                        }
                    }
                    .disabled(showsGlobalCommands || selectedProjectID == nil)
                }
                if !showsGlobalCommands, let project = selectedProject,
                   let index = settingsStore.configuration.scriptProjects.firstIndex(where: { $0.id == project.id }) {
                    HStack {
                        Text("项目显示顺序").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        reorderButtons(
                            canMoveUp: index > 0,
                            canMoveDown: index < settingsStore.configuration.scriptProjects.count - 1,
                            onMoveUp: { settingsStore.moveScriptProject(id: project.id, offset: -1) },
                            onMoveDown: { settingsStore.moveScriptProject(id: project.id, offset: 1) }
                        )
                    }
                }
            }
            if showsGlobalCommands {
                GlobalCommandRegistrationView(command: selectedGlobalCommand).id(selectedGlobalCommand)
            } else {
                scriptDetail
            }
        }
    }

    private var scriptSourceSelection: Binding<String> {
        Binding {
            showsGlobalCommands ? "command:" + selectedGlobalCommand.rawValue : (selectedProjectID?.uuidString ?? "")
        } set: { value in
            if let command = DeveloperCommand.allCases.first(where: { "command:" + $0.rawValue == value }) {
                selectedGlobalCommand = command
                showsGlobalCommands = true
            } else if let project = settingsStore.configuration.scriptProjects.first(where: { $0.id.uuidString == value }) {
                selectedProjectID = project.id
                showsGlobalCommands = false
            }
        }
    }

    @ViewBuilder
    private var scriptDetail: some View {
        if let project = selectedProject {
            SettingsContentCard("项目") {
                SettingsFieldRow("项目名称") {
                    SettingsTextInput("项目名称", text: projectNameBinding(projectID: project.id))
                }
                SettingsFieldRow("项目目录") {
                    Text(project.directoryPath)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Text("常用脚本 · \(project.scripts.count)").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { settingsStore.addScript(to: project.id) } label: {
                    Label("添加脚本", systemImage: "plus")
                }
            }
            if project.scripts.isEmpty {
                Text("暂无脚本，点击“添加脚本”开始配置。")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(project.scripts.enumerated()), id: \.element.id) { index, script in
                SettingsContentCard {
                    scriptEditor(projectID: project.id, script: script, index: index, count: project.scripts.count)
                }
            }
        } else {
            placeholder(icon: "terminal", title: "选择或添加项目")
                .frame(maxWidth: .infinity).padding(32)
        }
    }

    private func scriptEditor(
        projectID: RequirementScriptProject.ID,
        script: RequirementScriptCommand,
        index: Int,
        count: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("名称").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                SettingsTextInput("脚本名称", text: scriptNameBinding(projectID: projectID, scriptID: script.id))
                reorderButtons(
                    canMoveUp: index > 0,
                    canMoveDown: index < count - 1,
                    onMoveUp: {
                        settingsStore.moveScript(projectID: projectID, scriptID: script.id, offset: -1)
                    },
                    onMoveDown: {
                        settingsStore.moveScript(projectID: projectID, scriptID: script.id, offset: 1)
                    }
                )

                Button(role: .destructive) {
                    settingsStore.deleteScript(projectID: projectID, scriptID: script.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(SettingsIconButtonStyle())
                .help("删除脚本")
                .pointingHandCursor()
            }

            Text("命令").font(.system(size: 12)).foregroundStyle(.secondary)
            SettingsMultilineEditor(text: scriptBodyBinding(projectID: projectID, scriptID: script.id))
                .frame(height: 96)
                .padding(10)
                .background(DesignColor.surface.opacity(0.84), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(DesignColor.textPrimary.opacity(0.10), lineWidth: 0.7)
                )
        }

    }

    private var quickLinksView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(settingsStore.configuration.quickLinkItems.count) 个链接或分组")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Button { settingsStore.addQuickLinkGroup() } label: {
                    Label("添加分组", systemImage: "folder.badge.plus")
                }
                Button { settingsStore.addQuickLink() } label: {
                    Label("添加链接", systemImage: "plus")
                }
            }
            if settingsStore.configuration.quickLinkItems.isEmpty {
                Text("暂无快捷链接，可添加链接或分组。")
                    .foregroundStyle(.secondary).padding(.vertical, 24)
            }
            ForEach(Array(settingsStore.configuration.quickLinkItems.enumerated()), id: \.element.id) { index, item in
                quickLinkTopLevelEditor(item, index: index, count: settingsStore.configuration.quickLinkItems.count)
            }
        }
    }

    @ViewBuilder
    private func quickLinkTopLevelEditor(
        _ item: RequirementQuickLinkItem,
        index: Int,
        count: Int
    ) -> some View {
        switch item {
        case let .link(link):
            SettingsContentCard {
            quickLinkEditor(
                link,
                groupID: nil,
                canMoveUp: index > 0,
                canMoveDown: index < count - 1,
                onMoveUp: {
                    settingsStore.moveQuickLinkItem(id: link.id, offset: -1)
                },
                onMoveDown: {
                    settingsStore.moveQuickLinkItem(id: link.id, offset: 1)
                }
            )
            }
        case let .group(group):
            quickLinkGroupEditor(group, index: index, count: count)
        }
    }

    private func quickLinkGroupEditor(
        _ group: RequirementQuickLinkGroup,
        index: Int,
        count: Int
    ) -> some View {
        SettingsContentCard {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignColor.doing)

                SettingsTextInput("分组名称", text: quickLinkGroupNameBinding(groupID: group.id))
                reorderButtons(
                    canMoveUp: index > 0,
                    canMoveDown: index < count - 1,
                    onMoveUp: {
                        settingsStore.moveQuickLinkItem(id: group.id, offset: -1)
                    },
                    onMoveDown: {
                        settingsStore.moveQuickLinkItem(id: group.id, offset: 1)
                    }
                )

                Button("解散") {
                    settingsStore.dissolveQuickLinkGroup(id: group.id)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(DesignColor.stopped)
                .help("解散分组，内部链接保留为不分组状态")
                .pointingHandCursor()
            }

            if group.links.isEmpty {
                Text("暂无链接，可通过链接右侧的分组菜单移入")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(group.links.enumerated()), id: \.element.id) { linkIndex, link in
                    Divider()
                    quickLinkEditor(
                        link,
                        groupID: group.id,
                        canMoveUp: linkIndex > 0,
                        canMoveDown: linkIndex < group.links.count - 1,
                        onMoveUp: {
                            settingsStore.moveQuickLink(id: link.id, offset: -1)
                        },
                        onMoveDown: {
                            settingsStore.moveQuickLink(id: link.id, offset: 1)
                        }
                    )
                }
            }
        }
    }

    private func quickLinkEditor(
        _ link: RequirementQuickLink,
        groupID: RequirementQuickLinkGroup.ID?,
        canMoveUp: Bool,
        canMoveDown: Bool,
        onMoveUp: @escaping () -> Void,
        onMoveDown: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("名称").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                SettingsTextInput("链接名称", text: quickLinkNameBinding(linkID: link.id))
            }
            HStack(spacing: 12) {
                Text("地址").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                SettingsTextInput("https://…", text: quickLinkURLBinding(linkID: link.id))
                    .accessibilityLabel("链接地址")
            }
            HStack(spacing: 12) {
                Text("分组").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                quickLinkGroupMenu(linkID: link.id, currentGroupID: groupID)
                Spacer()
                reorderButtons(canMoveUp: canMoveUp, canMoveDown: canMoveDown,
                    onMoveUp: onMoveUp, onMoveDown: onMoveDown)
                Button(role: .destructive) { settingsStore.deleteQuickLink(id: link.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(SettingsIconButtonStyle()).help("删除链接")
            }
        }
        .font(.system(size: 13))
    }

    private func quickLinkGroupMenu(
        linkID: RequirementQuickLink.ID,
        currentGroupID: RequirementQuickLinkGroup.ID?
    ) -> some View {
        Menu {
            Button {
                settingsStore.moveQuickLink(id: linkID, toGroupID: nil)
            } label: {
                Label("不分组", systemImage: currentGroupID == nil ? "checkmark" : "tray")
            }
            .disabled(currentGroupID == nil)

            if !settingsStore.quickLinkGroups.isEmpty {
                Divider()

                ForEach(settingsStore.quickLinkGroups) { group in
                    Button {
                        settingsStore.moveQuickLink(id: linkID, toGroupID: group.id)
                    } label: {
                        Label(
                            group.name.isEmpty ? "未命名分组" : group.name,
                            systemImage: currentGroupID == group.id ? "checkmark" : "folder"
                        )
                    }
                    .disabled(currentGroupID == group.id)
                }
            }
        } label: {
            Label(
                quickLinkGroupDisplayName(groupID: currentGroupID),
                systemImage: currentGroupID == nil ? "tray" : "folder"
            )
            .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .lineLimit(1)
        .frame(width: 170, height: 28)
        .help("选择所属分组")
        .pointingHandCursor()
    }

    private func quickLinkGroupDisplayName(groupID: RequirementQuickLinkGroup.ID?) -> String {
        guard let groupID,
              let group = settingsStore.quickLinkGroup(id: groupID)
        else {
            return "不分组"
        }

        let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未命名分组" : name
    }

    private var pluginConfigurationView: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsContentCard("站点配置") {
                SettingsFieldRow("Jira 基础地址") {
                    SettingsTextInput("http://jira.zstack.io/browse/", text: pluginJiraBaseURLBinding)
                }
                SettingsFieldRow("MR 域名") {
                    SettingsTextInput("gitlab.zstack.io", text: pluginMRHostBinding)
                }
                Text("用于补全 Jira 链接，以及识别 GitLab 合并请求页面。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            SettingsContentCard("浏览器扩展") {
                SettingsFieldRow("扩展 ID") {
                    SettingsTextInput("从扩展管理页面复制 ID", text: pluginChromeExtensionIDBinding)
                }
                Text("在 chrome://extensions 中加载插件目录，再填入扩展 ID。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("打开插件目录", action: openPluginDirectory)
                    Button("打开测试页", action: openPluginTestPage)
                        .disabled(settingsStore.configuration.pluginSettings.chromeExtensionID
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }
            }
            SettingsContentCard("本机连接") {
                nativeHostStatusInline
                HStack(alignment: .center, spacing: 16) {
                    Text("安装连接组件，让浏览器与需求记录 App 通信。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(isInstallingNativeHost ? "安装中…" : "安装 Native Host", action: installNativeHost)
                        .disabled(isInstallingNativeHost || settingsStore.configuration.pluginSettings.chromeExtensionID
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            SettingsContentCard("MR 状态自动同步") {
                SettingsFieldRow("打开需求 MR") { Label("已自测", systemImage: "checkmark.circle").foregroundStyle(DesignColor.tested) }
                SettingsFieldRow("MR 合并") { Label("已合并", systemImage: "checkmark.circle.fill").foregroundStyle(DesignColor.merged) }
                Divider()
                Text("仅更新已记录且关联明确的需求。暂停、停止和历史 MR 不会自动推进；浏览器运行时每 15 分钟补查合并状态。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var nativeHostStatusInline: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(nativeHostStatusColor)
                .frame(width: 7, height: 7)

            Text(nativeHostStatusTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)
                .fixedSize()

            Text(nativeHostStatusDetail)
                .font(.system(size: 11))
                .foregroundStyle(DesignColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                refreshNativeHostStatus()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignColor.textSecondary)
            }
            .buttonStyle(.borderless)
            .help("刷新连接状态")
            .pointingHandCursor()
        }
        .onAppear {
            refreshNativeHostStatus()
        }
    }

    private var nativeHostStatusColor: Color {
        guard let nativeHostStatus else {
            return DesignColor.textPrimary.opacity(0.25)
        }

        return nativeHostStatus.isConnected
            ? Color(red: 0.08, green: 0.65, blue: 0.42)
            : Color(red: 0.85, green: 0.18, blue: 0.26)
    }

    private var nativeHostStatusTitle: String {
        guard let nativeHostStatus else {
            return "检查中..."
        }

        return nativeHostStatus.isConnected ? "已连接" : "未连接"
    }

    private var nativeHostStatusDetail: String {
        guard let nativeHostStatus else {
            return ""
        }

        if nativeHostStatus.isConnected {
            if let lastSeenAt = nativeHostStatus.lastSeenAt {
                return "最近通信 \(Self.heartbeatFormatter.string(from: lastSeenAt))"
            }

            return "已安装，等待插件首次通信"
        }

        return nativeHostStatus.detail
    }

    private static let heartbeatFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private func refreshNativeHostStatus() {
        nativeHostStatus = RequirementPluginSupport.nativeHostStatus(
            extensionID: settingsStore.configuration.pluginSettings.chromeExtensionID
        )
    }

    private func settingsStatusTint(_ status: RequirementTimelineStatus) -> Color {
        switch status {
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

    private var selectedProject: RequirementScriptProject? {
        if let selectedProjectID,
           let project = settingsStore.configuration.scriptProjects.first(where: { $0.id == selectedProjectID }) {
            return project
        }

        return settingsStore.configuration.scriptProjects.first
    }

    private func ensureProjectSelection() {
        let projects = settingsStore.configuration.scriptProjects
        guard !projects.isEmpty else {
            selectedProjectID = nil
            return
        }

        if selectedProjectID == nil || !projects.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID = projects.first?.id
        }
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "选择"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        selectedProjectID = settingsStore.addScriptProject(directoryURL: url)
        showsGlobalCommands = false
    }

    private func projectNameBinding(projectID: RequirementScriptProject.ID) -> Binding<String> {
        Binding {
            settingsStore.configuration.scriptProjects.first { $0.id == projectID }?.name ?? ""
        } set: { value in
            settingsStore.updateScriptProject(id: projectID) { project in
                project.name = value
            }
        }
    }

    private func scriptNameBinding(
        projectID: RequirementScriptProject.ID,
        scriptID: RequirementScriptCommand.ID
    ) -> Binding<String> {
        Binding {
            settingsStore.configuration.scriptProjects
                .first { $0.id == projectID }?
                .scripts
                .first { $0.id == scriptID }?
                .name ?? ""
        } set: { value in
            settingsStore.updateScriptProject(id: projectID) { project in
                guard let index = project.scripts.firstIndex(where: { $0.id == scriptID }) else {
                    return
                }
                project.scripts[index].name = value
            }
        }
    }

    private func scriptBodyBinding(
        projectID: RequirementScriptProject.ID,
        scriptID: RequirementScriptCommand.ID
    ) -> Binding<String> {
        Binding {
            settingsStore.configuration.scriptProjects
                .first { $0.id == projectID }?
                .scripts
                .first { $0.id == scriptID }?
                .script ?? ""
        } set: { value in
            settingsStore.updateScriptProject(id: projectID) { project in
                guard let index = project.scripts.firstIndex(where: { $0.id == scriptID }) else {
                    return
                }
                project.scripts[index].script = value
            }
        }
    }

    private func quickLinkNameBinding(linkID: RequirementQuickLink.ID) -> Binding<String> {
        Binding {
            settingsStore.quickLink(id: linkID)?.name ?? ""
        } set: { value in
            settingsStore.updateQuickLink(id: linkID) { link in
                link.name = value
            }
        }
    }

    private func quickLinkURLBinding(linkID: RequirementQuickLink.ID) -> Binding<String> {
        Binding {
            settingsStore.quickLink(id: linkID)?.url ?? ""
        } set: { value in
            settingsStore.updateQuickLink(id: linkID) { link in
                link.url = value
            }
        }
    }

    private func quickLinkGroupNameBinding(groupID: RequirementQuickLinkGroup.ID) -> Binding<String> {
        Binding {
            settingsStore.quickLinkGroup(id: groupID)?.name ?? ""
        } set: { value in
            settingsStore.updateQuickLinkGroup(id: groupID) { group in
                group.name = value
            }
        }
    }

    private var pluginJiraBaseURLBinding: Binding<String> {
        Binding {
            settingsStore.configuration.pluginSettings.jiraBaseURL
        } set: { value in
            settingsStore.updatePluginSettings { settings in
                settings.jiraBaseURL = value
            }
        }
    }

    private var pluginMRHostBinding: Binding<String> {
        Binding {
            settingsStore.configuration.pluginSettings.mrHosts.first ?? ""
        } set: { value in
            settingsStore.updatePluginSettings { settings in
                settings.mrHosts = [value]
            }
        }
    }

    private var pluginChromeExtensionIDBinding: Binding<String> {
        Binding {
            settingsStore.configuration.pluginSettings.chromeExtensionID
        } set: { value in
            settingsStore.updatePluginSettings { settings in
                settings.chromeExtensionID = value
            }
        }
    }

    private func openPluginDirectory() {
        do {
            try RequirementPluginSupport.openExtensionDirectory()
        } catch {
            pluginAlertMessage = error.localizedDescription
        }
    }

    private func installNativeHost() {
        let extensionID = settingsStore.configuration.pluginSettings.chromeExtensionID
        isInstallingNativeHost = true

        Task {
            do {
                _ = try await RequirementPluginSupport.installNativeHost(extensionID: extensionID)
            } catch {
                pluginAlertMessage = error.localizedDescription
            }

            isInstallingNativeHost = false
            refreshNativeHostStatus()
        }
    }

    private func openPluginTestPage() {
        let extensionID = settingsStore.configuration.pluginSettings.chromeExtensionID

        Task {
            do {
                try await RequirementPluginSupport.openExtensionTestPage(extensionID: extensionID)
            } catch {
                pluginAlertMessage = error.localizedDescription
            }
        }
    }
}

private enum RequirementSettingsTab: String, CaseIterable, Identifiable {
    case base
    case plugin
    case scripts
    case quickLinks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .base:
            "基础设置"
        case .plugin:
            "插件配置"
        case .scripts:
            "脚本配置"
        case .quickLinks:
            "快捷访问"
        }
    }

    var subtitle: String {
        switch self {
        case .base: "调整菜单栏外观、日历访问和需求排序。"
        case .plugin: "连接浏览器扩展，管理 Jira 与 GitLab 站点。"
        case .scripts: "管理全局命令与项目常用脚本。"
        case .quickLinks: "整理常用链接，在菜单栏快速访问。"
        }
    }

    var systemImage: String {
        switch self {
        case .base:
            "gearshape"
        case .plugin:
            "puzzlepiece.extension"
        case .scripts:
            "terminal"
        case .quickLinks:
            "link"
        }
    }
}

private extension RequirementPanelStyle {
    var systemImage: String {
        switch self {
        case .standard:
            "rectangle"
        case .minimal:
            "minus"
        case .modern:
            "sparkles"
        }
    }

    var summary: String {
        switch self {
        case .standard:
            "顶部状态栏，底部日期与搜索"
        case .minimal:
            "状态、日期与搜索集中在横条"
        case .modern:
            "玻璃搜索按钮与独立操作按钮"
        }
    }
}

private struct SettingsMultilineEditor: NSViewRepresentable {
    @Binding var text: String
    /// 为 true 时作为“单行内容、多行展示”的编辑器：换行会被拒绝或过滤（适合 URL）。
    var disallowsLineBreaks = false

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, disallowsLineBreaks: disallowsLineBreaks)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = TextEditorScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        textView.autoresizingMask = [.width]
        textView.string = text
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        context.coordinator.updateBinding($text)
        if textView.string != text {
            textView.string = text
            textView.sizeToFit()
        }
        scrollView.needsLayout = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        let disallowsLineBreaks: Bool

        init(text: Binding<String>, disallowsLineBreaks: Bool) {
            _text = text
            self.disallowsLineBreaks = disallowsLineBreaks
        }

        func updateBinding(_ text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            if disallowsLineBreaks, textView.string.contains(where: \.isNewline) {
                textView.string = textView.string.filter { !$0.isNewline }
            }

            text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard disallowsLineBreaks else {
                return false
            }

            return commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
        }
    }
}

private struct SettingsIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .frame(width: 28, height: 28)
            .background(
                DesignColor.textPrimary.opacity(configuration.isPressed ? 0.10 : 0.035),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.35)
    }
}

// 设置内容自行控制列宽和间距，避免 Form 的自动标签布局改变编辑控件的位置。
struct SettingsContentCard<Content: View>: View {
    private let title: String?
    private let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title { Text(title).font(.system(size: 14, weight: .semibold)) }
            content
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
        }
    }
}

private struct SettingsFieldRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 112, height: 34, alignment: .leading)
            content
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        }
    }
}

private struct SettingsTextInput: View {
    let title: String
    @Binding var text: String
    @FocusState private var isFocused: Bool

    init(_ title: String, text: Binding<String>) {
        self.title = title
        _text = text
    }

    var body: some View {
        TextField(title, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .multilineTextAlignment(.leading)
            .focused($isFocused)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isFocused ? Color.accentColor : Color.primary.opacity(0.16), lineWidth: isFocused ? 1.5 : 0.7)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel(title)
    }
}
