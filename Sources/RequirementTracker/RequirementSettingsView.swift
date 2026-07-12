import AppKit
import RequirementCore
import SwiftUI

struct RequirementSettingsView: View {
    @EnvironmentObject private var settingsStore: RequirementSettingsStore
    @State private var selectedTab: RequirementSettingsTab = .base
    @State private var selectedSortFilter: RequirementStatusFilter = .incomplete
    @Namespace private var sortFilterSelectionNamespace
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
        .ignoresSafeArea(.container, edges: .top)
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
        HStack(spacing: 14) {
            Text("设置")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(DesignColor.textPrimary)

            Spacer(minLength: 12)

            HStack(spacing: 4) {
                ForEach(RequirementSettingsTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 10.5, weight: .semibold))

                            Text(tab.title)
                                .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(selectedTab == tab ? DesignColor.doing : Color.black.opacity(0.55))
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(
                            selectedTab == tab
                                ? Color.white.opacity(0.82)
                                : Color.black.opacity(0.025),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    selectedTab == tab
                                        ? DesignColor.doing.opacity(0.20)
                                        : Color.clear,
                                    lineWidth: 0.6
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
        }
        .padding(.leading, 88)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(Color.white.opacity(0.20))
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
        let rules = settingsStore.tabSortRules(for: selectedSortFilter)
        let isDefault = rules == RequirementTabSortConfiguration.defaultRules(for: selectedSortFilter)

        return ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                settingsPageHeader(
                    title: "弹窗样式",
                    help: "选择菜单栏弹窗底部的状态、日期、搜索与更多操作布局。"
                )

                panelStyleSelector

                GlassDivider()
                    .padding(.vertical, 2)

                HStack(spacing: 8) {
                    settingsPageHeader(
                        title: "列表排序",
                        help: "选择状态页后，可调整状态顺序以及各状态的时间正倒序。"
                    )

                    Spacer()

                    sortFilterSegmentedControl

                    if !isDefault {
                        Button {
                            settingsStore.resetTabSortRules(for: selectedSortFilter)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.black.opacity(0.48))
                        .help("恢复默认排序")
                        .pointingHandCursor()
                    }
                }

                VStack(spacing: 7) {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        tabSortRuleRow(
                            statusFilter: selectedSortFilter,
                            rule: rule,
                            index: index,
                            count: rules.count
                        )
                    }
                }
                .padding(10)
                .background(Color.white.opacity(0.60), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.075), lineWidth: 0.6)
                )
            }
            .padding(20)
        }
    }

    private var panelStyleSelector: some View {
        HStack(spacing: 8) {
            ForEach(RequirementPanelStyle.allCases) { style in
                let isSelected = settingsStore.panelStyle == style

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        settingsStore.setPanelStyle(style)
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: style.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isSelected ? DesignColor.doing : Color.black.opacity(0.42))
                            .frame(width: 24, height: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(style.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DesignColor.textPrimary)

                            Text(style.summary)
                                .font(.system(size: 9.5))
                                .foregroundStyle(Color.black.opacity(0.46))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 2)

                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isSelected ? DesignColor.doing : Color.black.opacity(0.18))
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .background(
                        isSelected ? DesignColor.doing.opacity(0.085) : Color.white.opacity(0.56),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                isSelected ? DesignColor.doing.opacity(0.22) : Color.black.opacity(0.075),
                                lineWidth: 0.6
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("弹窗样式：\(style.title)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .pointingHandCursor()
            }
        }
    }

    private var sortFilterSegmentedControl: some View {
        HStack(spacing: 2) {
            ForEach(RequirementStatusFilter.allCases) { statusFilter in
                let isSelected = selectedSortFilter == statusFilter

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedSortFilter = statusFilter
                    }
                } label: {
                    Text(statusFilter.title)
                        .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? DesignColor.doing : Color.black.opacity(0.48))
                        .frame(minWidth: 42)
                        .frame(height: 24)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(DesignColor.doing.opacity(0.12))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(DesignColor.doing.opacity(0.16), lineWidth: 0.5)
                                    }
                                    .matchedGeometryEffect(
                                        id: "sort-filter-selection",
                                        in: sortFilterSelectionNamespace
                                    )
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换到\(statusFilter.title)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .pointingHandCursor()
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
        }
    }

    private func tabSortRuleRow(
        statusFilter: RequirementStatusFilter,
        rule: RequirementTabSortRule,
        index: Int,
        count: Int
    ) -> some View {
        let tint = settingsStatusTint(rule.status)

        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .frame(width: 25, height: 25)
                .background(tint.opacity(0.12), in: Circle())

            Text(rule.status.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)

            Spacer()

            Button {
                settingsStore.toggleTabSortDirection(for: statusFilter, ruleID: rule.id)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: rule.ascending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9, weight: .bold))

                    Text(rule.ascending ? "旧→新" : "新→旧")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .frame(height: 25)
                .background(Color.white.opacity(0.64), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(rule.ascending ? "组内时间早的在前，点击切换为倒序" : "组内时间新的在前，点击切换为正序")
            .pointingHandCursor()

            if count > 1 {
                reorderButtons(
                    canMoveUp: index > 0,
                    canMoveDown: index < count - 1,
                    onMoveUp: {
                        settingsStore.moveTabSortRule(for: statusFilter, ruleID: rule.id, offset: -1)
                    },
                    onMoveDown: {
                        settingsStore.moveTabSortRule(for: statusFilter, ruleID: rule.id, offset: 1)
                    }
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(tint.opacity(0.13), lineWidth: 0.5)
        )
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

                Text("\(settingsStore.configuration.scriptProjects.count)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignColor.doing)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(DesignColor.doing.opacity(0.09), in: Capsule())

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 5) {
                    ForEach(
                        Array(settingsStore.configuration.scriptProjects.enumerated()),
                        id: \.element.id
                    ) { index, project in
                        HStack(spacing: 3) {
                            Button {
                                selectedProjectID = project.id
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(project.name.isEmpty ? "未命名项目" : project.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(DesignColor.textPrimary)
                                        .lineLimit(1)

                                    Text(project.directoryPath)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.black.opacity(0.38))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()

                            reorderButtons(
                                canMoveUp: index > 0,
                                canMoveDown: index < settingsStore.configuration.scriptProjects.count - 1,
                                onMoveUp: {
                                    settingsStore.moveScriptProject(id: project.id, offset: -1)
                                },
                                onMoveDown: {
                                    settingsStore.moveScriptProject(id: project.id, offset: 1)
                                }
                            )
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            project.id == selectedProjectID
                                ? DesignColor.doing.opacity(0.11)
                                : Color.black.opacity(0.018),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(
                                    project.id == selectedProjectID
                                        ? DesignColor.doing.opacity(0.18)
                                        : Color.clear,
                                    lineWidth: 0.5
                                )
                        )
                    }
                }
                .padding(.horizontal, 8)
            }

            GlassDivider()

            HStack(spacing: 10) {
                Button {
                    chooseProjectFolder()
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("添加项目")
                .pointingHandCursor()

                Button {
                    if let selectedProjectID {
                        settingsStore.deleteScriptProject(id: selectedProjectID)
                    }
                } label: {
                    Label("删除", systemImage: "minus")
                        .font(.system(size: 10.5, weight: .medium))
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
        .background(Color.white.opacity(0.64), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.7)
        )
        .padding(.trailing, 16)
    }

    @ViewBuilder
    private var scriptDetail: some View {
        if let project = selectedProject {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("项目详情")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(DesignColor.textPrimary)

                    Spacer()

                    Text("\(project.scripts.count) 个脚本")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(DesignColor.doing)
                        .padding(.horizontal, 7)
                        .frame(height: 19)
                        .background(DesignColor.doing.opacity(0.09), in: Capsule())
                }

                TextField("项目名称", text: projectNameBinding(projectID: project.id))
                    .textFieldStyle(.roundedBorder)

                Label(project.directoryPath, systemImage: "folder")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.black.opacity(0.40))
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
                .controlSize(.small)
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
        .padding(12)
        .background(Color.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.black.opacity(0.07), lineWidth: 0.6)
        )
    }

    private var quickLinksView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                settingsPageHeader(
                    title: "快捷访问"
                )

                Spacer()

                Button {
                    settingsStore.addQuickLink()
                } label: {
                    Label("添加链接", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 10) {
                    ForEach(Array(settingsStore.configuration.quickLinks.enumerated()), id: \.element.id) { index, link in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 9) {
                                TextField("链接标题", text: quickLinkNameBinding(linkID: link.id))
                                    .textFieldStyle(.roundedBorder)

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

                            quickLinkURLEditor(linkID: link.id)
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.075), lineWidth: 0.6)
                        )
                    }
                }
            }
        }
        .padding(20)
    }

    private var pluginConfigurationView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                settingsPageHeader(
                    title: "插件配置"
                )

                pluginSettingCard(title: "Jira 基础地址", help: "用于把 Jira 编号补全为 browse 地址") {
                    TextField("http://jira.zstack.io/browse/", text: pluginJiraBaseURLBinding)
                        .textFieldStyle(.roundedBorder)
                }

                pluginSettingCard(title: "MR 域名", help: "插件会在这个域名页面上识别 MR") {
                    TextField("gitlab.zstack.io", text: pluginMRHostBinding)
                        .textFieldStyle(.roundedBorder)
                }

                pluginSettingCard(
                    title: "Chrome 扩展 ID",
                    help: "从 chrome://extensions 复制扩展 ID，填入后点击右侧安装即可连接"
                ) {
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
            }
            .padding(20)
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

    private func settingsPageHeader(title: String, help: String? = nil) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(DesignColor.textPrimary)

            if let help {
                SettingsHelpIcon(text: help)
            }
        }
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

    private func pluginSettingCard<Content: View>(
        title: String,
        help: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            settingField(title: title, help: help, content: content)
        }
        .padding(15)
        .background(Color.white.opacity(0.66), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.black.opacity(0.075), lineWidth: 0.6)
        )
        .shadow(color: Color.black.opacity(0.025), radius: 4, y: 1)
    }

    private func settingField<Content: View>(
        title: String,
        help: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignColor.textPrimary)

                if let help {
                    SettingsHelpIcon(text: help)
                }
            }

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

private struct SettingsHelpIcon: View {
    let text: String
    @State private var isPopoverPresented = false
    @State private var isPinned = false
    @State private var isPointerInside = false

    var body: some View {
        Button {
            isPinned.toggle()
            isPopoverPresented = isPinned
        } label: {
            Text("?")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.secondary)
                .frame(width: 16, height: 16)
                .background(Color.secondary.opacity(0.08), in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 0.5)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover(perform: updatePointerState)
        .popover(
            isPresented: popoverPresentation,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 220, alignment: .leading)
                .padding(11)
                .onHover(perform: updatePointerState)
        }
        .pointingHandCursor()
        .accessibilityLabel("说明")
        .accessibilityHint(text)
    }

    private var popoverPresentation: Binding<Bool> {
        Binding(
            get: {
                isPopoverPresented
            },
            set: { isPresented in
                isPopoverPresented = isPresented
                if !isPresented {
                    isPinned = false
                }
            }
        )
    }

    private func updatePointerState(_ isInside: Bool) {
        isPointerInside = isInside

        if isInside {
            isPopoverPresented = true
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if !isPointerInside && !isPinned {
                isPopoverPresented = false
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
