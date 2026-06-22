import SwiftUI

struct RequirementSettingsView: View {
    var body: some View {
        ZStack {
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "gearshape")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(DesignColor.doing)
                    .frame(width: 52, height: 52)
                    .background(DesignColor.doing.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(spacing: 5) {
                    Text("设置")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DesignColor.textPrimary)

                    Text("暂未配置可调整项")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.black.opacity(0.48))
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
        }
        .frame(width: 460, height: 300)
        .background(TransparentWindowConfigurator())
    }
}
