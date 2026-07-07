import AppKit
import RequirementCore
import SwiftUI

struct RequirementSettingsView: View {
    @EnvironmentObject private var settingsStore: RequirementSettingsStore
    @State private var selectedTab: RequirementSettingsTab = .base
    @State private var selectedProjectID: RequirementScriptProject.ID?
    @State private var pluginAlertMessage = ""
    @State private var isInstallingNativeHost = false
    @State private var nativeHostStatus: RequirementNativeHostStatus?

    var body: some View {
        ZStack {
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                settingsToolbar

                GlassDivider()

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 760, height: 520)
        .background(TransparentWindowConfigurator())
        .onAppear {
            ensureProjectSelection()
        }
        .onChange(of: settingsStore.configuration.scriptProjects.map(\.id)) { _ in
            ensureProjectSelection()
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

    private var settingsToolbar: some View {
        HStack(spacing: 18) {
            ForEach(RequirementSettingsTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 22, weight: .regular))
                            .frame(height: 25)

                        Text(tab.title)
                            .font(.system(size: 11.5, weight: selectedTab == tab ? .semibold : .regular))
                    }
                    .foregroundStyle(selectedTab == tab ? DesignColor.doing : Color.black.opacity(0.58))
                    .frame(width: 82, height: 58)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selectedTab == tab ? Color.white.opacity(0.82) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 88)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .base:
            baseConfigurationView
        case .plugin:
            pluginConfigurationView
        case .scripts:
            scriptConfigurationView
        case .quickLinks:
            quickLinksView
        }
    }

    private var baseConfigurationView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                pluginSettingCard(
                    title: "列表排序",
                    subtitle: "点击状态切换组内时间方向（↑早的在前 ↓新的在前），‹ › 调整分组顺序"
                ) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(RequirementStatusFilter.allCases) { statusFilter in
                            tabSortRow(for: statusFilter)
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    private func tabSortRow(for statusFilter: RequirementStatusFilter) -> some View {
        let rules = settingsStore.tabSortRules(for: statusFilter)
        let isDefault = rules == RequirementTabSortConfiguration.defaultRules(for: statusFilter)

        return HStack(spacing: 6) {
            Text(statusFilter.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)
                .frame(width: 50, alignment: .leading)

            ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                tabSortChip(statusFilter: statusFilter, rule: rule, index: index, count: rules.count)
            }

            Spacer(minLength: 0)

            if !isDefault {
                Button {
                    settingsStore.resetTabSortRules(for: statusFilter)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.45))
                }
                .buttonStyle(.borderless)
                .help("恢复默认")
                .pointingHandCursor()
            }
        }
    }

    private func tabSortChip(
        statusFilter: RequirementStatusFilter,
        rule: RequirementTabSortRule,
        index: Int,
        count: Int
    ) -> some View {
        HStack(spacing: 1) {
            if count > 1 {
                tabSortMoveButton(systemImage: "chevron.left", enabled: index > 0) {
                    settingsStore.moveTabSortRule(for: statusFilter, ruleID: rule.id, offset: -1)
                }
            }

            Button {
                settingsStore.toggleTabSortDirection(for: statusFilter, ruleID: rule.id)
            } label: {
                HStack(spacing: 3) {
                    Text(rule.status.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DesignColor.textPrimary)

                    Image(systemName: rule.ascending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.55))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(rule.ascending ? "组内时间早的在前，点击切换为倒序" : "组内时间新的在前，点击切换为正序")
            .pointingHandCursor()

            if count > 1 {
                tabSortMoveButton(systemImage: "chevron.right", enabled: index < count - 1) {
                    settingsStore.moveTabSortRule(for: statusFilter, ruleID: rule.id, offset: 1)
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
        )
    }

    private func tabSortMoveButton(
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 12, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .foregroundStyle(Color.black.opacity(enabled ? 0.45 : 0.15))
        .pointingHandCursor(enabled)
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
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(!canMoveUp)
            .foregroundStyle(Color.black.opacity(canMoveUp ? 0.55 : 0.18))
            .help("上移")
            .pointingHandCursor(canMoveUp)

            Button(action: onMoveDown) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(!canMoveDown)
            .foregroundStyle(Color.black.opacity(canMoveDown ? 0.55 : 0.18))
            .help("下移")
            .pointingHandCursor(canMoveDown)
        }
    }

    private func placeholder(icon: String, title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.35))

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)

            Text("暂未配置")
                .font(.system(size: 12))
                .foregroundStyle(Color.black.opacity(0.40))
        }
    }

    private var scriptConfigurationView: some View {
        HStack(spacing: 0) {
            projectList
                .frame(width: 230)

            scriptDetail
        }
        .padding(18)
    }

    private var projectList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("项目")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignColor.textPrimary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 5) {
                    ForEach(settingsStore.configuration.scriptProjects) { project in
                        Button {
                            selectedProjectID = project.id
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(project.name.isEmpty ? "未命名项目" : project.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(DesignColor.textPrimary)
                                    .lineLimit(1)

                                Text(project.directoryPath)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Color.black.opacity(0.38))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(project.id == selectedProjectID ? DesignColor.doing.opacity(0.12) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                }
                .padding(.horizontal, 8)
            }

            GlassDivider()

            HStack(spacing: 10) {
                Button {
                    chooseProjectFolder()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("添加项目")
                .pointingHandCursor()

                Button {
                    if let selectedProjectID {
                        settingsStore.deleteScriptProject(id: selectedProjectID)
                    }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(selectedProjectID == nil)
                .help("删除项目")
                .pointingHandCursor(selectedProjectID != nil)

                Spacer()
            }
            .foregroundStyle(Color.black.opacity(0.62))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.7)
        )
        .padding(.trailing, 16)
    }

    @ViewBuilder
    private var scriptDetail: some View {
        if let project = selectedProject {
            VStack(alignment: .leading, spacing: 12) {
                TextField("项目名称", text: projectNameBinding(projectID: project.id))
                    .textFieldStyle(.roundedBorder)

                Text(project.directoryPath)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.black.opacity(0.42))
                    .lineLimit(1)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(project.scripts.enumerated()), id: \.element.id) { index, script in
                            scriptEditor(
                                projectID: project.id,
                                script: script,
                                index: index,
                                count: project.scripts.count
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }

                Button {
                    settingsStore.addScript(to: project.id)
                } label: {
                    Label("添加脚本", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()
            }
        } else {
            placeholder(icon: "terminal", title: "脚本配置")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                TextField("脚本名称", text: scriptNameBinding(projectID: projectID, scriptID: script.id))
                    .textFieldStyle(.roundedBorder)

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
                .buttonStyle(.borderless)
                .help("删除脚本")
                .pointingHandCursor()
            }

            SettingsMultilineEditor(text: scriptBodyBinding(projectID: projectID, scriptID: script.id))
                .frame(minHeight: 74)
                .padding(6)
                .background(Color.white.opacity(0.84), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.7)
                )
        }
        .padding(10)
        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var quickLinksView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("快捷访问")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignColor.textPrimary)

                Spacer()

                Button {
                    settingsStore.addQuickLink()
                } label: {
                    Label("添加链接", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    ForEach(Array(settingsStore.configuration.quickLinks.enumerated()), id: \.element.id) { index, link in
                        HStack(spacing: 9) {
                            TextField("名称", text: quickLinkNameBinding(linkID: link.id))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 170)

                            quickLinkURLEditor(linkID: link.id)

                            reorderButtons(
                                canMoveUp: index > 0,
                                canMoveDown: index < settingsStore.configuration.quickLinks.count - 1,
                                onMoveUp: {
                                    settingsStore.moveQuickLink(id: link.id, offset: -1)
                                },
                                onMoveDown: {
                                    settingsStore.moveQuickLink(id: link.id, offset: 1)
                                }
                            )

                            Button(role: .destructive) {
                                settingsStore.deleteQuickLink(id: link.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("删除链接")
                            .pointingHandCursor()
                        }
                        .padding(10)
                        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
        .padding(22)
    }

    private var pluginConfigurationView: some View {
        VStack(alignment: .leading, spacing: 12) {
            pluginSettingCard(title: "Jira 基础地址", subtitle: "用于把 Jira 编号补全为 browse 地址") {
                TextField("http://jira.zstack.io/browse/", text: pluginJiraBaseURLBinding)
                    .textFieldStyle(.roundedBorder)
            }

            pluginSettingCard(title: "MR 域名", subtitle: "插件会在这个域名页面上识别 MR") {
                TextField("gitlab.zstack.io", text: pluginMRHostBinding)
                    .textFieldStyle(.roundedBorder)
            }

            pluginSettingCard(title: "Chrome 扩展 ID", subtitle: "从 chrome://extensions 复制扩展 ID，填入后点击右侧安装即可连接") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("从 chrome://extensions 复制", text: pluginChromeExtensionIDBinding)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        Button {
                            openPluginDirectory()
                        } label: {
                            Label("打开插件目录", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .pointingHandCursor()

                        nativeHostStatusInline
                            .padding(.leading, 4)

                        Spacer(minLength: 8)

                        Button {
                            installNativeHost()
                        } label: {
                            Label(isInstallingNativeHost ? "安装中..." : "安装 Native Host", systemImage: "tray.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isInstallingNativeHost || settingsStore.configuration.pluginSettings.chromeExtensionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .pointingHandCursor(!isInstallingNativeHost)
                    }
                }
            }

            Spacer()
        }
        .padding(22)
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
                .foregroundStyle(Color.black.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                refreshNativeHostStatus()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.50))
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
            return Color.black.opacity(0.25)
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

    private func pluginSettingCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            settingField(title: title, subtitle: subtitle, content: content)
        }
        .padding(14)
        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.7)
        )
    }

    private func settingField<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Color.black.opacity(0.42))

            content()
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

    /// URL 编辑框：单行内容、最多三行换行展示，超出部分滚动查看。
    private func quickLinkURLEditor(linkID: RequirementQuickLink.ID) -> some View {
        let binding = quickLinkURLBinding(linkID: linkID)

        return SettingsMultilineEditor(text: binding, disallowsLineBreaks: true)
            .frame(height: 48)
            .padding(6)
            .background(Color.white.opacity(0.84), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.7)
            )
            .overlay(alignment: .topLeading) {
                if binding.wrappedValue.isEmpty {
                    Text("https://...")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.black.opacity(0.28))
                        .padding(.leading, 8)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                }
            }
    }

    private func quickLinkNameBinding(linkID: RequirementQuickLink.ID) -> Binding<String> {
        Binding {
            settingsStore.configuration.quickLinks.first { $0.id == linkID }?.name ?? ""
        } set: { value in
            settingsStore.updateQuickLink(id: linkID) { link in
                link.name = value
            }
        }
    }

    private func quickLinkURLBinding(linkID: RequirementQuickLink.ID) -> Binding<String> {
        Binding {
            settingsStore.configuration.quickLinks.first { $0.id == linkID }?.url ?? ""
        } set: { value in
            settingsStore.updateQuickLink(id: linkID) { link in
                link.url = value
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

private struct SettingsMultilineEditor: NSViewRepresentable {
    @Binding var text: String
    /// 为 true 时作为“单行内容、多行展示”的编辑器：换行会被拒绝或过滤（适合 URL）。
    var disallowsLineBreaks = false

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, disallowsLineBreaks: disallowsLineBreaks)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
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

        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        let disallowsLineBreaks: Bool

        init(text: Binding<String>, disallowsLineBreaks: Bool) {
            _text = text
            self.disallowsLineBreaks = disallowsLineBreaks
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
