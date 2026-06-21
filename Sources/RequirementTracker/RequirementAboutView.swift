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
                    .frame(width: 72, height: 72)
                    .shadow(color: Color.black.opacity(0.18), radius: 10, y: 4)

                VStack(spacing: 4) {
                    Text(appName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(DesignColor.textPrimary)

                    Text("需求记录工具")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.black.opacity(0.48))
                }

                VStack(spacing: 0) {
                    AboutInfoRow(label: "版本", value: version)
                    AboutInfoRow(label: "GitHub", value: githubURL ?? "未配置", linkURL: githubURL)
                }
                .background(Color.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                )
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 24)
        }
        .frame(width: 420, height: 272)
        .background(TransparentWindowConfigurator())
    }
}

private struct AboutInfoRow: View {
    let label: String
    let value: String
    var linkURL: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.black.opacity(0.42))
                .frame(width: 54, alignment: .leading)

            if let linkURL, let url = URL(string: linkURL) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text(value)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(DesignColor.doing)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            } else {
                Text(value)
                    .font(.system(size: 11.5, design: label == "GitHub" ? .default : .monospaced))
                    .foregroundStyle(Color.black.opacity(0.70))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if label == "版本" {
                Rectangle()
                    .fill(Color.black.opacity(0.06))
                    .frame(height: 0.5)
                    .padding(.leading, 80)
            }
        }
    }
}
