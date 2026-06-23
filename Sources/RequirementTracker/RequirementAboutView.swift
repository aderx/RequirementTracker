import AppKit
import SwiftUI

struct RequirementAboutView: View {
    let appIcon: NSImage
    let appName: String
    let version: String
    let githubURL: String?

    var body: some View {
        ZStack {
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 68, height: 68)
                    .shadow(color: Color.black.opacity(0.18), radius: 10, y: 4)

                VStack(spacing: 4) {
                    Text(appName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(DesignColor.textPrimary)

                    Text("版本 \(version)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.black.opacity(0.54))
                }

                Spacer(minLength: 12)

                githubLink
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 18)
        }
        .frame(width: 360, height: 230)
        .background(TransparentWindowConfigurator())
    }

    @ViewBuilder
    private var githubLink: some View {
        if let githubURL, let url = URL(string: githubURL) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Text(githubURL)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DesignColor.doing.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        } else {
            EmptyView()
        }
    }
}
