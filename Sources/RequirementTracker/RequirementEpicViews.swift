import RequirementCore
import SwiftUI

struct RequirementEpicBadge: View {
    let name: String

    var body: some View {
        Label("Epic", systemImage: "bolt.fill")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.purple)
            .padding(.horizontal, 4)
            .frame(height: 16)
            .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            .fixedSize()
            .help(name)
            .accessibilityLabel("Epic：\(name)")
    }
}

struct RequirementEpicQuickLook: View {
    let key: String
    let name: String
    let requirements: [Requirement]
    let onClose: () -> Void
    @State private var expandedID: Requirement.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(key, systemImage: "bolt.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("关闭 Epic 速览")
                    .accessibilityLabel("关闭 Epic 速览")
                }
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .help(name)
                Text("App 已记录 \(requirements.count) 项")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            // 与主列表共用卡片和 Store，操作直接更新同一条需求记录。
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(requirements) { requirement in
                        RequirementRowView(
                            requirement: requirement,
                            isExpanded: expandedID == requirement.id,
                            onToggleExpanded: {
                                expandedID = expandedID == requirement.id ? nil : requirement.id
                            },
                            epicName: name
                        )
                    }
                    if requirements.isEmpty {
                        Text("此 Epic 暂无已记录的需求")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 30)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: RequirementPanelMetrics.width - 16, height: RequirementPanelMetrics.height - 24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
    }
}
