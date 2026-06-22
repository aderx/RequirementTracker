import AppKit
import RequirementCore
import SwiftUI

struct RequirementSettingsView: View {
    @EnvironmentObject private var settingsStore: RequirementSettingsStore
    @State private var selectedTab: RequirementSettingsTab = .base
    @State private var selectedProjectID: RequirementScriptProject.ID?

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
                    .frame(width: 82, height: 66)
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
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .base:
            placeholder(icon: "gearshape", title: "基础设置")
        case .plugin:
            placeholder(icon: "puzzlepiece.extension", title: "插件配置")
        case .scripts:
            scriptConfigurationView
        case .quickLinks:
            quickLinksView
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

            ScrollView {
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

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(project.scripts) { script in
                            scriptEditor(projectID: project.id, script: script)
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
        script: RequirementScriptCommand
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                TextField("脚本名称", text: scriptNameBinding(projectID: projectID, scriptID: script.id))
                    .textFieldStyle(.roundedBorder)

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

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(settingsStore.configuration.quickLinks) { link in
                        HStack(spacing: 9) {
                            TextField("名称", text: quickLinkNameBinding(linkID: link.id))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 170)

                            TextField("URL", text: quickLinkURLBinding(linkID: link.id))
                                .textFieldStyle(.roundedBorder)

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

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
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
