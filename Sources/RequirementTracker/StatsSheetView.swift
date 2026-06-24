import RequirementCore
import SwiftUI

struct StatsSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: RequirementStore

    @State private var dateFilter: RequirementDateFilter = .thisWeek

    private var stats: RequirementStats {
        RequirementQuery.stats(for: store.requirements, dateFilter: dateFilter)
    }

    private var requirements: [Requirement] {
        RequirementQuery.sorted(
            store.requirements,
            dateFilter: dateFilter
        )
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: .menu, blendingMode: .behindWindow)
                .ignoresSafeArea()

            LinearGradient(
                colors: [Color.white.opacity(0.18), Color.accentColor.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("需求统计")
                        .font(.title3.weight(.semibold))

                    Spacer()

                    Button("完成") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }

                Picker("时间", selection: $dateFilter) {
                    ForEach(RequirementDateFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                    StatTile(title: "总需求", value: stats.total, systemImage: "list.bullet.rectangle")
                    StatTile(title: "开发中", value: stats.active, systemImage: "hammer")
                    StatTile(title: "待开发", value: stats.pending, systemImage: "clock")
                    StatTile(title: "已完成", value: stats.completed, systemImage: "checkmark.circle")
                    StatTile(title: "已自测", value: stats.tested, systemImage: "testtube.2")
                    StatTile(title: "已合并", value: stats.merged, systemImage: "arrow.triangle.merge")
                    StatTile(title: "异常", value: stats.paused, systemImage: "pause.circle")
                }

                GlassDivider()

                Text("当前范围")
                    .font(.headline)

                List(requirements) { requirement in
                    HStack {
                        Text(requirement.jiraKey)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundStyle(Color.accentColor)

                        Text(requirement.displayStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if let mrIdentifier = RequirementParser.mrIdentifier(from: requirement.mrURL) {
                            Text(mrIdentifier)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.purple)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            .padding(18)
        }
        .frame(width: 480, height: 430)
        .background(TransparentWindowConfigurator())
    }
}

private struct StatTile: View {
    let title: String
    let value: Int
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(value)")
                    .font(.title3.weight(.semibold))
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(GlassPanelBackground(cornerRadius: 9, tintOpacity: 0.13))
    }
}
